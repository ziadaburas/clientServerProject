// main.dart
// Flutter LAN WebRTC محسّن مع جميع الإصلاحات من التقرير
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
// import 'package:shared_preferences/shared_preferences.dart';
// import 'package:crypto/crypto.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

// ---------------------------
// Logger للتسجيل المفصل
// ---------------------------
class AppLogger {
  static const String _logTag = 'VoIPApp';
  
  static void info(String message) {
    final timestamp = DateTime.now().toIso8601String();
    print('[$_logTag] [INFO] [$timestamp] $message');
  }
  
  static void error(String message, [Object? error]) {
    final timestamp = DateTime.now().toIso8601String();
    print('[$_logTag] [ERROR] [$timestamp] $message ${error ?? ''}');
  }
  
  static void warning(String message) {
    final timestamp = DateTime.now().toIso8601String();
    print('[$_logTag] [WARNING] [$timestamp] $message');
  }
  
  static void debug(String message) {
    final timestamp = DateTime.now().toIso8601String();
    print('[$_logTag] [DEBUG] [$timestamp] $message');
  }
}

// ---------------------------
// مولد الهوية الآمن
// ---------------------------
String _generateSecureId() {
  const uuid = Uuid();
  return uuid.v4();
}

// ---------------------------
// مراقب جودة الصوت
// ---------------------------
class AudioQualityMonitor {
  Timer? _statsTimer;
  final Function(String)? onQualityUpdate;
  
  AudioQualityMonitor({this.onQualityUpdate});
  
  void startMonitoring(RTCPeerConnection pc, String peerId) {
    AppLogger.info('بدء مراقبة جودة الصوت للمستخدم: $peerId');
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final stats = await pc.getStats();
        _analyzeAudioStats(stats, peerId);
      } catch (e) {
        AppLogger.error('فشل في جمع إحصائيات الصوت: $e');
      }
    });
  }
  
  void _analyzeAudioStats(List<StatsReport> reports, String peerId) {
    for (final report in reports) {
      if (report.type == 'inbound-rtp' && report.values['mediaType'] == 'audio') {
        final packetsLost = report.values['packetsLost'] ?? 0;
        final jitter = report.values['jitter'] ?? 0.0;
        final bytesReceived = report.values['bytesReceived'] ?? 0;
        
        String quality = 'ممتازة';
        if (packetsLost > 50) {
          quality = 'ضعيفة - فقدان حزم عالي';
          AppLogger.warning('جودة صوت ضعيفة للمستخدم $peerId: فقدان $packetsLost حزمة');
        } else if (jitter > 0.1) {
          quality = 'متوسطة - تأخير عالي';
          AppLogger.warning('تأخير عالي للمستخدم $peerId: $jitter');
        }
        
        onQualityUpdate?.call('المستخدم $peerId: $quality');
      }
    }
  }
  
  void stop() {
    _statsTimer?.cancel();
    _statsTimer = null;
    AppLogger.info('تم إيقاف مراقبة جودة الصوت');
  }
}

// ---------------------------
// مدير إعادة الاتصال التلقائي
// ---------------------------
class ReconnectionManager {
  Timer? _reconnectTimer;
  int _retryCount = 0;
  final int _maxRetries = 5;
  final Function() onReconnect;
  final Function(String)? onStatusUpdate;
  
  ReconnectionManager({
    required this.onReconnect,
    this.onStatusUpdate,
  });
  
  void startReconnection() {
    if (_reconnectTimer?.isActive == true) return;
    
    AppLogger.info('بدء آلية إعادة الاتصال التلقائي');
    onStatusUpdate?.call('محاولة إعادة الاتصال...');
    
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_retryCount >= _maxRetries) {
        AppLogger.error('فشل في إعادة الاتصال بعد $_maxRetries محاولات');
        onStatusUpdate?.call('فشل في الاتصال - تحقق من الشبكة');
        timer.cancel();
        return;
      }
      
      _retryCount++;
      AppLogger.info('محاولة إعادة الاتصال رقم $_retryCount');
      onStatusUpdate?.call('محاولة $_retryCount من $_maxRetries');
      onReconnect();
    });
  }
  
  void stopReconnection() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryCount = 0;
    AppLogger.info('تم إيقاف آلية إعادة الاتصال');
  }
  
  void resetRetryCount() {
    _retryCount = 0;
  }
}

// ---------------------------
// مدير الأذونات المحسن
// ---------------------------
class PermissionManager {
  static Future<bool> requestMicrophonePermission() async {
    try {
      AppLogger.info('طلب إذن الميكروفون...');
      final status = await Permission.microphone.request();
      
      if (status.isGranted) {
        AppLogger.info('تم منح إذن الميكروفون');
        return true;
      } else if (status.isDenied) {
        AppLogger.warning('تم رفض إذن الميكروفون');
        return false;
      } else if (status.isPermanentlyDenied) {
        AppLogger.error('تم رفض إذن الميكروفون نهائياً');
        await openAppSettings();
        return false;
      }
    } catch (e) {
      AppLogger.error('خطأ في طلب إذن الميكروفون: $e');
    }
    return false;
  }
  
  static Future<bool> checkMicrophonePermission() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }
}

// ---------------------------
// خادم الإشارات المحسن
// ---------------------------
class EmbeddedSignalingServer {
  static const int MAX_CLIENTS = 10;
  static const Duration HEARTBEAT_INTERVAL = Duration(seconds: 30);
  
  HttpServer? _server;
  final Map<String, WebSocket> _clients = {};
  final Map<String, DateTime> _lastHeartbeat = {};
  Timer? _heartbeatTimer;
  
  bool get isRunning => _server != null;
  int get clientCount => _clients.length;
  
