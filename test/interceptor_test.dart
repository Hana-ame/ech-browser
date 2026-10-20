import 'package:ech_browser/interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Interceptor.localTarget', () {
    test('改写保留 path 与 query', () {
      final u = Uri.parse('https://www.pixiv.net/artworks/123456?lang=zh');
      final t = Interceptor.localTarget(8443, u);
      expect(t.toString(), 'http://127.0.0.1:8443/artworks/123456?lang=zh');
    });

    test('空 path 归一化为 /', () {
      final u = Uri.parse('https://www.pixiv.net');
      final t = Interceptor.localTarget(8443, u);
      expect(t.toString(), 'http://127.0.0.1:8443/');
    });

    test('无 query 不带问号', () {
      final u = Uri.parse('https://example.com/a/b');
      final t = Interceptor.localTarget(8080, u);
      expect(t.toString(), 'http://127.0.0.1:8080/a/b');
    });
  });
}
