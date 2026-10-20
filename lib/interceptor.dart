import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'proxy_manager.dart';

/// 逐跳头：描述"上一跳到下一跳"，不能透传给本地回环内核上游。
const _hopByHop = <String>{
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade',
};

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

  /// 拦截回调：http(s) 请求 → 本地回环内核 → 返回响应流。
  /// 非 http(s)（自定义 scheme 等）放行；内核未就绪时返回 null 让 webview
  /// 走默认（显示失败页而非闪退）。
  Future<WebResourceResponse?> onShouldInterceptRequest(
      InAppWebViewController controller, WebResourceRequest request) async {
    final url = request.url;
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final port = proxy.port;
    if (port <= 0) return null;

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..followRedirects = false;

    try {
      final local = localTarget(port, url);
      final req = await httpClient.openUrl(request.method, local);
      req.headers.set(HttpHeaders.hostHeader, url.host);

      request.headers?.forEach((key, value) {
        final k = key.toLowerCase();
        if (k == 'host' || _hopByHop.contains(k)) return;
        req.headers.set(key, value);
      });

      final body = request.body;
      if (body != null && request.method != 'GET' && request.method != 'HEAD') {
        req.contentLength = body.length;
        req.add(body);
      }

      final resp = await req.close();
      final headers = <String, String>{};
      resp.headers.forEach((k, v) => headers[k] = v.join(', '));

      return WebResourceResponse(
        contentType:
            resp.headers.contentType?.toString() ?? 'application/octet-stream',
        statusCode: resp.statusCode,
        reasonPhrase: resp.reasonPhrase,
        headers: headers,
        data: resp.map((chunk) => Uint8List.fromList(chunk)),
      );
    } catch (_) {
      // 内核链路出错：放行默认，避免整页闪退。
      return null;
    } finally {
      httpClient.close(force: true);
    }
  }
}
