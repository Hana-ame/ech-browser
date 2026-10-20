import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'proxy_manager.dart';

/// 逐跳头：描述"上一跳到下一跳"，不能透传给本地回环内核上游。
const _hopByHop = <String>{
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

/// 拦截层直接转发的无请求体方法：GET / HEAD / OPTIONS（含 CORS 预检）。
/// 带 body 的 POST/PUT/PATCH/DELETE 通过注入的 JS fetch/XHR 桥调用 [forwardRequest] 转发。
const _interceptableMethods = {'GET', 'HEAD', 'OPTIONS'};

/// 重定向状态码集合。
const _redirectStatuses = {301, 302, 303, 307, 308};

/// 供上层处理响应中的 Set-Cookie（同步到 WebView CookieManager）。
typedef SetCookiesCallback = FutureOr<void> Function(
    Uri url, List<String> rawSetCookies);

/// 通用代理转发响应模型（供拦截器与 JS 桥共用）。
class ProxiedHttpResponse {
  const ProxiedHttpResponse({
    required this.finalUrl,
    required this.statusCode,
    required this.reasonPhrase,
    required this.mimeType,
    required this.charset,
    required this.headers,
    required this.setCookies,
    required this.body,
  });

  final Uri finalUrl;
  final int statusCode;
  final String reasonPhrase;
  final String mimeType;
  final String charset;
  final Map<String, String> headers;
  final List<String> setCookies;
  final Uint8List body;
}

/// 把 webview 的资源请求改写到本地 go 内核回环代理（保留原始 Host 与协议）。
/// webview 永远只与 127.0.0.1 打交道 → 不需要改系统 hosts、不需要装证书。
class Interceptor {
  Interceptor(this.proxy, {this.onSetCookies});

  final ProxyManager proxy;
  final SetCookiesCallback? onSetCookies;

  static const int maxRedirects = 8;

  /// 复用连接池且禁用自动解压的 HttpClient：
  /// 关键修复：dart:io 默认 autoUncompress=true 会把上游 gzip/deflate 解压成明文，
  /// 但响应头仍保留 Content-Encoding: gzip，导致 WebView 二次解压报错 ERR_CONTENT_DECODING_FAILED。
  late final io.HttpClient _rawClient = io.HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 60)
    ..maxConnectionsPerHost = 64;

  /// 下载专用 HttpClient（开启自动解压，直接拿到解压后的文件字节）。
  late final io.HttpClient _downloadClient = io.HttpClient()
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 60);

  /// 改写规则（纯函数，便于单测）：原始 URL → 本地回环 URL。
  static Uri localTarget(int port, Uri url) {
    final path = url.path.isEmpty ? '/' : url.path;
    final query = url.hasQuery ? '?${url.query}' : '';
    return Uri.parse('http://127.0.0.1:$port$path$query');
  }

  /// 原始 Host 头（纯函数）：保留非标准端口（Uri.host 不含端口，IPv6 自动加方括号）。
  /// 例：https://example.com:8080/x → "example.com:8080"
  static String originalHostHeader(Uri url) {
    final rawHost = url.host.contains(':') && !url.host.startsWith('[')
        ? '[${url.host}]'
        : url.host;
    if (url.hasPort &&
        !(url.scheme == 'http' && url.port == 80) &&
        !(url.scheme == 'https' && url.port == 443)) {
      return '$rawHost:${url.port}';
    }
    return rawHost;
  }

  /// 当前请求方法是否可经 shouldInterceptRequest 直接拦截转发（GET/HEAD/OPTIONS）。
  static bool isInterceptable(String method) =>
      _interceptableMethods.contains(method.trim().toUpperCase());

  /// 判断状态码是否属于需要代理内部跟随的 3xx 重定向。
  static bool isRedirectStatus(int statusCode) =>
      _redirectStatuses.contains(statusCode);

  /// 解析重定向目标 URL（支持绝对路径与相对路径，纯函数便于单测）。
  static Uri? resolveRedirectUrl(Uri currentUrl, String? locationHeader) {
    if (locationHeader == null) return null;
    final loc = locationHeader.trim();
    if (loc.isEmpty) return null;
    try {
      final resolved = currentUrl.resolve(loc);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') {
        return null;
      }
      return resolved;
    } catch (_) {
      return null;
    }
  }

  /// 提取不带参数的純 MIME 类型（修复 Android WebView 传入 "text/html; charset=utf-8" 无法渲染页面问题）。
  static String extractMimeType(String? contentTypeHeader) {
    if (contentTypeHeader == null || contentTypeHeader.trim().isEmpty) {
      return 'application/octet-stream';
    }
    final semi = contentTypeHeader.indexOf(';');
    final mime = (semi >= 0
            ? contentTypeHeader.substring(0, semi)
            : contentTypeHeader)
        .trim()
        .toLowerCase();
    return mime.isEmpty ? 'application/octet-stream' : mime;
  }

  /// 提取字符集编码（默认 utf-8）。
  static String extractCharset(String? contentTypeHeader) {
    if (contentTypeHeader == null) return 'utf-8';
    final match = RegExp(r'charset\s*=\s*"?([^";\s]+)"?', caseSensitive: false)
        .firstMatch(contentTypeHeader);
    final cs = match?.group(1)?.trim();
    return (cs != null && cs.isNotEmpty) ? cs : 'utf-8';
  }

  /// 确保 reasonPhrase 绝不为空（Android WebView WebResourceResponse 要求 reasonPhrase 非空，否则抛 IllegalArgumentException）。
  static String reasonPhraseForStatus(int statusCode, [String? rawReason]) {
    final trimmed = rawReason?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    switch (statusCode) {
      case 200:
        return 'OK';
      case 201:
        return 'Created';
      case 204:
        return 'No Content';
      case 206:
        return 'Partial Content';
      case 301:
        return 'Moved Permanently';
      case 302:
        return 'Found';
      case 304:
        return 'Not Modified';
      case 400:
        return 'Bad Request';
      case 401:
        return 'Unauthorized';
      case 403:
        return 'Forbidden';
      case 404:
        return 'Not Found';
      case 500:
        return 'Internal Server Error';
      case 502:
        return 'Bad Gateway';
      case 503:
        return 'Service Unavailable';
      case 504:
        return 'Gateway Timeout';
      default:
        return 'Status $statusCode';
    }
  }

  /// 执行经本地回环内核的请求（自动在内核侧跟随 3xx 重定向，防止 dart:io 直连绕过 ECH 或丢失 Host）。
  Future<ProxiedHttpResponse?> forwardRequest({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    Uint8List? body,
    bool autoUncompress = false,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final port = proxy.port;
    if (port <= 0) return null;

    final client = autoUncompress ? _downloadClient : _rawClient;
    var currentUrl = url;
    var currentMethod = method.trim().toUpperCase();
    var currentBody = body;
    final collectedCookies = <String>[];

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final local = localTarget(port, currentUrl);
      final req = await client.openUrl(currentMethod, local);
      req.followRedirects = false;
      req.persistentConnection = true;

      req.headers.set(io.HttpHeaders.hostHeader, originalHostHeader(currentUrl));
      req.headers.set('X-ECH-Scheme', currentUrl.scheme);

      headers?.forEach((key, value) {
        final k = key.toLowerCase();
        if (k == 'host' || k == 'x-ech-scheme' || _hopByHop.contains(k)) return;
        // 跨域重定向后不自动携带原域名的 Authorization
        if (hop > 0 && k == 'authorization' && currentUrl.host != url.host) {
          return;
        }
        req.headers.set(key, value);
      });

      if (currentBody != null && currentBody.isNotEmpty) {
        req.contentLength = currentBody.length;
        req.add(currentBody);
      }

      final resp = await req.close();

      // 提取当前跳的 Set-Cookie（不能用 ', ' 拼接，否则 Expires=Wed, ... 中的逗号会破坏 Cookie 解析）
      final rawCookies =
          resp.headers[io.HttpHeaders.setCookieHeader] ?? const <String>[];
      if (rawCookies.isNotEmpty) {
        collectedCookies.addAll(rawCookies);
        if (onSetCookies != null) {
          await onSetCookies!(currentUrl, rawCookies);
        }
      }

      if (isRedirectStatus(resp.statusCode) && hop < maxRedirects) {
        final loc = resp.headers.value(io.HttpHeaders.locationHeader);
        final nextUrl = resolveRedirectUrl(currentUrl, loc);
        if (nextUrl != null) {
          await resp.drain<void>();
          currentUrl = nextUrl;
          if (resp.statusCode == 303 ||
              ((resp.statusCode == 301 || resp.statusCode == 302) &&
                  currentMethod == 'POST')) {
            currentMethod = 'GET';
            currentBody = null;
          }
          continue;
        }
      }

      final outHeaders = <String, String>{};
      resp.headers.forEach((k, v) {
        final lower = k.toLowerCase();
        if (_hopByHop.contains(lower)) return;
        if (autoUncompress &&
            (lower == 'content-encoding' || lower == 'content-length')) {
          return;
        }
        if (lower == 'set-cookie') {
          // Map<String, String> 仅能保留单值，多条 Set-Cookie 已通过 onSetCookies 写入 CookieManager
          if (v.isNotEmpty) {
            outHeaders[k] = v.first;
          }
          return;
        }
        outHeaders[k] = v.join(', ');
      });

      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      final respBytes = builder.toBytes();

      final rawCt = resp.headers.value(io.HttpHeaders.contentTypeHeader);
      return ProxiedHttpResponse(
        finalUrl: currentUrl,
        statusCode: resp.statusCode,
        reasonPhrase: reasonPhraseForStatus(resp.statusCode, resp.reasonPhrase),
        mimeType: extractMimeType(rawCt),
        charset: extractCharset(rawCt),
        headers: outHeaders,
        setCookies: collectedCookies,
        body: respBytes,
      );
    }

    return null;
  }

  /// 拦截回调：http(s) 的 GET/HEAD/OPTIONS → 本地回环内核 → 返回响应。
  /// - 非 http(s) / 带 body 方法：返回 null 放行（或由 JS 桥接管）
  /// - 内核未就绪或链路出错：返回 null 让 webview 走默认（不闪退）
  Future<WebResourceResponse?> onShouldInterceptRequest(
      InAppWebViewController controller, WebResourceRequest request) async {
    final url = request.url;
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final method = (request.method ?? 'GET').toUpperCase();
    if (!isInterceptable(method)) return null;

    if (proxy.port <= 0) return null;

    try {
      final proxied = await forwardRequest(
        method: method,
        url: url,
        headers: request.headers,
        autoUncompress: false,
      );
      if (proxied == null) return null;

      return WebResourceResponse(
        contentType: proxied.mimeType,
        contentEncoding: proxied.charset,
        statusCode: proxied.statusCode,
        reasonPhrase: proxied.reasonPhrase,
        headers: proxied.headers,
        data: proxied.body,
      );
    } catch (_) {
      // 内核链路出错：放行默认，避免整页闪退。
      return null;
    }
  }

  /// 经内核拉取完整解压后字节（下载等场景复用；支持携带 Referer / Cookie / User-Agent 防盗链）。失败返回 null。
  Future<Uint8List?> fetchBytes(
    Uri url, {
    Map<String, String>? headers,
    String? referer,
    String? cookie,
    String? userAgent,
  }) async {
    try {
      final merged = <String, String>{
        'Accept': '*/*',
        'Accept-Encoding': 'gzip, deflate',
        if (headers != null) ...headers,
      };
      if (referer != null && referer.isNotEmpty) {
        merged['Referer'] = referer;
      }
      if (cookie != null && cookie.isNotEmpty) {
        merged['Cookie'] = cookie;
      }
      if (userAgent != null && userAgent.isNotEmpty) {
        merged['User-Agent'] = userAgent;
      }
      final proxied = await forwardRequest(
        method: 'GET',
        url: url,
        headers: merged,
        autoUncompress: true,
      );
      if (proxied == null ||
          proxied.statusCode < 200 ||
          proxied.statusCode >= 300) {
        return null;
      }
      return proxied.body;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _rawClient.close(force: true);
    _downloadClient.close(force: true);
  }
}
