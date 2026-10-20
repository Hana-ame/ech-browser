import 'package:ech_browser/interceptor.dart';
import 'package:ech_browser/main.dart';
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

    test('IPv6 主机自动保留方括号', () {
      expect(
          Interceptor.originalHostHeader(Uri.parse('http://[::1]:8443/status')),
          '[::1]:8443');
    });
  });

  group('Interceptor.isInterceptable', () {
    test('GET/HEAD/OPTIONS 可直接拦截转发', () {
      expect(Interceptor.isInterceptable('GET'), isTrue);
      expect(Interceptor.isInterceptable('HEAD'), isTrue);
      expect(Interceptor.isInterceptable('OPTIONS'), isTrue);
      expect(Interceptor.isInterceptable('get'), isTrue);
    });

    test('带 body 方法由 JS 桥接管，shouldInterceptRequest 返回 false', () {
      expect(Interceptor.isInterceptable('POST'), isFalse);
      expect(Interceptor.isInterceptable('PUT'), isFalse);
      expect(Interceptor.isInterceptable('PATCH'), isFalse);
      expect(Interceptor.isInterceptable('DELETE'), isFalse);
    });
  });

  group('Interceptor 重定向与响应头辅助函数', () {
    test('resolveRedirectUrl 正确处理绝对与相对 Location', () {
      final base = Uri.parse('https://pixiv.net/artworks/1');
      expect(
        Interceptor.resolveRedirectUrl(base, 'https://www.pixiv.net/artworks/1')
            .toString(),
        'https://www.pixiv.net/artworks/1',
      );
      expect(
        Interceptor.resolveRedirectUrl(base, '/login?return_to=%2F').toString(),
        'https://pixiv.net/login?return_to=%2F',
      );
      expect(Interceptor.resolveRedirectUrl(base, 'javascript:alert(1)'),
          isNull);
    });

    test('extractMimeType 与 extractCharset 正确分离 MIME 与字符集', () {
      expect(Interceptor.extractMimeType('text/html; charset=UTF-8'),
          'text/html');
      expect(
          Interceptor.extractCharset('text/html; charset=UTF-8'), 'UTF-8');
      expect(Interceptor.extractMimeType(null), 'application/octet-stream');
      expect(Interceptor.extractCharset(null), 'utf-8');
    });

    test('reasonPhraseForStatus 保证非空 reasonPhrase', () {
      expect(Interceptor.reasonPhraseForStatus(200, ''), 'OK');
      expect(Interceptor.reasonPhraseForStatus(521, null), 'Status 521');
      expect(Interceptor.reasonPhraseForStatus(404, 'Not Found'), 'Not Found');
    });
  });

  group('BrowserScreen 地址栏归一化与文件名清洗', () {
    test('normalizeInputToUrl 区分域名、本机地址与搜索词', () {
      expect(BrowserScreen.normalizeInputToUrl('www.pixiv.net'),
          'https://www.pixiv.net');
      expect(BrowserScreen.normalizeInputToUrl('localhost:8443/logs'),
          'http://localhost:8443/logs');
      expect(BrowserScreen.normalizeInputToUrl('127.0.0.1:8443'),
          'http://127.0.0.1:8443');
      expect(BrowserScreen.normalizeInputToUrl('pixiv 排行榜'),
          startsWith(kSearchEnginePrefix));
    });

    test('sanitizeFileName 阻止路径穿越与非法字符', () {
      final u = Uri.parse('https://i.pximg.net/img-original/12345_p0.jpg');
      expect(BrowserScreen.sanitizeFileName(null, u), '12345_p0.jpg');
      expect(BrowserScreen.sanitizeFileName('../../etc/passwd', u),
          '____etc_passwd');
      expect(BrowserScreen.sanitizeFileName('a<b>c:d*e?.png', u),
          'a_b_c_d_e_.png');
    });
  });
}