  Future<int> start({int port = 8080}) async {
    if (_server != null) {
      AppLogger.info('الخادم يعمل بالفعل على المنفذ ${_server!.port}');
      return _server!.port;
    }
    
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      AppLogger.info('تم بدء خادم الإشارات على المنفذ $port');
      
      _startHeartbeat();
      
      _server!.listen((HttpRequest req) async {
        await _handleRequest(req);
      });
      
      return _server!.port;
    } catch (e) {
      AppLogger.error('فشل في بدء الخادم: $e');
      rethrow;
    }
  }
  
  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.write('غير مسموح - طلبات WebSocket فقط');
        await req.response.close();
        return;
      }
      
      if (_clients.length >= MAX_CLIENTS) {
        AppLogger.warning('تم رفض اتصال جديد - تم الوصول للحد الأقصى من العملاء');
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.write('الخادم ممتلئ - حاول لاحقاً');
        await req.response.close();
        return;
      }
      
      await _handleNewConnection(req);
    } catch (e) {
      AppLogger.error('خطأ في معالجة الطلب: $e');
    }
  }
  
  Future<void> _handleNewConnection(HttpRequest req) async {
    try {
      final socket = await WebSocketTransformer.upgrade(req);
      final id = _generateSecureId();
      
      _clients[id] = socket;
      _lastHeartbeat[id] = DateTime.now();
      
      AppLogger.info('عميل جديد متصل: $id (إجمالي العملاء: ${_clients.length})');
      
      // إرسال الهوية المخصصة وقائمة الأقران الحاليين
      final peers = _clients.keys.where((k) => k != id).toList();
      final welcomeMessage = {
        'type': 'id',
        'id': id,
        'peers': peers,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      
      _sendToClient(socket, welcomeMessage);
      
      // إشعار الآخرين بوصول عميل جديد
      _broadcastToOthers(id, {
        'type': 'peer-joined',
        'id': id,
        'timestamp': DateTime.now().millisecondsSinceEpoch
      });
      
      // الاستماع للرسائل
      socket.listen(
        (message) => _handleMessage(id, message),
        onDone: () => _handleDisconnection(id),
        onError: (error) => _handleError(id, error),
      );
      
    } catch (e) {
      AppLogger.error('فشل في إعداد اتصال WebSocket: $e');
    }
  }
  
  void _handleMessage(String senderId, dynamic message) {
    try {
      if (message is! String) {
        AppLogger.warning('رسالة غير صالحة من $senderId: ليست نص');
        return;
      }
      
      final Map<String, dynamic> msg = jsonDecode(message);
      
      // التحقق من صحة الرسالة
      if (!_validateMessage(msg)) {
        AppLogger.warning('رسالة غير صالحة من $senderId');
        return;
      }
      
      // تحديث وقت آخر heartbeat
      _lastHeartbeat[senderId] = DateTime.now();
      
      // إضافة معلومات المرسل
      msg['from'] = senderId;
      msg['timestamp'] = DateTime.now().millisecondsSinceEpoch;
      
      final to = msg['to'];
      
      if (to != null && _clients.containsKey(to)) {
        // رسالة مباشرة لعميل محدد
        _sendToClient(_clients[to]!, msg);
        AppLogger.debug('رسالة من $senderId إلى $to: ${msg['type']}');
      } else {
        // بث للجميع عدا المرسل
        _broadcastToOthers(senderId, msg);
        AppLogger.debug('بث من $senderId: ${msg['type']}');
      }
      
    } catch (e) {
      AppLogger.error('خطأ في معالجة رسالة من $senderId: $e');
    }
  }
  
  bool _validateMessage(Map<String, dynamic> msg) {
    // التحقق من وجود حقل type
    if (!msg.containsKey('type') || msg['type'] is! String) {
      return false;
    }
    
    final type = msg['type'] as String;
    
    // التحقق من أنواع الرسائل المسموحة
    const allowedTypes = [
      'join', 'offer', 'answer', 'candidate', 
      'heartbeat', 'leave', 'text-message'
    ];
    
    if (!allowedTypes.contains(type)) {
      return false;
    }
    
    // تحققات إضافية حسب نوع الرسالة
    if (type == 'offer' || type == 'answer') {
      return msg.containsKey('sdp') && msg.containsKey('sdpType');
    }
    
    if (type == 'candidate') {
      return msg.containsKey('candidate');
    }
    
    return true;
  }
  
  void _sendToClient(WebSocket socket, Map<String, dynamic> message) {
    try {
      socket.add(jsonEncode(message));
    } catch (e) {
      AppLogger.error('فشل في إرسال رسالة للعميل: $e');
    }
  }
  
  void _broadcastToOthers(String senderId, Map<String, dynamic> message) {
    for (final entry in _clients.entries) {
      if (entry.key != senderId) {
        _sendToClient(entry.value, message);
      }
    }
  }
  
  void _handleDisconnection(String id) {
    _clients.remove(id);
    _lastHeartbeat.remove(id);
    
    AppLogger.info('عميل منقطع: $id (العملاء المتبقون: ${_clients.length})');
    
    // إشعار الآخرين بالانقطاع
    _broadcastToOthers(id, {
      'type': 'peer-left',
      'id': id,
      'timestamp': DateTime.now().millisecondsSinceEpoch
    });
  }
  
  void _handleError(String id, dynamic error) {
    AppLogger.error('خطأ في اتصال العميل $id: $error');
    _handleDisconnection(id);
  }
  
  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(HEARTBEAT_INTERVAL, (timer) {
      final now = DateTime.now();
      final disconnectedClients = <String>[];
      
      for (final entry in _lastHeartbeat.entries) {
        final timeSinceLastHeartbeat = now.difference(entry.value);
        if (timeSinceLastHeartbeat > Duration(seconds: 60)) {
          disconnectedClients.add(entry.key);
        }
      }
      
      for (final clientId in disconnectedClients) {
        AppLogger.warning('عميل غير متجاوب: $clientId - إزالة الاتصال');
        _clients[clientId]?.close();
        _handleDisconnection(clientId);
      }
    });
  }
  
  Future<void> stop() async {
    try {
      AppLogger.info('إيقاف خادم الإشارات...');
      
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      
      // إشعار جميع العملاء بالإغلاق
      final shutdownMessage = {
        'type': 'server-shutdown',
        'message': 'الخادم يتم إغلاقه',
        'timestamp': DateTime.now().millisecondsSinceEpoch
      };
      
      for (final socket in _clients.values) {
        _sendToClient(socket, shutdownMessage);
        await socket.close();
      }
      
      _clients.clear();
      _lastHeartbeat.clear();
      
      await _server?.close(force: true);
      _server = null;
      
      AppLogger.info('تم إيقاف خادم الإشارات بنجاح');
    } catch (e) {
      AppLogger.error('خطأ أثناء إيقاف الخادم: $e');
    }
  }
}

// ---------------------------
// التطبيق الرئيسي
// ---------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مكالمات الصوت عبر الشبكة المحلية',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Arial',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 16),
          bodyMedium: TextStyle(fontSize: 14),
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
      home: const RoleSelectPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ---------------------------
// صفحة اختيار الدور
// ---------------------------
class RoleSelectPage extends StatefulWidget {
  const RoleSelectPage({super.key});
  
