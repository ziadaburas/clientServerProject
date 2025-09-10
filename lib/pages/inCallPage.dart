import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../appLogger.dart';
import '../permessionManager.dart';
import '../reconnectManger.dart';

class InCallPage extends StatefulWidget {
  final String initialServer;
  final bool isManager;
  final String ip;
  final int port;

  const InCallPage({
    super.key,
    required this.ip,
    this.port = 5000,
    this.isManager = false,
  }) : initialServer = 'ws://$ip:$port';

  @override
  State<InCallPage> createState() => _InCallPageState();
}

class _InCallPageState extends State<InCallPage> with WidgetsBindingObserver {
  // Controllers
  final _serverController = TextEditingController();
  final _nameController = TextEditingController(text: 'مستخدم');
  // Video renderers
  RTCVideoRenderer? _localVideoRenderer;
  final Map<String, RTCVideoRenderer> _remoteVideoRenderers = {};

  // Video state
  bool _videoEnabled = true;
  bool _frontCamera = true;

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

  // Video UI state
  bool _isLocalVideoExpanded = false;


  // Managers
  ReconnectionManager? _reconnectionManager;

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
    _serverController.text = widget.initialServer;

    if (widget.isManager) {
      _nameController.text = 'المدير';
    }

    // إعداد مدير إعادة الاتصال
    _reconnectionManager = ReconnectionManager(
      onReconnect: _attemptReconnection,
      onStatusUpdate: _updateConnectionStatus,
    );

    Future.delayed(const Duration(milliseconds: 1), () {
      _connectToServer();
    });
  }

  void _updateConnectionStatus(String status) {
    if (mounted) {
      setState(() => _connectionStatus = status);
    }
  }

  Map<String, dynamic> _getOptimizedMediaConstraints() {
  return {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'sampleRate': 48000,
      'channelCount': 1,
    },
    'video': _videoEnabled ? {
      'width': {'ideal': 640},
      'height': {'ideal': 480},
      'frameRate': {'ideal': 30},
      'facingMode': _frontCamera ? 'user' : 'environment',
    } : false,
  };
}

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

  Future<void> _toggleVideo() async {
  if (_localStream == null) return;

  final videoTracks = _localStream!.getVideoTracks();
  if (videoTracks.isNotEmpty) {
    final enabled = !videoTracks.first.enabled;
    videoTracks.first.enabled = enabled;

    setState(() => _videoEnabled = enabled);
    AppLogger.info('حالة الفيديو: ${enabled ? 'مفعل' : 'معطل'}');

    if (!enabled && _localVideoRenderer != null) {
      _localVideoRenderer!.srcObject = null;
    } else if (enabled && _localVideoRenderer != null) {
      _localVideoRenderer!.srcObject = _localStream;
    }
  }
}

