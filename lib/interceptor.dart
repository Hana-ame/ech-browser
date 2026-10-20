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

  /// 拦截回调：http(s) 请求 → 本地回环内核 → 返回响应。
  /// 非 http(s)（自定义 scheme 等）放行；内核未就绪或链路出错时返回 null
  /// 让 webview 走默认（显示失败页而非闪退）。
  Future<WebResourceResponse?> onShouldInterceptRequest(
      InAppWebViewController controller, WebResourceRequest request) async {
    final url = request.url;
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final port = proxy.port;
    if (port <= 0) return null;

    final client = io.HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);

    try {
      final local = localTarget(port, url);
      final req = await client.openUrl(request.method ?? 'GET', local);
      req.headers.set(io.HttpHeaders.hostHeader, url.host);

      request.headers?.forEach((key, value) {
        final k = key.toLowerCase();
        if (k == 'host' || _hopByHop.contains(k)) return;
        req.headers.set(key, value);
      });

      // 注意：flutter_inappwebview 6.1.5 的 WebResourceRequest 没有 body 字段，
      // POST body 无法经 shouldInterceptRequest 获取（Android/本版本通用限制，
      // 见 README 已知边界）。GET/HEAD/无 body 请求不受影响。

      final resp = await req.close();
      final headers = <String, String>{};
      resp.headers.forEach((k, v) => headers[k] = v.join(', '));

      // 6.1.5 的 WebResourceResponse.data 是 Uint8List?（整包缓冲，不支持流）：
      // MVP 取舍，大媒体流式留给后续迭代（Windows WebView2 走同 API）。
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
}
