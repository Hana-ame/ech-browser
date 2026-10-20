import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'proxy_manager.dart';

/// 逐跳头：描述"上一跳到下一跳"，不能透传给本地回环内核上游。
const _hopByHop = <String>{
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade',
};

/// 拦截层支持的方法：GET/HEAD 无 body，可完整经内核转发。
/// POST/PUT/PATCH/DELETE 等带 body 的方法在 flutter_inappwebview 6.1.5
/// shouldInterceptRequest 里拿不到 body（平台 API 硬限制），强行转发会丢 body
/// 破坏请求——策略是**放行直连**（功能可用，只是不经 ECH），并在状态栏提示。
const _interceptableMethods = {'GET', 'HEAD'};

/// 把 webview 的资源请求改写到本地 go 内核回环代理（保留原始 Host）。
/// webview 永远只与 127.0.0.1 打交道 → 不需要改系统 hosts、不需要装证书。
class Interceptor {
  Interceptor(this.proxy);
  final ProxyManager proxy;

  /// 改写规则（纯函数，便于单测）：原始 URL → 本地回环 URL。
  static Uri localTarget(int port, Uri url) {
    final path = url.path.isEmpty ? '/' : url.path;
    final query = url.hasQuery ? '?${url.query}' : '';
    return Uri.parse('http://127.0.0.1:$port$path$query');
  }

  /// 原始 Host 头（纯函数）：保留非标准端口（Uri.host 不含端口）。
  /// 例：https://example.com:8080/x → "example.com:8080"
  static String originalHostHeader(Uri url) {
    if (url.hasPort &&
        !(url.scheme == 'http' && url.port == 80) &&
        !(url.scheme == 'https' && url.port == 443)) {
      return '${url.host}:${url.port}';
    }
    return url.host;
  }

  /// 当前请求是否可经拦截层完整转发（GET/HEAD）。
  static bool isInterceptable(String method) =>
      _interceptableMethods.contains(method.toUpperCase());

  /// 拦截回调：http(s) 的 GET/HEAD → 本地回环内核 → 返回响应。
  /// - 非 http(s) / 带 body 方法：返回 null 放行默认（直连或失败页）
  /// - 内核未就绪或链路出错：返回 null 让 webview 走默认（不闪退）
  Future<WebResourceResponse?> onShouldInterceptRequest(
      InAppWebViewController controller, WebResourceRequest request) async {
    final url = request.url;
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final method = (request.method ?? 'GET').toUpperCase();
    if (!isInterceptable(method)) return null;

    final port = proxy.port;
    if (port <= 0) return null;

    final client = io.HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);

    try {
      final local = localTarget(port, url);
      final req = await client.openUrl(method, local);
      req.headers.set(io.HttpHeaders.hostHeader, originalHostHeader(url));

      request.headers?.forEach((key, value) {
        final k = key.toLowerCase();
        if (k == 'host' || _hopByHop.contains(k)) return;
        req.headers.set(key, value);
      });

      final resp = await req.close();
      final headers = <String, String>{};
      resp.headers.forEach((k, v) => headers[k] = v.join(', '));

      // 6.1.5 的 WebResourceResponse.data 是 Uint8List?（整包缓冲，不支持流）：
      // 大媒体靠 Range 分块缓解（视频播放器按段请求，每段体量小）。
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      final body = builder.toBytes();

      return WebResourceResponse(
        contentType:
            resp.headers.contentType?.toString() ?? 'application/octet-stream',
        statusCode: resp.statusCode,
        reasonPhrase: resp.reasonPhrase,
        headers: headers,
        data: body,
      );
    } catch (_) {
      // 内核链路出错：放行默认，避免整页闪退。
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 经内核拉取完整字节（下载等场景复用；GET）。失败返回 null。
  Future<Uint8List?> fetchBytes(Uri url) async {
    final port = proxy.port;
    if (port <= 0) return null;
    final client = io.HttpClient()
      ..connectionTimeout = const Duration(seconds: 60);
    try {
      final local = localTarget(port, url);
      final req = await client.getUrl(local);
      req.headers.set(io.HttpHeaders.hostHeader, originalHostHeader(url));
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      return builder.toBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