Future<void> _switchCamera() async {
  if (_localStream == null) return;

  final videoTracks = _localStream!.getVideoTracks();
  if (videoTracks.isNotEmpty) {
    await Helper.switchCamera(videoTracks.first);
    setState(() => _frontCamera = !_frontCamera);
    AppLogger.info('تم تبديل الكاميرا إلى: ${_frontCamera ? 'الأمامية' : 'الخلفية'}');
  }
}

  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
  if (_peerConnections.containsKey(peerId)) {
    AppLogger.info('اتصال الند موجود بالفعل: $peerId');
    return _peerConnections[peerId]!;
  }

  try {
    AppLogger.info('إنشاء اتصال ند جديد: $peerId');

    final config = _getOptimizedRTCConfiguration();
    final pc = await createPeerConnection(config);

    // إضافة المسارات المحلية
    final localStream = await _openLocalMediaStream();

    for (final track in localStream.getTracks()) {
      await pc.addTrack(track, localStream);
      AppLogger.info('تم إضافة مسار ${track.kind} للند $peerId');
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

      if (event.streams.isNotEmpty) {
        if (event.track.kind == 'audio') {
          await _handleRemoteAudioTrack(peerId, event.streams[0]);
        } else if (event.track.kind == 'video') {
          await _handleRemoteVideoTrack(peerId, event.streams[0]);
        }
      }
    };

    // باقي الكود كما هو...
    pc.onConnectionState = (RTCPeerConnectionState state) {
      AppLogger.info('حالة اتصال الند $peerId: $state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        // Connected
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _handlePeerDisconnection(peerId);
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      AppLogger.info('حالة ICE للند $peerId: $state');

      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _handlePeerDisconnection(peerId);
      }
    };

    _peerConnections[peerId] = pc;
    return pc;
  } catch (e) {
    AppLogger.error('فشل في إنشاء اتصال الند $peerId: $e');
    rethrow;
  }
}

  Future<MediaStream> _openLocalMediaStream() async {
  if (_localStream != null) {
    AppLogger.info('تدفق الوسائط المحلي موجود بالفعل');
    return _localStream!;
  }

  try {
    AppLogger.info('فتح تدفق الوسائط المحلي...');

    final constraints = _getOptimizedMediaConstraints();
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);

    // تهيئة معرض الفيديو المحلي
    if (_videoEnabled) {
      _localVideoRenderer ??= RTCVideoRenderer();
      await _localVideoRenderer!.initialize();
      _localVideoRenderer!.srcObject = _localStream;
    }

    final audioTracks = _localStream!.getAudioTracks();
    final videoTracks = _localStream!.getVideoTracks();
    AppLogger.info('تم فتح تدفق الوسائط: ${audioTracks.length} صوت، ${videoTracks.length} فيديو');

    return _localStream!;
  } catch (e) {
    AppLogger.error('فشل في فتح تدفق الوسائط: $e');

    final hasPermissions = await PermissionManager.requestAllPermissions();
    if (!hasPermissions) {
      throw Exception('لم يتم منح الأذونات المطلوبة');
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
      AppLogger.info('حالة الميكروفون: ${enabled ? 'مفعل' : 'مكتوم'}');
    }
  }

  Future<void> _toggleSpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(!_speakerOn);
      setState(() => _speakerOn = !_speakerOn);
      AppLogger.info('حالة السماعة: ${_speakerOn ? 'مفعلة' : 'معطلة'}');
    } catch (e) {
      AppLogger.error('فشل في تغيير حالة السماعة: $e');
    }
  }

  Future<void> _handleRemoteAudioTrack(
      String peerId, MediaStream stream) async {
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

  Future<void> _handleRemoteVideoTrack(String peerId, MediaStream stream) async {
  try {
    AppLogger.info('معالجة مسار فيديو بعيد من $peerId');

    if (!_remoteVideoRenderers.containsKey(peerId)) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _remoteVideoRenderers[peerId] = renderer;
    }

    _remoteVideoRenderers[peerId]!.srcObject = stream;

    if (mounted) {
      setState(() {});
    }
  } catch (e) {
    AppLogger.error('فشل في معالجة الفيديو البعيد من $peerId: $e');
  }
}


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
    } catch (e) {
      AppLogger.error('فشل في إنشاء عرض للند $peerId: $e');
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
    } catch (e) {
      AppLogger.error('فشل في معالجة عرض من $fromPeer: $e');
    }
  }

  Future<void> _handleAnswer(
      String fromPeer, String sdp, String sdpType) async {
    try {
      AppLogger.info('معالجة إجابة من الند: $fromPeer');

      final pc = _peerConnections[fromPeer];
      if (pc == null) {
        AppLogger.warning('لا يوجد اتصال ند للإجابة من $fromPeer');
        return;
      }

      await pc.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
    } catch (e) {
      AppLogger.error('فشل في معالجة إجابة من $fromPeer: $e');
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

  Future<void> _connectToServer() async {
    if (_isConnecting || _isConnected) {
      AppLogger.info('الاتصال جاري بالفعل أو متصل');
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionStatus = 'جاري الاتصال...';
    });

    try {
      AppLogger.info('الاتصال بخادم الإشارات: ${widget.initialServer}');

      _signalingChannel = IOWebSocketChannel.connect(widget.initialServer);

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
    } catch (e) {
      AppLogger.error('فشل في الاتصال بالخادم: $e');

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

    // بدء إعادة الاتصال
    _reconnectionManager?.startReconnection();
  }

  void _handleSignalingDisconnection() {
    AppLogger.info('انقطع اتصال الإشارة');

    setState(() {
      _isConnected = false;
      _connectionStatus = 'منقطع';
    });

    // بدء إعادة الاتصال التلقائي
    if (!widget.isManager) {
      // المدير لا يعيد الاتصال تلقائياً
      _reconnectionManager?.startReconnection();
    }
  }

  void _handleSignalingError(dynamic error) {
    AppLogger.error('خطأ في اتصال الإشارة: $error');

    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _connectionStatus = 'خطأ في الاتصال';
    });

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

  // إزالة معرض الصوت
  final renderer = _remoteRenderers.remove(peerId);
  if (renderer != null) {
    try {
      await renderer.dispose();
    } catch (e) {
      AppLogger.error('خطأ في تنظيف معرض الصوت للند $peerId: $e');
    }
  }

  // إزالة معرض الفيديو
  final videoRenderer = _remoteVideoRenderers.remove(peerId);
  if (videoRenderer != null) {
    try {
      await videoRenderer.dispose();
    } catch (e) {
      AppLogger.error('خطأ في تنظيف معرض الفيديو للند $peerId: $e');
    }
  }

  // تحديث قائمة الأقران
  if (mounted) {
    setState(() {
      _connectedPeers.remove(peerId);
    });
  }
}

  Future<void> _cleanupSignaling() async {
    try {
      await _signalingChannel?.sink.close();
    } catch (e) {
      AppLogger.error('خطأ في إغلاق قناة الإشارة: $e');
    }
    _signalingChannel = null;
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
    if (_isConnected) {
      _sendSignalingMessage({'type': 'leave'});
    }

    if (mounted) {
      // Navigator.of(context).pushAndRemoveUntil(
      //   MaterialPageRoute(builder: (_) => const RoleSelectPage()),
      //   (route) => false,
      // );
      Navigator.of(context).pop();
    }
  }

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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isManager ? 'المدير - مكالمة فيديو' : 'مكالمة فيديو'),
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
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black,
        child: Stack(
          children: [
            // منطقة عرض الفيديو الرئيسية
            if (_remoteVideoRenderers.isNotEmpty)
              _buildMainVideoView()
            else
              _buildWaitingView(),

            // الفيديو المحلي (صغير في الزاوية)
  if (_localVideoRenderer != null && _videoEnabled)
    Positioned(
      top: _getLocalVideoPosition().dy,
      right: _getLocalVideoPosition().dx,
      child: GestureDetector(
        onTap: _toggleLocalVideoSize, // إضافة إمكانية النقر لتكبير/تصغير
        child: Container(
          width: _isLocalVideoExpanded ? 200 : 120,
          height: _isLocalVideoExpanded ? 150 : 160,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white, width: 2),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                RTCVideoView(
                  _localVideoRenderer!,
                  mirror: _frontCamera,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
                // أيقونة صغيرة تدل على أنه فيديو محلي
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.person,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),

            // شريط المعلومات العلوي
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
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
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (_isConnected) ...[
                        Icon(
                          Icons.people,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${_connectedPeers.length + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            // أزرار التحكم السفلية
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withOpacity(0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: _isConnected ? _buildControlButtons() : _buildConnectingView(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainVideoView() {

    if (_remoteVideoRenderers.isEmpty) {
      return _buildWaitingView();
    }
    return _buildGridVideoView();
  }

  Widget _buildGridVideoView() {
    final peers = _remoteVideoRenderers.keys.toList();
    
  return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        children:List.generate (peers.length, (index) {
          final peerId = peers[index];
          return Expanded(child: _buildRemoteVideoTile(peerId));
        }),
      ),
    );
    
  }

  Widget _buildRemoteVideoTile(String peerId) {
    final renderer = _remoteVideoRenderers[peerId];
    final isConnected = _peerConnections.containsKey(peerId);
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConnected ? Colors.green : Colors.red,
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // الفيديو أو الأفاتار
            if (renderer != null && renderer.srcObject != null)
              Container(
                width: double.infinity,
                height: double.infinity,
                child: RTCVideoView(
                  renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.grey[800],
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: Colors.blue[700],
                      child: Icon(
                        Icons.person,
                        size: 35,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'بدون فيديو',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

            // معلومات المشارك
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'مشارك ${peerId.substring(0, 6)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // أيقونة حالة الصوت
                    Icon(
                      Icons.volume_up,
                      size: 14,
                      color: isConnected ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 2),
                    // أيقونة حالة الفيديو
                    Icon(
                      renderer?.srcObject != null ? Icons.videocam : Icons.videocam_off,
                      size: 14,
                      color: renderer?.srcObject != null ? Colors.green : Colors.grey,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaitingView() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.videocam_off,
            size: 80,
            color: Colors.white.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'في انتظار المشاركين...',
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 18,
            ),
          ),
          if (widget.isManager) ...[
            const SizedBox(height: 8),
            Text(
              'شارك هذا العنوان: ${widget.ip}:${widget.port}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 14,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControlButtons() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // زر الميكروفون
          _buildControlButton(
            icon: _microphoneMuted ? Icons.mic_off : Icons.mic,
            label: _microphoneMuted ? 'مكتوم' : 'صوت',
            color: _microphoneMuted ? Colors.red : Colors.white,
            onPressed: _toggleMicrophone,
          ),

          const SizedBox(width: 8),

          // زر الفيديو
          _buildControlButton(
            icon: _videoEnabled ? Icons.videocam : Icons.videocam_off,
            label: _videoEnabled ? 'فيديو' : 'معطل',
            color: _videoEnabled ? Colors.white : Colors.red,
            onPressed: _toggleVideo,
          ),

          const SizedBox(width: 8),

          // زر تبديل الكاميرا
          _buildControlButton(
            icon: Icons.flip_camera_ios,
            label: 'تبديل',
            color: Colors.white,
            onPressed: _videoEnabled ? _switchCamera : null,
          ),

          const SizedBox(width: 8),

          // زر السماعة
          _buildControlButton(
            icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
            label: _speakerOn ? 'سماعة' : 'صامت',
            color: _speakerOn ? Colors.white : Colors.grey,
            onPressed: _toggleSpeaker,
          ),

          const SizedBox(width: 8),

          // زر إعادة تهيئة الفيديو
          _buildControlButton(
            icon: Icons.refresh,
            label: 'تحديث',
            color: Colors.orange,
            onPressed: _refreshVideoConnections,
          ),

          const SizedBox(width: 8),

          // زر إنهاء المكالمة
          _buildControlButton(
            icon: Icons.call_end,
            label: 'إنهاء',
            color: Colors.red,
            onPressed: _leaveCall,
            isEndCall: true,
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
    bool isEndCall = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isEndCall ? Colors.red : Colors.white.withOpacity(0.2),
            shape: BoxShape.circle,
            border: Border.all(
              color: color.withOpacity(0.5),
              width: 1,
            ),
          ),
          child: IconButton(
            onPressed: onPressed,
            icon: Icon(icon),
            color: color,
            iconSize: 28,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text(
            'جاري الاتصال...',
            style: TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }
  // دالة لتحديد موضع الفيديو المحلي بناءً على عدد المشاركين
  Offset _getLocalVideoPosition() {
    // إذا كان هناك مشاركون كثر، ضع الفيديو في موضع مختلف
    if (_remoteVideoRenderers.length > 4) {
      return const Offset(16, 200);
    } else if (_remoteVideoRenderers.length > 2) {
      return const Offset(16, 150);
    }
    return const Offset(16, 100);
  }

  // دالة لتبديل حجم الفيديو المحلي
  void _toggleLocalVideoSize() {
    setState(() {
      _isLocalVideoExpanded = !_isLocalVideoExpanded;
    });
  }
  // دالة لإعادة تهيئة الفيديو في حالة حدوث مشاكل
  Future<void> _refreshVideoConnections() async {
    AppLogger.info('إعادة تهيئة اتصالات الفيديو...');
    
    for (final peerId in _connectedPeers) {
      final pc = _peerConnections[peerId];
      if (pc != null) {
        // إعادة تعيين المسارات
        try {
          final localStream = await _openLocalMediaStream();
          final senders = await pc.getSenders();
          
          // تحديث مسار الفيديو إذا لزم الأمر
          for (final sender in senders) {
            if (sender.track?.kind == 'video') {
              final videoTracks = localStream.getVideoTracks();
              if (videoTracks.isNotEmpty) {
                await sender.replaceTrack(videoTracks.first);
                AppLogger.info('تم تحديث مسار الفيديو للند $peerId');
              }
            }
          }
        } catch (e) {
          AppLogger.error('فشل في تحديث مسار الفيديو للند $peerId: $e');
        }
      }
    }
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
