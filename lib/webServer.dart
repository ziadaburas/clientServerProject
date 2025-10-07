import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'appLogger.dart';

class WebServer {
  static const int MAX_CLIENTS = 10;
  
  HttpServer? _server;
  final Map<String, WebSocket> _clients = {};
  final Map<String, DateTime> _lastHeartbeat = {};
  Timer? _heartbeatTimer;

  bool get isRunning => _server != null;
  int get clientCount => _clients.length;
  static const allowedTypes = [
    'join',
    'offer',
    'answer',
    'candidate',
    'leave',
    'text-message'
  ];

  Future<int> start({int port = 5000}) async {
    if (_server != null) {
      AppLogger.info('الخادم يعمل بالفعل على المنفذ ${_server!.port}');
      return _server!.port;
    }

    try {
      // _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server = await HttpServer.bind("0.0.0.0", port);
      AppLogger.info('تم بدء خادم الإشارات على المنفذ $port');

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
      final id = const Uuid().v4();

      _clients[id] = socket;
      _lastHeartbeat[id] = DateTime.now();

      AppLogger.info(
          'عميل جديد متصل: $id (إجمالي العملاء: ${_clients.length})');

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
