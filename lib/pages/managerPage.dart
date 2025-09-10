// ---------------------------
// صفحة المدير المحسنة
// ---------------------------
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../appLogger.dart';
import '../embdServer.dart';
import 'oarticipantPage.dart';

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
