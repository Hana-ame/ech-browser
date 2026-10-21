import 'package:ech_browser/crash_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CrashLog.pathFor', () {
    test('有 home 时落 ~/.ech-browser/crash.log（分隔符随平台）', () {
      final p = CrashLog.pathFor('/home/u', '/tmp');
      expect(p, contains('.ech-browser'));
      expect(p, endsWith('crash.log'));
      expect(p, startsWith('/home/u'));
    });

    test('无 home 时回落临时目录', () {
      final p = CrashLog.pathFor(null, '/tmp');
      expect(p, '/tmp${p.contains('\\') ? '\\' : '/'}ech-browser-crash.log');
    });

    test('空 home 也回落临时目录', () {
      expect(CrashLog.pathFor('', '/tmp'), contains('ech-browser-crash.log'));
    });
  });
}
