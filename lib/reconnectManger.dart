import 'dart:async';
import './appLogger.dart';

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
