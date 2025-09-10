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
