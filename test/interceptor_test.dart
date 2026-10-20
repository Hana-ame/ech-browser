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

  group('Interceptor.originalHostHeader', () {
    test('默认端口省略', () {
      expect(Interceptor.originalHostHeader(Uri.parse('https://pixiv.net/a')),
          'pixiv.net');
      expect(Interceptor.originalHostHeader(Uri.parse('http://a.com/b')),
          'a.com');
    });

    test('非标准端口保留（:8080 / :8443）', () {
      expect(Interceptor.originalHostHeader(Uri.parse('https://x.com:8080/a')),
          'x.com:8080');
      expect(Interceptor.originalHostHeader(Uri.parse('http://y.com:8443/b')),
          'y.com:8443');
    });

    test('显式标准端口也省略', () {
      expect(Interceptor.originalHostHeader(Uri.parse('https://z.com:443/a')),
          'z.com');
      expect(Interceptor.originalHostHeader(Uri.parse('http://z.com:80/a')),
          'z.com');
    });
  });

  group('Interceptor.isInterceptable', () {
    test('GET/HEAD 可拦截转发', () {
      expect(Interceptor.isInterceptable('GET'), isTrue);
      expect(Interceptor.isInterceptable('HEAD'), isTrue);
      expect(Interceptor.isInterceptable('get'), isTrue);
    });

    test('带 body 方法放行直连（拦截层拿不到 body）', () {
      expect(Interceptor.isInterceptable('POST'), isFalse);
      expect(Interceptor.isInterceptable('PUT'), isFalse);
      expect(Interceptor.isInterceptable('PATCH'), isFalse);
      expect(Interceptor.isInterceptable('DELETE'), isFalse);
    });
  });
}
