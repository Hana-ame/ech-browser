import 'package:ech_browser/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SettingsStore.uniqueFileName', () {
    test('不重名原样返回', () {
      expect(SettingsStore.uniqueFileName('a.jpg', (_) => false), 'a.jpg');
    });

    test('重名追加 (1)，再重名 (2)', () {
      final existing = <String>{'a.jpg', 'a (1).jpg'};
      expect(SettingsStore.uniqueFileName('a.jpg', existing.contains),
          'a (2).jpg');
    });

    test('无扩展名也能去重', () {
      final existing = <String>{'file'};
      expect(SettingsStore.uniqueFileName('file', existing.contains),
          'file (1)');
    });

    test('点开头的隐藏文件不当扩展名', () {
      final existing = <String>{'.gitignore'};
      expect(SettingsStore.uniqueFileName('.gitignore', existing.contains),
          '.gitignore (1)');
    });
  });

  group('SettingsStore 默认值', () {
    test('默认 DoH 为 moonchan.xyz', () {
      expect(SettingsStore().dohUrl, 'https://moonchan.xyz/doh');
    });
  });
}