  @override
  State<RoleSelectPage> createState() => _RoleSelectPageState();
}

class _RoleSelectPageState extends State<RoleSelectPage> {
  bool _isCheckingPermissions = false;
  
  @override
  void initState() {
    super.initState();
    _checkInitialPermissions();
  }
  
  Future<void> _checkInitialPermissions() async {
    setState(() => _isCheckingPermissions = true);
    
    final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      _showPermissionDialog();
    }
    
    setState(() => _isCheckingPermissions = false);
  }
  
  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('إذن الميكروفون مطلوب'),
        content: const Text(
          'هذا التطبيق يحتاج إلى إذن الوصول للميكروفون لإجراء المكالمات الصوتية. '
          'يرجى السماح بالوصول للميكروفون للمتابعة.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await PermissionManager.requestMicrophonePermission();
            },
            child: const Text('طلب الإذن'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _navigateToManager() async {
    if (_isCheckingPermissions) return;
    
    final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      final granted = await PermissionManager.requestMicrophonePermission();
      if (!granted) {
        _showPermissionDialog();
        return;
      }
    }
    
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ManagerPage())
      );
    }
  }
  
  Future<void> _navigateToParticipant() async {
    if (_isCheckingPermissions) return;
    
    final hasPermission = await PermissionManager.checkMicrophonePermission();
    if (!hasPermission) {
      final granted = await PermissionManager.requestMicrophonePermission();
      if (!granted) {
        _showPermissionDialog();
        return;
      }
    }
    
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ParticipantPage())
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('اختر دورك في المكالمة'),
        centerTitle: true,
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue[50]!, Colors.white],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.phone,
                  size: 80,
                  color: Colors.blue[700],
                ),
                const SizedBox(height: 32),
                const Text(
                  'مرحباً بك في تطبيق المكالمات الصوتية',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  'اختر دورك للبدء في المكالمة',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                if (_isCheckingPermissions)
                  const Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('جاري التحقق من الأذونات...'),
                    ],
                  )
                else ...[
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _navigateToManager,
                      icon: const Icon(Icons.wifi_tethering, size: 24),
                      label: const Text(
                        'بدء كمدير (استضافة المكالمة)',
                        style: TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[600],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _navigateToParticipant,
                      icon: const Icon(Icons.person_add, size: 24),
                      label: const Text(
                        'انضمام كمشارك',
                        style: TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[600],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue),
                      SizedBox(height: 8),
                      Text(
                        'نصائح:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '• المدير: يستضيف المكالمة ويدير الاتصالات\n'
                        '• المشارك: ينضم إلى مكالمة موجودة\n'
                        '• تأكد من اتصال جميع الأجهزة بنفس الشبكة',
                        style: TextStyle(fontSize: 12, color: Colors.blue),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------
// صفحة المدير المحسنة
// ---------------------------
class ManagerPage extends StatefulWidget {
  const ManagerPage({super.key});
  
  @override
  State<ManagerPage> createState() => _ManagerPageState();
}

class _ManagerPageState extends State<ManagerPage> with WidgetsBindingObserver {
  final EmbeddedSignalingServer _server = EmbeddedSignalingServer();
  bool _serverRunning = false;
  String _localIp = 'جاري البحث...';
  final int _port = 8080;
  String _log = '';
  bool _isStarting = false;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeManager();
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopServer();
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogger.info('تغيير حالة التطبيق: $state');
    if (state == AppLifecycleState.paused && _serverRunning) {
      // الحفاظ على الخادم يعمل في الخلفية
      WakelockPlus.enable();
    } else if (state == AppLifecycleState.resumed) {
      WakelockPlus.disable();
    }
  }
  
  Future<void> _initializeManager() async {
    await _getLocalIp();
    _appendLog('مدير المكالمة جاهز للعمل');
  }
  
  Future<void> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && 
              addr.address.contains('.') &&
              !addr.address.startsWith('169.254')) {
            setState(() => _localIp = addr.address);
            AppLogger.info('تم العثور على عنوان IP المحلي: ${addr.address}');
            return;
          }
        }
      }
      
      setState(() => _localIp = 'غير محدد');
      AppLogger.warning('لم يتم العثور على عنوان IP صالح');
    } catch (e) {
      setState(() => _localIp = 'خطأ في الحصول على IP');
      AppLogger.error('خطأ في الحصول على IP المحلي: $e');
    }
  }
  
  void _appendLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    setState(() {
      _log = '[$timestamp] $message\n$_log';
    });
    AppLogger.info(message);
  }
  
  Future<void> _startServer() async {
    if (_isStarting || _serverRunning) return;
    
    setState(() => _isStarting = true);
    
    try {
      _appendLog('بدء خادم الإشارات...');
      
      final actualPort = await _server.start(port: _port);
      await _getLocalIp(); // تحديث IP مرة أخرى
      
      setState(() {
        _serverRunning = true;
        _isStarting = false;
      });
      
      _appendLog('تم بدء الخادم بنجاح على المنفذ $actualPort');
      _appendLog('عنوان الخادم: ws://$_localIp:$actualPort');
      _appendLog('يمكن للمشاركين الآن الاتصال بهذا العنوان');
      
      // الانتقال لصفحة المشارك كمدير
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ParticipantPage(
              initialServer: 'ws://$_localIp:$actualPort',
              isManager: true,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _isStarting = false);
      _appendLog('فشل في بدء الخادم: $e');
      _showErrorDialog('فشل في بدء الخادم', e.toString());
    }
  }
  
  Future<void> _stopServer() async {
    if (!_serverRunning) return;
    
    try {
      _appendLog('إيقاف الخادم...');
      await _server.stop();
      setState(() => _serverRunning = false);
      _appendLog('تم إيقاف الخادم بنجاح');
    } catch (e) {
      _appendLog('خطأ أثناء إيقاف الخادم: $e');
    }
  }
  
  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('موافق'),
          ),
        ],
      ),
    );
  }
  
  void _copyServerAddress() {
    final address = 'ws://$_localIp:$_port';
    Clipboard.setData(ClipboardData(text: address));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم نسخ عنوان الخادم'),
        duration: Duration(seconds: 2),
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مدير المكالمة'),
        centerTitle: true,
        backgroundColor: Colors.green[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _getLocalIp,
            icon: const Icon(Icons.refresh),
            tooltip: 'تحديث عنوان IP',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // معلومات الخادم
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Colors.blue[700],
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'معلومات الخادم',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const Divider(),
                    _buildInfoRow('عنوان IP المحلي:', _localIp),
                    _buildInfoRow('منفذ الإشارات:', _port.toString()),
                    _buildInfoRow('حالة الخادم:', _serverRunning ? 'يعمل' : 'متوقف'),
                    if (_serverRunning)
                      _buildInfoRow('عدد العملاء المتصلين:', '${_server.clientCount}'),
                    const SizedBox(height: 12),
                    if (_serverRunning) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green[200]!),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'ws://$_localIp:$_port',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: Colors.green[800],
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: _copyServerAddress,
                              icon: const Icon(Icons.copy),
                              tooltip: 'نسخ العنوان',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // أزرار التحكم
            if (_isStarting)
              const SizedBox(
                height: 56,
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 16),
                      Text('جاري بدء الخادم...'),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _serverRunning ? _stopServer : _startServer,
                  icon: Icon(_serverRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _serverRunning 
                      ? 'إيقاف الخادم' 
                      : 'بدء الخادم والانضمام للمكالمة',
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _serverRunning 
                      ? Colors.red[600] 
                      : Colors.green[600],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                  ),
                ),
              ),
            
            const SizedBox(height: 16),
            
            // سجل الأحداث
            const Text(
              'سجل الأحداث:',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                elevation: 2,
                child: Container(
                  padding: const EdgeInsets.all(2.0),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _log.isEmpty ? 'لا توجد أحداث بعد...' : _log,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // تعليمات
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline, color: Colors.amber[700]),
                      const SizedBox(width: 8),
                      Text(
                        'تعليمات:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.amber[700],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. اضغط "بدء الخادم" لاستضافة المكالمة\n'
                    '2. شارك عنوان الخادم مع المشاركين\n'
                    '3. سيتم نقلك تلقائياً لشاشة المكالمة\n'
                    '4. تأكد من اتصال جميع الأجهزة بنفس الشبكة',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          Text(
            value,
            style: TextStyle(
              color: Colors.blue[700],
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------
// صفحة المشارك المحسنة
// ---------------------------
class ParticipantPage extends StatefulWidget {
  final String? initialServer;
  final bool isManager;
  
  const ParticipantPage({
    super.key,
    this.initialServer,
    this.isManager = false,
  });
  
  @override
  State<ParticipantPage> createState() => _ParticipantPageState();
}

class _ParticipantPageState extends State<ParticipantPage> 
    with WidgetsBindingObserver {
  
  // Controllers
  final _serverController = TextEditingController();
  final _nameController = TextEditingController(text: 'مستخدم');
  
  // WebRTC & Signaling
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final List<String> _connectedPeers = [];
  MediaStream? _localStream;
  IOWebSocketChannel? _signalingChannel;
  String? _myId;
  
  // State management
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _microphoneMuted = false;
  bool _speakerOn = true;
  String _connectionStatus = 'غير متصل';
  String _log = '';
  
  // Managers
  ReconnectionManager? _reconnectionManager;
  AudioQualityMonitor? _qualityMonitor;
  Timer? _heartbeatTimer;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeParticipant();
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cleanupResources();
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogger.info('تغيير حالة تطبيق المشارك: $state');
    
    switch (state) {
      case AppLifecycleState.paused:
        _handleAppPaused();
        break;
      case AppLifecycleState.resumed:
        _handleAppResumed();
        break;
      case AppLifecycleState.detached:
        _handleAppDetached();
        break;
      default:
        break;
    }
  }
  
  void _handleAppPaused() {
    AppLogger.info('التطبيق في الخلفية - الحفاظ على الاتصال');
    WakelockPlus.enable();
    // لا نقطع الاتصال، فقط نحافظ على التطبيق نشطاً
  }
  
  void _handleAppResumed() {
    AppLogger.info('التطبيق عاد للمقدمة');
    WakelockPlus.disable();
    // التحقق من حالة الاتصالات
    _checkConnectionHealth();
  }
  
  void _handleAppDetached() {
    AppLogger.info('التطبيق تم إغلاقه - تنظيف الموارد');
    _cleanupResources();
  }
  
  Future<void> _initializeParticipant() async {
    // إعداد القيم الأولية
    if (widget.initialServer != null) {
      _serverController.text = widget.initialServer!;
    }
    
    if (widget.isManager) {
      _nameController.text = 'المدير';
    }
    
    // إعداد مدير إعادة الاتصال
    _reconnectionManager = ReconnectionManager(
      onReconnect: _attemptReconnection,
      onStatusUpdate: _updateConnectionStatus,
    );
    
    // إعداد مراقب الجودة
    _qualityMonitor = AudioQualityMonitor(
      onQualityUpdate: _updateQualityStatus,
    );
    
    _appendLog('المشارك جاهز للاتصال');
    
    // إذا كان لدينا خادم محدد مسبقاً، نتصل تلقائياً
    if (widget.initialServer != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _connectToServer();
      });
    }
  }
  
  void _appendLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    if (mounted) {
      setState(() {
        _log = '[$timestamp] $message\n$_log';
      });
    }
    AppLogger.info(message);
  }
  
  void _updateConnectionStatus(String status) {
    if (mounted) {
      setState(() => _connectionStatus = status);
    }
  }
  
  void _updateQualityStatus(String qualityInfo) {
    _appendLog('جودة الصوت: $qualityInfo');
  }
  
  // ---------------------------
  // WebRTC Configuration
  // ---------------------------
  
  Map<String, dynamic> _getOptimizedRTCConfiguration() {
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        // يمكن إضافة خوادم TURN هنا للشبكات المعقدة
      ],
      'iceCandidatePoolSize': 10,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };
  }
  
  Map<String, dynamic> _getOptimizedAudioConstraints() {
    return {
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'sampleRate': 48000,
        'channelCount': 1,
        'googEchoCancellation': true,
        'googNoiseSuppression': true,
        'googHighpassFilter': true,
        'googTypingNoiseDetection': true,
      },
      'video': false,
    };
  }
  
  // ---------------------------
  // Audio Stream Management
  // ---------------------------
  
  Future<MediaStream> _openLocalAudioStream() async {
    if (_localStream != null) {
      AppLogger.info('تدفق الصوت المحلي موجود بالفعل');
      return _localStream!;
    }
    
    try {
      AppLogger.info('فتح تدفق الصوت المحلي...');
      
      final constraints = _getOptimizedAudioConstraints();
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      
      final audioTracks = _localStream!.getAudioTracks();
      AppLogger.info('تم فتح تدفق الصوت: ${audioTracks.length} مسار صوتي');
      
      if (audioTracks.isNotEmpty) {
        _appendLog('تم فتح الميكروفون بنجاح');
      } else {
        _appendLog('تحذير: لم يتم العثور على مسارات صوتية');
      }
      
      return _localStream!;
    } catch (e) {
      AppLogger.error('فشل في فتح تدفق الصوت: $e');
      _appendLog('خطأ: فشل في الوصول للميكروفون - $e');
      
      // طلب الأذونات مرة أخرى
      final hasPermission = await PermissionManager.requestMicrophonePermission();
      if (!hasPermission) {
        throw Exception('لم يتم منح إذن الميكروفون');
      }
      
      rethrow;
    }
  }
  
  Future<void> _toggleMicrophone() async {
    if (_localStream == null) return;
    
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isNotEmpty) {
      final enabled = !audioTracks.first.enabled;
      audioTracks.first.enabled = enabled;
      
      setState(() => _microphoneMuted = !enabled);
      _appendLog(enabled ? 'تم تشغيل الميكروفون' : 'تم كتم الميكروفون');
      AppLogger.info('حالة الميكروفون: ${enabled ? 'مفعل' : 'مكتوم'}');
    }
  }
  
  Future<void> _toggleSpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(!_speakerOn);
      setState(() => _speakerOn = !_speakerOn);
      _appendLog(_speakerOn ? 'تم تشغيل السماعة' : 'تم إيقاف السماعة');
      AppLogger.info('حالة السماعة: ${_speakerOn ? 'مفعلة' : 'معطلة'}');
    } catch (e) {
      AppLogger.error('فشل في تغيير حالة السماعة: $e');
      _appendLog('خطأ في تغيير حالة السماعة');
    }
  }
  
  // ---------------------------
  // Peer Connection Management  
  // ---------------------------
  
  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    if (_peerConnections.containsKey(peerId)) {
      AppLogger.info('اتصال الند موجود بالفعل: $peerId');
      return _peerConnections[peerId]!;
    }
    
    try {
      AppLogger.info('إنشاء اتصال ند جديد: $peerId');
      
      final config = _getOptimizedRTCConfiguration();
      final pc = await createPeerConnection(config);
      
      // إضافة المسار الصوتي المحلي
      final localStream = await _openLocalAudioStream();
      for (final track in localStream.getAudioTracks()) {
        await pc.addTrack(track, localStream);
        AppLogger.info('تم إضافة مسار صوتي للند $peerId');
      }
      
      // معالجة ICE candidates
      pc.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          _sendSignalingMessage({
            'type': 'candidate',
            'to': peerId,
            'candidate': candidate.toMap(),
          });
          AppLogger.debug('تم إرسال ICE candidate للند $peerId');
        }
      };
      
      // معالجة المسارات البعيدة
      pc.onTrack = (RTCTrackEvent event) async {
        AppLogger.info('تم استلام مسار بعيد من $peerId: ${event.track.kind}');
        
        if (event.streams.isNotEmpty && event.track.kind == 'audio') {
          await _handleRemoteAudioTrack(peerId, event.streams[0]);
        }
      };
      
      // معالجة تغييرات حالة الاتصال
      pc.onConnectionState = (RTCPeerConnectionState state) {
        AppLogger.info('حالة اتصال الند $peerId: $state');
        _appendLog('حالة الاتصال مع $peerId: ${_translateConnectionState(state)}');
        
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _qualityMonitor?.startMonitoring(pc, peerId);
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                   state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _handlePeerDisconnection(peerId);
        }
      };
      
      // معالجة تغييرات ICE
      pc.onIceConnectionState = (RTCIceConnectionState state) {
        AppLogger.info('حالة ICE للند $peerId: $state');
        
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _appendLog('فشل اتصال ICE مع $peerId - محاولة إعادة الاتصال');
          _handlePeerDisconnection(peerId);
        }
      };
      
      _peerConnections[peerId] = pc;
      return pc;
    } catch (e) {
      AppLogger.error('فشل في إنشاء اتصال الند $peerId: $e');
      _appendLog('خطأ في الاتصال بـ $peerId');
      rethrow;
    }
  }
  
  Future<void> _handleRemoteAudioTrack(String peerId, MediaStream stream) async {
    try {
      AppLogger.info('معالجة مسار صوتي بعيد من $peerId');
      
      if (!_remoteRenderers.containsKey(peerId)) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        _remoteRenderers[peerId] = renderer;
      }
      
      _remoteRenderers[peerId]!.srcObject = stream;
      
      if (mounted) {
        setState(() {});
      }
      
      _appendLog('تم استلام الصوت من $peerId');
    } catch (e) {
      AppLogger.error('فشل في معالجة المسار البعيد من $peerId: $e');
    }
  }
  
  String _translateConnectionState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        return 'جديد';
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        return 'يتصل';
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return 'متصل';
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        return 'منقطع';
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return 'فشل';
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return 'مغلق';
      default:
        return 'غير معروف';
    }
  }
  
  Future<void> _handlePeerDisconnection(String peerId) async {
    AppLogger.info('معالجة انقطاع الند: $peerId');
    
    // إزالة الاتصال
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      try {
        await pc.close();
      } catch (e) {
        AppLogger.error('خطأ في إغلاق اتصال الند $peerId: $e');
      }
    }
    
    // إزالة المعرض
    final renderer = _remoteRenderers.remove(peerId);
    if (renderer != null) {
      try {
        await renderer.dispose();
      } catch (e) {
        AppLogger.error('خطأ في تنظيف معرض الند $peerId: $e');
      }
    }
    
    // تحديث قائمة الأقران
    if (mounted) {
      setState(() {
        _connectedPeers.remove(peerId);
      });
    }
    
    _appendLog('تم قطع الاتصال مع $peerId');
  }
  
  // ---------------------------
  // WebRTC Negotiation
  // ---------------------------
  
  Future<void> _createOfferForPeer(String peerId) async {
    try {
      AppLogger.info('إنشاء عرض للند: $peerId');
      
      final pc = await _createPeerConnection(peerId);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      
      _sendSignalingMessage({
        'type': 'offer',
        'to': peerId,
        'sdp': offer.sdp,
        'sdpType': offer.type,
      });
      
      _appendLog('تم إرسال عرض الاتصال إلى $peerId');
    } catch (e) {
      AppLogger.error('فشل في إنشاء عرض للند $peerId: $e');
      _appendLog('خطأ في إرسال عرض الاتصال إلى $peerId');
    }
  }
  
  Future<void> _handleOffer(String fromPeer, String sdp, String sdpType) async {
    try {
      AppLogger.info('معالجة عرض من الند: $fromPeer');
      
      final pc = await _createPeerConnection(fromPeer);
      await pc.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
      
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      
      _sendSignalingMessage({
        'type': 'answer',
        'to': fromPeer,
        'sdp': answer.sdp,
        'sdpType': answer.type,
      });
      
      _appendLog('تم الرد على عرض الاتصال من $fromPeer');
    } catch (e) {
      AppLogger.error('فشل في معالجة عرض من $fromPeer: $e');
      _appendLog('خطأ في معالجة عرض الاتصال من $fromPeer');
    }
  }
  
  Future<void> _handleAnswer(String fromPeer, String sdp, String sdpType) async {
    try {
      AppLogger.info('معالجة إجابة من الند: $fromPeer');
      
      final pc = _peerConnections[fromPeer];
      if (pc == null) {
        AppLogger.warning('لا يوجد اتصال ند للإجابة من $fromPeer');
        return;
      }
      
      await pc.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
      _appendLog('تم تطبيق إجابة الاتصال من $fromPeer');
    } catch (e) {
      AppLogger.error('فشل في معالجة إجابة من $fromPeer: $e');
      _appendLog('خطأ في معالجة إجابة الاتصال من $fromPeer');
    }
  }
  
  Future<void> _handleIceCandidate(String fromPeer, Map candidateData) async {
    try {
      final pc = _peerConnections[fromPeer];
      if (pc == null) {
        AppLogger.warning('لا يوجد اتصال ند لـ ICE candidate من $fromPeer');
        return;
      }
      
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      
      await pc.addCandidate(candidate);
      AppLogger.debug('تم إضافة ICE candidate من $fromPeer');
    } catch (e) {
      AppLogger.error('فشل في معالجة ICE candidate من $fromPeer: $e');
    }
  }
  
  // ---------------------------
  // Signaling Management
  // ---------------------------
  
  Future<void> _connectToServer() async {
    if (_isConnecting || _isConnected) {
      AppLogger.info('الاتصال جاري بالفعل أو متصل');
      return;
    }
    
    final serverUrl = _serverController.text.trim();
    if (serverUrl.isEmpty) {
      _showErrorDialog('خطأ', 'يرجى إدخال عنوان الخادم');
      return;
    }
    
    setState(() {
      _isConnecting = true;
      _connectionStatus = 'جاري الاتصال...';
    });
    
    try {
      AppLogger.info('الاتصال بخادم الإشارات: $serverUrl');
      _appendLog('جاري الاتصال بالخادم...');
      
      _signalingChannel = IOWebSocketChannel.connect(serverUrl);
      
      // الاستماع للرسائل
      _signalingChannel!.stream.listen(
        _handleSignalingMessage,
        onDone: _handleSignalingDisconnection,
        onError: _handleSignalingError,
      );
      
      // إرسال رسالة انضمام
      _sendSignalingMessage({
        'type': 'join',
        'name': _nameController.text.trim(),
      });
      
      // بدء heartbeat
      _startHeartbeat();
      
    } catch (e) {
      AppLogger.error('فشل في الاتصال بالخادم: $e');
      _appendLog('فشل في الاتصال: $e');
      
      setState(() {
        _isConnecting = false;
        _connectionStatus = 'فشل الاتصال';
      });
      
      _showErrorDialog('خطأ في الاتصال', e.toString());
    }
  }
  
  void _handleSignalingMessage(dynamic data) async {
    try {
      if (data is! String) {
        AppLogger.warning('رسالة إشارة غير صالحة: ليست نص');
        return;
      }
      
      final message = jsonDecode(data) as Map<String, dynamic>;
      final type = message['type'] as String?;
      
      if (type == null) {
        AppLogger.warning('رسالة إشارة بدون نوع');
        return;
      }
      
      AppLogger.debug('استلام رسالة إشارة: $type');
      
      switch (type) {
        case 'id':
          await _handleIdAssignment(message);
          break;
        case 'peer-joined':
          await _handlePeerJoined(message);
          break;
        case 'peer-left':
          await _handlePeerLeft(message);
          break;
        case 'offer':
          if (message['to'] == _myId) {
            await _handleOffer(
              message['from'],
              message['sdp'],
              message['sdpType'],
            );
          }
          break;
        case 'answer':
          if (message['to'] == _myId) {
            await _handleAnswer(
              message['from'],
              message['sdp'],
              message['sdpType'],
            );
          }
          break;
        case 'candidate':
          if (message['to'] == _myId) {
            await _handleIceCandidate(
              message['from'],
              message['candidate'],
            );
          }
          break;
        case 'server-shutdown':
          _handleServerShutdown(message);
          break;
        default:
          AppLogger.info('نوع رسالة إشارة غير معروف: $type');
      }
    } catch (e) {
      AppLogger.error('خطأ في معالجة رسالة الإشارة: $e');
    }
  }
  
  Future<void> _handleIdAssignment(Map<String, dynamic> message) async {
    _myId = message['id'] as String?;
    final peers = List<String>.from(message['peers'] ?? []);
    
    AppLogger.info('تم تخصيص الهوية: $_myId');
    AppLogger.info('الأقران الموجودون: $peers');
    
    setState(() {
      _isConnected = true;
      _isConnecting = false;
      _connectionStatus = 'متصل';
      _connectedPeers.clear();
      _connectedPeers.addAll(peers);
    });
    
    _appendLog('تم الاتصال بنجاح - الهوية: $_myId');
    _appendLog('الأقران الموجودون: ${peers.length}');
    
    // إنشاء عروض اتصال للأقران الموجودين (العميل الجديد يبدأ)
    for (final peerId in peers) {
      await _createOfferForPeer(peerId);
    }
    
    // إيقاف مدير إعادة الاتصال
    _reconnectionManager?.stopReconnection();
  }
  
  Future<void> _handlePeerJoined(Map<String, dynamic> message) async {
    final peerId = message['id'] as String?;
    if (peerId == null || peerId == _myId) return;
    
    AppLogger.info('انضم ند جديد: $peerId');
    
    if (mounted) {
      setState(() {
        if (!_connectedPeers.contains(peerId)) {
          _connectedPeers.add(peerId);
        }
      });
    }
    
    _appendLog('انضم مشارك جديد: $peerId');
    // العميل الموجود لا يحتاج لإرسال عرض - العميل الجديد سيرسل
  }
  
  Future<void> _handlePeerLeft(Map<String, dynamic> message) async {
    final peerId = message['id'] as String?;
    if (peerId == null) return;
    
    AppLogger.info('غادر الند: $peerId');
    await _handlePeerDisconnection(peerId);
  }
  
  void _handleServerShutdown(Map<String, dynamic> message) {
    final shutdownMessage = message['message'] as String? ?? 'الخادم متوقف';
    AppLogger.info('الخادم يتم إغلاقه: $shutdownMessage');
    _appendLog('تحذير: $shutdownMessage');
    
    // بدء إعادة الاتصال
    _reconnectionManager?.startReconnection();
  }
  
  void _handleSignalingDisconnection() {
    AppLogger.info('انقطع اتصال الإشارة');
    _appendLog('انقطع الاتصال بالخادم');
    
    setState(() {
      _isConnected = false;
      _connectionStatus = 'منقطع';
    });
    
    _stopHeartbeat();
    
    // بدء إعادة الاتصال التلقائي
    if (!widget.isManager) { // المدير لا يعيد الاتصال تلقائياً
      _reconnectionManager?.startReconnection();
    }
  }
  
  void _handleSignalingError(dynamic error) {
    AppLogger.error('خطأ في اتصال الإشارة: $error');
    _appendLog('خطأ في الاتصال: $error');
    
    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _connectionStatus = 'خطأ في الاتصال';
    });
    
    _stopHeartbeat();
    
    // بدء إعادة الاتصال
    _reconnectionManager?.startReconnection();
  }
  
  void _sendSignalingMessage(Map<String, dynamic> message) {
    if (_signalingChannel == null) {
      AppLogger.warning('لا يوجد اتصال إشارة لإرسال الرسالة');
      return;
    }
    
    try {
      final jsonMessage = jsonEncode(message);
      _signalingChannel!.sink.add(jsonMessage);
      AppLogger.debug('تم إرسال رسالة إشارة: ${message['type']}');
    } catch (e) {
      AppLogger.error('فشل في إرسال رسالة الإشارة: $e');
    }
  }
  
  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _sendSignalingMessage({'type': 'heartbeat'});
    });
  }
  
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }
  
  // ---------------------------
  // Reconnection Logic
  // ---------------------------
  
  Future<void> _attemptReconnection() async {
    if (_isConnected || _isConnecting) {
      _reconnectionManager?.stopReconnection();
      return;
    }
    
    AppLogger.info('محاولة إعادة الاتصال...');
    
    // تنظيف الاتصالات السابقة
    await _cleanupSignaling();
    
    // محاولة الاتصال مرة أخرى
    await _connectToServer();
  }
  
  Future<void> _checkConnectionHealth() async {
    AppLogger.info('فحص صحة الاتصالات...');
    
    if (!_isConnected) {
      _appendLog('الاتصال غير موجود - محاولة إعادة الاتصال');
      _reconnectionManager?.startReconnection();
      return;
    }
    
    // فحص اتصالات الأقران
    for (final peerId in _connectedPeers.toList()) {
      final pc = _peerConnections[peerId];
      if (pc == null) {
        AppLogger.warning('اتصال الند $peerId مفقود');
        continue;
      }
      
      final state = await pc.connectionState;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        AppLogger.warning('اتصال الند $peerId في حالة سيئة: $state');
        await _handlePeerDisconnection(peerId);
      }
    }
  }
  
  // ---------------------------
  // Cleanup and Disposal
  // ---------------------------
  
  Future<void> _cleanupSignaling() async {
    try {
      await _signalingChannel?.sink.close();
    } catch (e) {
      AppLogger.error('خطأ في إغلاق قناة الإشارة: $e');
    }
    _signalingChannel = null;
    _stopHeartbeat();
  }
  
  Future<void> _cleanupPeerConnections() async {
    AppLogger.info('تنظيف اتصالات الأقران...');
    
    for (final entry in _peerConnections.entries) {
      try {
        await entry.value.close();
      } catch (e) {
        AppLogger.error('خطأ في إغلاق اتصال الند ${entry.key}: $e');
      }
    }
    _peerConnections.clear();
    
    for (final entry in _remoteRenderers.entries) {
      try {
        await entry.value.dispose();
      } catch (e) {
        AppLogger.error('خطأ في تنظيف معرض الند ${entry.key}: $e');
      }
    }
    _remoteRenderers.clear();
    
    _connectedPeers.clear();
  }
  
  Future<void> _cleanupLocalStream() async {
    if (_localStream != null) {
      try {
        AppLogger.info('تنظيف التدفق المحلي...');
        await _localStream!.dispose();
        _localStream = null;
      } catch (e) {
        AppLogger.error('خطأ في تنظيف التدفق المحلي: $e');
      }
    }
  }
  
  Future<void> _cleanupResources() async {
    AppLogger.info('تنظيف جميع الموارد...');
    
    _reconnectionManager?.stopReconnection();
    _qualityMonitor?.stop();
    
    await _cleanupSignaling();
    await _cleanupPeerConnections();
    await _cleanupLocalStream();
    
    try {
      WakelockPlus.disable();
    } catch (e) {
      AppLogger.error('خطأ في إيقاف Wakelock: $e');
    }
    
    AppLogger.info('تم تنظيف جميع الموارد');
  }
  
  Future<void> _leaveCall() async {
    AppLogger.info('مغادرة المكالمة...');
    _appendLog('جاري المغادرة...');
    
    // إرسال رسالة مغادرة
    if (_isConnected) {
      _sendSignalingMessage({'type': 'leave'});
    }
    
    await _cleanupResources();
    
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleSelectPage()),
        (route) => false,
      );
    }
  }
  
  // ---------------------------
  // UI Helper Methods
  // ---------------------------
  
  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('موافق'),
          ),
        ],
      ),
    );
  }
  
  void _showServerInputDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إدخال عنوان الخادم'),
        content: TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            hintText: 'ws://192.168.1.100:8080',
            labelText: 'عنوان الخادم',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _connectToServer();
            },
            child: const Text('اتصال'),
          ),
        ],
      ),
    );
  }
  
  Color _getConnectionStatusColor() {
    switch (_connectionStatus) {
      case 'متصل':
        return Colors.green;
      case 'جاري الاتصال...':
        return Colors.orange;
      case 'منقطع':
      case 'فشل الاتصال':
      case 'خطأ في الاتصال':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
  
  IconData _getConnectionStatusIcon() {
    switch (_connectionStatus) {
      case 'متصل':
        return Icons.wifi;
      case 'جاري الاتصال...':
        return Icons.wifi_find;
      case 'منقطع':
      case 'فشل الاتصال':
      case 'خطأ في الاتصال':
        return Icons.wifi_off;
      default:
        return Icons.signal_wifi_statusbar_null;
    }
  }
  
  // ---------------------------
  // Build Method
  // ---------------------------
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isManager ? 'المدير - في المكالمة' : 'المشارك'),
        centerTitle: true,
        backgroundColor: widget.isManager ? Colors.green[700] : Colors.blue[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _leaveCall,
            icon: const Icon(Icons.call_end),
            tooltip: 'إنهاء المكالمة',
            color: Colors.red[300],
          ),
        ],
      ),
      body: Column(
        children: [
          // شريط الحالة
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _getConnectionStatusColor().withOpacity(0.1),
              border: Border(
                bottom: BorderSide(
                  color: _getConnectionStatusColor().withOpacity(0.3),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _getConnectionStatusIcon(),
                  color: _getConnectionStatusColor(),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _connectionStatus,
                  style: TextStyle(
                    color: _getConnectionStatusColor(),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_isConnected) ...[
                  Icon(
                    Icons.people,
                    color: Colors.blue[700],
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'المشاركون: ${_connectedPeers.length + 1}',
                    style: TextStyle(
                      color: Colors.blue[700],
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          
          // منطقة الاتصال والتحكم
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // إعدادات الاتصال
                  if (!_isConnected) ...[
                    Card(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'إعدادات الاتصال',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _serverController,
                              decoration: InputDecoration(
                                labelText: 'عنوان خادم الإشارات',
                                hintText: 'ws://192.168.1.100:8080',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.dns),
                                suffixIcon: IconButton(
                                  onPressed: _showServerInputDialog,
                                  icon: const Icon(Icons.edit),
                                ),
                              ),
                              enabled: !_isConnecting,
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _nameController,
                              decoration: const InputDecoration(
                                labelText: 'اسمك في المكالمة',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.person),
                              ),
                              enabled: !_isConnecting,
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 48,
                              child: ElevatedButton.icon(
                                onPressed: _isConnecting ? null : _connectToServer,
                                icon: _isConnecting
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      )
                                    : const Icon(Icons.phone),
                                label: Text(
                                  _isConnecting ? 'جاري الاتصال...' : 'اتصال',
                                  style: const TextStyle(fontSize: 16),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green[600],
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  
                  // أزرار التحكم في الصوت
                  if (_isConnected) ...[
                    Card(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // زر الميكروفون
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FloatingActionButton(
                                  onPressed: _toggleMicrophone,
                                  backgroundColor: _microphoneMuted 
                                      ? Colors.red[600] 
                                      : Colors.green[600],
                                  foregroundColor: Colors.white,
                                  heroTag: 'mic',
                                  child: Icon(
                                    _microphoneMuted 
                                        ? Icons.mic_off 
                                        : Icons.mic,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _microphoneMuted ? 'مكتوم' : 'مفعل',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                            
                            // زر السماعة
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FloatingActionButton(
                                  onPressed: _toggleSpeaker,
                                  backgroundColor: _speakerOn 
                                      ? Colors.blue[600] 
                                      : Colors.grey[600],
                                  foregroundColor: Colors.white,
                                  heroTag: 'speaker',
                                  child: Icon(
                                    _speakerOn 
                                        ? Icons.volume_up 
                                        : Icons.volume_off,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _speakerOn ? 'مفعلة' : 'معطلة',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                            
                            // زر إنهاء المكالمة
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FloatingActionButton(
                                  onPressed: _leaveCall,
                                  backgroundColor: Colors.red[600],
                                  foregroundColor: Colors.white,
                                  heroTag: 'hangup',
                                  child: const Icon(Icons.call_end),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'إنهاء',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // قائمة المشاركين
                    Card(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.people, color: Colors.blue[700]),
                                const SizedBox(width: 8),
                                const Text(
                                  'المشاركون في المكالمة',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(),
                            
                            // المستخدم الحالي
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.green[100],
                                child: Icon(
                                  Icons.person,
                                  color: Colors.green[700],
                                ),
                              ),
                              title: Text('${_nameController.text} (أنت)'),
                              subtitle: Text(
                                'الهوية: ${_myId ?? 'غير محدد'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _microphoneMuted ? Icons.mic_off : Icons.mic,
                                    size: 16,
                                    color: _microphoneMuted ? Colors.red : Colors.green,
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    _speakerOn ? Icons.volume_up : Icons.volume_off,
                                    size: 16,
                                    color: _speakerOn ? Colors.blue : Colors.grey,
                                  ),
                                ],
                              ),
                            ),
                            
                            // المشاركون الآخرون
                            if (_connectedPeers.isNotEmpty) ...[
                              const Divider(),
                              ..._connectedPeers.map((peerId) => _buildPeerTile(peerId)),
                            ] else if (_isConnected) ...[
                              const Divider(),
                              const ListTile(
                                leading: Icon(Icons.info_outline),
                                title: Text('لا يوجد مشاركون آخرون'),
                                subtitle: Text('انتظر انضمام مشاركين آخرين'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 16),
                  
                  // سجل الأحداث
                  const Text(
                    'سجل الأحداث:',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Card(
                      elevation: 2,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            _log.isEmpty ? 'لا توجد أحداث بعد...' : _log,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildPeerTile(String peerId) {
    final isConnected = _peerConnections.containsKey(peerId);
    final hasAudio = _remoteRenderers.containsKey(peerId);
    
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isConnected ? Colors.blue[100] : Colors.grey[100],
        child: Icon(
          Icons.person,
          color: isConnected ? Colors.blue[700] : Colors.grey[600],
        ),
      ),
      title: Text('مشارك: ${peerId.substring(0, 8)}...'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'الحالة: ${isConnected ? 'متصل' : 'غير متصل'}',
            style: TextStyle(
              fontSize: 12,
              color: isConnected ? Colors.green : Colors.red,
            ),
          ),
          if (hasAudio)
            const Text(
              'الصوت: متاح',
              style: TextStyle(
                fontSize: 11,
                color: Colors.blue,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected ? Icons.wifi : Icons.wifi_off,
            size: 16,
            color: isConnected ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 4),
          Icon(
            hasAudio ? Icons.volume_up : Icons.volume_off,
            size: 16,
            color: hasAudio ? Colors.blue : Colors.grey,
          ),
        ],
      ),
    );
  }
}
