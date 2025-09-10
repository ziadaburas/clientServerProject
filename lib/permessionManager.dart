
// ---------------------------
// مدير الأذونات المحسن
// ---------------------------
import 'package:permission_handler/permission_handler.dart';

import 'appLogger.dart';

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
