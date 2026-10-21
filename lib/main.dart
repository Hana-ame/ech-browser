import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'crash_log.dart';
import 'interceptor.dart';
import 'proxy_manager.dart';
import 'settings_store.dart';

/// ech-browser：点开即用的通用 ECH 浏览器。
/// 任意 http(s) 网址可访问；webview 请求经拦截交给本地 go 内核，
/// 免改系统 hosts、免手动安装证书。目标：与普通浏览器使用体验无异。
void main() {
  // 注意：WidgetsFlutterBinding 必须在 zone 外初始化。
  // 把 ensureInitialized 放进 runZonedGuarded 是 Flutter 已知反模式：平台回调
  // 在根 zone 触发，与自定义 zone 的 timer/microtask 语义错位，表现为进程
  // 几秒后静默退出（Windows 退出码 -1）。
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    CrashLog.write('flutter', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    CrashLog.write('platform', error, stack);
    return true;
  };
  // 全局兜底：任何未捕获的 Dart 异常都落盘，闪退后可通过
  // ~/.ech-browser/crash.log（或临时目录同名文件）回传定位。
  runZonedGuarded(() {
    runApp(const EchBrowserApp());
  }, (error, stack) {
    CrashLog.write('zone', error, stack);
  });
}

/// 默认首页（可改任意网址；地址栏可访问任何站点或输入关键词搜索）。
const String kHomePage = 'https://www.pixiv.net/';

/// 默认搜索引擎模板（地址栏输入非网址关键词时自动拼接）。
const String kSearchEnginePrefix = 'https://www.bing.com/search?q=';

/// 注入到页面顶层的 JS 桥：将带请求体的 fetch (POST/PUT/PATCH/DELETE) 经 Flutter 转发至本地 Go ECH 内核，
/// 解决平台 shouldInterceptRequest 拿不到请求体的问题。
const String _kEchFetchBridgeScript = r'''
(function() {
  if (window.__echBridgeInstalled) return;
  window.__echBridgeInstalled = true;
  const origFetch = window.fetch;
  if (!origFetch) return;

  function toBase64(buf) {
    const bytes = new Uint8Array(buf);
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
  }

  window.fetch = async function(input, init) {
    try {
      let method = (init && init.method) ? String(init.method).toUpperCase() :
                   (input && input.method ? String(input.method).toUpperCase() : 'GET');
      if (method === 'GET' || method === 'HEAD' || method === 'OPTIONS') {
        return origFetch.apply(this, arguments);
      }
      if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
        return origFetch.apply(this, arguments);
      }
      const req = new Request(input, init);
      const url = req.url;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        return origFetch.apply(this, arguments);
      }
      const headers = {};
      req.headers.forEach((v, k) => { headers[k] = v; });
      const ab = await req.clone().arrayBuffer();
      const bodyB64 = ab.byteLength > 0 ? toBase64(ab) : '';
      const res = await window.flutter_inappwebview.callHandler('echFetch', {
        url: url,
        method: method,
        headers: headers,
        bodyBase64: bodyB64
      });
      if (!res || !res.ok) {
        return origFetch.apply(this, arguments);
      }
      const raw = atob(res.bodyBase64 || '');
      const outBytes = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) {
        outBytes[i] = raw.charCodeAt(i);
      }
      return new Response(outBytes.buffer, {
        status: res.statusCode || 200,
        statusText: res.reasonPhrase || 'OK',
        headers: res.headers || {}
      });
    } catch (_) {
      return origFetch.apply(this, arguments);
    }
  };
})();
''';

