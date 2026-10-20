import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'interceptor.dart';
import 'proxy_manager.dart';

/// ech-browser：点开即用的通用 ECH 浏览器。
/// 任意 http(s) 网址可访问；webview 请求经拦截交给本地 go 内核，
/// 免改系统 hosts、免手动安装证书。目标：与普通浏览器使用体验无异。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EchBrowserApp());
}

/// 默认首页（可改任意网址；地址栏可访问任何站点）。
const String kHomePage = 'https://www.pixiv.net/';

class EchBrowserApp extends StatelessWidget {
  const EchBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ech-browser',
      theme: ThemeData.dark(useMaterial3: true),
      home: const BrowserScreen(),
    );
  }
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final ProxyManager _proxy = ProxyManager.instance;
  late final Interceptor _interceptor;
  final TextEditingController _address = TextEditingController(text: kHomePage);
  InAppWebViewController? _web;
  bool _starting = true;
  String _status = '正在启动内核…';
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _interceptor = Interceptor(_proxy);
    _boot();
  }

  Future<void> _boot() async {
    _proxy.init();
    final port = await _proxy.start();
    if (!mounted) return;
    setState(() {
      _starting = false;
      _status = port > 0 ? '内核就绪 · 端口 $port' : '内核启动失败：${_proxy.lastError}';
    });
  }

  Future<void> _go(String raw) async {
    var url = raw.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final w = _web;
    if (w != null) {
      await w.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      setState(() => _address.text = url);
    }
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _handleDownload(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    _setStatus('下载中：$url');
    final bytes = await _interceptor.fetchBytes(uri);
    if (bytes == null || !mounted) {
      _setStatus('下载失败：$url（已放行直连）');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('ech-browser-dl');
    final name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download.bin';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);
    _setStatus('已下载：${file.path}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _navButton(Icons.arrow_back, _canGoBack, () => _web?.goBack()),
            _navButton(Icons.arrow_forward, _canGoForward, () => _web?.goForward()),
            _navButton(Icons.home, true, () => _go(kHomePage)),
            _navButton(Icons.refresh, true, () => _web?.reload()),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _address,
                decoration: const InputDecoration(
                    hintText: '输入任意网址…', isDense: true, border: InputBorder.none),
                onSubmitted: _go,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => _go(_address.text),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _statusBar(),
          Expanded(child: _webview()),
        ],
      ),
    );
  }

  Widget _navButton(IconData icon, bool enabled, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(icon),
      onPressed: enabled ? onPressed : null,
      iconSize: 20,
    );
  }

  Widget _statusBar() {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(_status, style: const TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: _showLogs,
            child: const Text('日志'),
          ),
        ],
      ),
    );
  }

  void _showLogs() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('内核日志'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(_proxy.logs().join('\n')),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(_), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _webview() {
    if (_starting) return const Center(child: CircularProgressIndicator());
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(kHomePage)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowFileAccess: true,
        supportZoom: true,
        useShouldInterceptAjaxRequest: false,
      ),
      onWebViewCreated: (c) => _web = c,
      onProgressChanged: (c, p) {
        _setStatus('加载中 $p% · 端口 ${_proxy.port}');
      },
      onLoadStop: (c, url) {
        if (url != null) {
          _address.text = url.toString();
          _setStatus('就绪 · 端口 ${_proxy.port}');
        }
      },
      onUpdateVisitedHistory: (c, url, isReload) async {
        final canBack = await c.canGoBack();
        final canFwd = await c.canGoForward();
        if (mounted) {
          setState(() {
            _canGoBack = canBack;
            _canGoForward = canFwd;
          });
        }
      },
      onDownloadStart: (c, url) => _handleDownload(url),
      onCreateWindow: (c, createWindowAction) async {
        // target=_blank 弹窗：在当前 webview 内打开（不弹新窗口）。
        final request = createWindowAction.request;
        if (request != null) {
          await c.loadUrl(urlRequest: request);
          return true;
        }
        return false;
      },
      shouldInterceptRequest: _interceptor.onShouldInterceptRequest,
    );
  }

  @override
  void dispose() {
    _proxy.stop();
    super.dispose();
  }
}
