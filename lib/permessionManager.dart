import 'package:flutter/material.dart';
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
  
  static void showPermissionDialog(context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('أذونات مطلوبة'),
      content: const Text(
          'هذا التطبيق يحتاج إلى إذن الوصول للميكروفون والكاميرا لإجراء مكالمات الفيديو. '
          'يرجى السماح بالوصول للميكروفون والكاميرا للمتابعة.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await PermissionManager.requestAllPermissions();
          },
          child: const Text('طلب الأذونات'),
        ),
      ],
    ),
  );
}

  static Future<bool> requestCameraPermission() async {
  try {
    AppLogger.info('طلب إذن الكاميرا...');
    final status = await Permission.camera.request();
    
    if (status.isGranted) {
      AppLogger.info('تم منح إذن الكاميرا');
      return true;
    } else if (status.isDenied) {
      AppLogger.warning('تم رفض إذن الكاميرا');
      return false;
    } else if (status.isPermanentlyDenied) {
      AppLogger.error('تم رفض إذن الكاميرا نهائياً');
      await openAppSettings();
      return false;
    }
  } catch (e) {
    AppLogger.error('خطأ في طلب إذن الكاميرا: $e');
  }
  return false;
}

  static Future<bool> checkCameraPermission() async {
    final status = await Permission.camera.status;
    return status.isGranted;
  }

  static Future<bool> requestAllPermissions() async {
    final micPermission = await requestMicrophonePermission();
    final cameraPermission = await requestCameraPermission();
    return micPermission && cameraPermission;
  }

  static Future<bool> checkAllPermissions() async {
  final micPermission = await checkMicrophonePermission();
  final cameraPermission = await checkCameraPermission();
  return micPermission && cameraPermission;
}

}
