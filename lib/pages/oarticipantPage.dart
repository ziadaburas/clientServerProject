
// ---------------------------
// صفحة المشارك المحسنة
// ---------------------------
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../appLogger.dart';
import '../audioQuality.dart';
import '../permessionManager.dart';
import '../reconnectManger.dart';
import 'roleSelectPage.dart';

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
