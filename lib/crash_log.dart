import 'dart:io';

/// 未捕获异常/崩溃日志（`~/.ech-browser/crash.log`）。
///
/// 目的：Windows 上"闪退"时进程内的任何缓冲都会消失，只有落盘文件能回传定位。
/// 所有 IO 失败静默，绝不影响主流程。
class CrashLog {
  static String? _cached;

  /// 纯函数：计算日志路径（便于单测）；home 为空时回落临时目录。
  static String pathFor(String? home, String tempDir) {
    final sep = Platform.pathSeparator;
    if (home != null && home.isNotEmpty) {
      return '$home$sep.ech-browser${sep}crash.log';
    }
    return '$tempDir${sep}ech-browser-crash.log';
  }

  static String path() {
    final cached = _cached;
    if (cached != null) return cached;
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    _cached = pathFor(home, Directory.systemTemp.path);
    return _cached!;
  }

  static Future<void> write(String source, Object error,
      [StackTrace? stackTrace]) async {
    try {
      final f = File(path());
      await f.parent.create(recursive: true);
      final ts = DateTime.now().toIso8601String();
      final body = '[$ts] [$source] $error\n${stackTrace ?? ''}\n';
      await f.writeAsString(body, mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写入失败不能影响主流程
    }
  }
}