class EchBrowserApp extends StatelessWidget {
  const EchBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ech-browser',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const BrowserScreen(),
    );
  }
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  /// 地址栏输入智能归一化（纯函数，便于单测）：
  /// - 已含 http:// 或 https:// → 原样返回
  /// - 含空白字符或不含点号（且非 localhost）→ 视为搜索词，走搜索引擎
  /// - localhost / 127.0.0.1 / [::1] → 默认补 http://
  /// - 其他域名/IP → 默认补 https://
  static String normalizeInputToUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('about:')) {
      return s;
    }
    if (s.contains(RegExp(r'\s'))) {
      return '$kSearchEnginePrefix${Uri.encodeQueryComponent(s)}';
    }
    final hostPart = s.split('/').first.toLowerCase();
    final isLocal = hostPart == 'localhost' ||
        hostPart.startsWith('localhost:') ||
        hostPart.startsWith('127.') ||
        hostPart.startsWith('[::1]');
    if (isLocal) {
      return 'http://$s';
    }
    if (!hostPart.contains('.') && !hostPart.contains(':')) {
      return '$kSearchEnginePrefix${Uri.encodeQueryComponent(s)}';
    }
    return 'https://$s';
  }

  /// 下载文件名安全清洗（纯函数，便于单测）：移除路径穿越与非法文件名字符。
  static String sanitizeFileName(String? suggested, Uri uri) {
    var candidate = (suggested ?? '').trim();
    if (candidate.isEmpty && uri.pathSegments.isNotEmpty) {
      candidate = uri.pathSegments.last.trim();
    }
    candidate = candidate
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll('..', '_');
    if (candidate.isEmpty || candidate == '.' || candidate == '_') {
      return 'download.bin';
    }
    return candidate;
  }

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final ProxyManager _proxy = ProxyManager.instance;
  final SettingsStore _settings = SettingsStore();
  late final Interceptor _interceptor;
  final TextEditingController _address = TextEditingController(text: kHomePage);
  String _dohUrl = 'https://moonchan.xyz/doh';
  InAppWebViewController? _web;
  bool _starting = true;
  String _status = '正在启动内核…';
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _interceptor = Interceptor(_proxy, onSetCookies: _syncCookiesToWebView);
    _initAndBoot();
  }

  /// 先载入持久化配置（DoH 等），再启动内核——避免"改了设置重启就丢"。
  Future<void> _initAndBoot() async {
    await _settings.load();
    _dohUrl = _settings.dohUrl;
    if (Platform.environment['ECH_NO_KERNEL'] == '1') {
      // CI 二分用：完全不加载 go 内核，判断退出是壳还是内核引起
      setState(() {
        _starting = false;
        _status = 'ECH_NO_KERNEL=1：内核已跳过';
      });
      return;
    }
    _proxy.setDohUrl(_dohUrl);
    await _boot();
  }

  Future<void> _syncCookiesToWebView(Uri url, List<String> rawCookies) async {
    try {
      final cm = CookieManager.instance();
      for (final raw in rawCookies) {
        final firstSemi = raw.indexOf(';');
        final pair = (firstSemi >= 0 ? raw.substring(0, firstSemi) : raw).trim();
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final name = pair.substring(0, eq).trim();
        final value = pair.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        await cm.setCookie(
          url: WebUri.uri(url),
          name: name,
          value: value,
        );
      }
    } catch (_) {}
  }

  Future<void> _boot() async {
    _proxy.init();
    final port = await _proxy.start();
    if (!mounted) return;
    setState(() {
      _starting = false;
      _status = port > 0
          ? '内核就绪 · 端口 $port'
          : '内核启动失败：${_proxy.lastError.isNotEmpty ? _proxy.lastError : "未知错误"}';
    });
  }

  Future<void> _go(String raw) async {
    final url = BrowserScreen.normalizeInputToUrl(raw);
    if (url.isEmpty) return;
    setState(() => _address.text = url);
    final w = _web;
    if (w != null) {
      await w.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _handleDownload(DownloadStartRequest request) async {
    final uri = request.url;
    _setStatus('下载中：${uri.toString()}');

    String? cookieHeader;
    try {
      final cookies = await CookieManager.instance().getCookies(url: uri);
      if (cookies.isNotEmpty) {
        cookieHeader = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      }
    } catch (_) {}

    final currentUrl = await _web?.getUrl();
    final referer = currentUrl?.toString() ?? '${uri.scheme}://${uri.host}/';

    final bytes = await _interceptor.fetchBytes(
      uri,
      referer: referer,
      cookie: cookieHeader,
      userAgent: request.userAgent,
    );
    if (bytes == null || !mounted) {
      _setStatus('下载失败：${uri.toString()}');
      return;
    }
    final dir = await SettingsStore.downloadDir();
    final rawName = BrowserScreen.sanitizeFileName(request.suggestedFilename, uri);
    final name = SettingsStore.uniqueFileName(
        rawName,
        (n) => File('${dir.path}${Platform.pathSeparator}$n').existsSync());
    final file = File('${dir.path}${Platform.pathSeparator}$name');
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
            _navButton(
                Icons.arrow_forward, _canGoForward, () => _web?.goForward()),
            _navButton(Icons.home, true, () => _go(kHomePage)),
            _navButton(Icons.refresh, true, () => _web?.reload()),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _address,
                decoration: const InputDecoration(
                    hintText: '输入网址或搜索词…',
                    isDense: true,
                    border: InputBorder.none),
                onSubmitted: _go,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: '前往',
              onPressed: () => _go(_address.text),
            ),
            IconButton(
              icon: const Icon(Icons.settings, size: 20),
              tooltip: '内核设置',
              onPressed: _showSettings,
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
            child: Text(
              _status,
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
      builder: (ctx) => AlertDialog(
        title: const Text('内核日志'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(_proxy.logs().join('\n')),
          ),
        ),
        actions: [
          if (_proxy.port > 0)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _go('http://127.0.0.1:${_proxy.port}/');
              },
              child: const Text('打开状态页'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  void _showSettings() {
    final dohCtrl = TextEditingController(text: _dohUrl);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ECH 内核设置'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('首选 DoH 地址（失败时自动切换内置备用节点）：',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: dohCtrl,
                decoration: const InputDecoration(
                  hintText: 'https://moonchan.xyz/doh',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '当前端口：${_proxy.port} · 内核就绪：${_proxy.readyState() == 1 ? "是" : "否"}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              _setStatus('正在重启内核…');
              final port = await _proxy.start();
              _setStatus(port > 0
                  ? '内核已重启 · 端口 $port'
                  : '内核重启失败：${_proxy.lastError}');
            },
            child: const Text('重启内核'),
          ),
          TextButton(
            onPressed: () {
              final nextDoh = dohCtrl.text.trim();
              if (nextDoh.isNotEmpty) {
                _dohUrl = nextDoh;
                _proxy.setDohUrl(nextDoh);
                _proxy.init();
                _settings.dohUrl = nextDoh;
                _settings.save();
                _setStatus('已更新 DoH 并保存：$nextDoh');
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _webview() {
    if (_starting) return const Center(child: CircularProgressIndicator());
    // CI smoke 专用：ECH_HEADLESS=1 时不创建 webview，只让内核跑起来被 curl 验证。
    // 无头 Windows runner 上 WebView2/GPU 初始化偶发访问违例，会污染 smoke 结论。
    if (Platform.environment['ECH_HEADLESS'] == '1') {
      return const Center(
          child: Text('headless smoke mode（未创建 webview）',
              style: TextStyle(color: Colors.white70)));
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(kHomePage)),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _kEchFetchBridgeScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        allowFileAccess: false,
        supportZoom: true,
        useShouldInterceptAjaxRequest: false,
        useOnDownloadStart: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
      ),
      onWebViewCreated: (c) {
        _web = c;
        c.addJavaScriptHandler(
          handlerName: 'echFetch',
          callback: (args) async {
            if (args.isEmpty || args.first is! Map) {
              return <String, dynamic>{'ok': false};
            }
            final payload = Map<String, dynamic>.from(args.first as Map);
            final rawUrl = payload['url']?.toString() ?? '';
            final method = payload['method']?.toString() ?? 'POST';
            final rawHeaders = payload['headers'];
            final bodyB64 = payload['bodyBase64']?.toString() ?? '';
            final uri = Uri.tryParse(rawUrl);
            if (uri == null) return <String, dynamic>{'ok': false};

            final headers = <String, String>{};
            if (rawHeaders is Map) {
              rawHeaders.forEach((k, v) {
                if (k != null && v != null) {
                  headers[k.toString()] = v.toString();
                }
              });
            }
            Uint8List? bodyBytes;
            if (bodyB64.isNotEmpty) {
              bodyBytes = base64Decode(bodyB64);
            }

            final proxied = await _interceptor.forwardRequest(
              method: method,
              url: uri,
              headers: headers,
              body: bodyBytes,
              autoUncompress: true,
            );
            if (proxied == null) {
              return <String, dynamic>{'ok': false};
            }
            return <String, dynamic>{
              'ok': true,
              'statusCode': proxied.statusCode,
              'reasonPhrase': proxied.reasonPhrase,
              'headers': proxied.headers,
              'bodyBase64': base64Encode(proxied.body),
            };
          },
        );
      },
      onProgressChanged: (c, p) {
        _setStatus('加载中 $p% · 端口 ${_proxy.port}');
      },
      onLoadStop: (c, url) {
        if (url != null) {
          _address.text = url.toString();
          _setStatus('就绪 · 端口 ${_proxy.port}');
        }
      },
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame ?? false) {
          _setStatus('加载异常：${err.description} · 端口 ${_proxy.port}');
        }
      },
      onUpdateVisitedHistory: (c, url, isReload) async {
        final canBack = await c.canGoBack();
        final canFwd = await c.canGoForward();
        if (mounted) {
          setState(() {
            if (url != null) {
              _address.text = url.toString();
            }
            _canGoBack = canBack;
            _canGoForward = canFwd;
          });
        }
      },
      onDownloadStartRequest: (c, request) => _handleDownload(request),
      onCreateWindow: (c, createWindowAction) async {
        // target=_blank 弹窗：在当前 webview 内打开（不弹新窗口）。
        await c.loadUrl(urlRequest: createWindowAction.request);
        return true;
      },
      shouldInterceptRequest: _interceptor.onShouldInterceptRequest,
    );
  }

  @override
  void dispose() {
    _address.dispose();
    _interceptor.dispose();
    _proxy.stop();
    super.dispose();
  }
}
