// ---------------------------
// مراقب جودة الصوت
// ---------------------------
import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'appLogger.dart';

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

