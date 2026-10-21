import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// go 内核（engine/main.go）的 Dart FFI 绑定。
///
/// 每个方法现场 open + lookup：跨 isolate 安全，代价是可忽略的查找开销。
class ProxyManager {
  ProxyManager._();
  static final ProxyManager instance = ProxyManager._();

  int _port = 0;
  String _lastError = '';

  int get port => _port;
  String get lastError => _lastError;

  /// 按平台与可执行文件目录解析动态库路径，避免工作目录变化导致找不到动态库。
  static List<String> candidateLibraryNames() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      return <String>[
        '$exeDir${sep}echproxy.dll',
        'echproxy.dll',
      ];
    }
    if (Platform.isMacOS) {
      return <String>[
        '$exeDir${sep}libechproxy.dylib',
        'libechproxy.dylib',
      ];
    }
    return <String>[
      '$exeDir${sep}lib${sep}libechproxy.so',
      '$exeDir${sep}libechproxy.so',
      'libechproxy.so',
    ];
  }

  static DynamicLibrary _open() {
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    Object? lastErr;
    for (final path in candidateLibraryNames()) {
      try {
        return DynamicLibrary.open(path);
      } catch (e) {
        lastErr = e;
      }
    }
    throw ArgumentError('Failed to open echproxy library: $lastErr');
  }

  /// 动态设置 DoH 服务端 URL（默认 https://moonchan.xyz/doh）。
  bool setDohUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    Pointer<Utf8> ptr = nullptr;
    try {
      final lib = _open();
      final fn = lib.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('ECHSetDohURL');
      ptr = trimmed.toNativeUtf8();
      fn(ptr);
      return true;
    } catch (e) {
      _lastError = 'setDohUrl: $e';
      return false;
    } finally {
      if (ptr != nullptr) {
        calloc.free(ptr);
      }
    }
  }

  /// ECH 预热（异步，不阻塞 UI）。返回后可用 [initReady] 轮询。
  void init() {
    try {
      final lib = _open();
      final initFn =
          lib.lookupFunction<Void Function(), void Function()>('ECHInit');
      initFn();
    } catch (e) {
      _lastError = 'init: $e';
    }
  }

  /// 带自定义 DoH 主机与引导 IP 的 ECH 预热。
  void initWithBootstrap(String host, String bootstrapIp) {
    Pointer<Utf8> hostPtr = nullptr;
    Pointer<Utf8> ipPtr = nullptr;
    try {
      final lib = _open();
      final fn = lib.lookupFunction<
          Void Function(Pointer<Utf8>, Pointer<Utf8>),
          void Function(Pointer<Utf8>, Pointer<Utf8>)>('ECHInitWithBootstrap');
      hostPtr = host.trim().toNativeUtf8();
      ipPtr = bootstrapIp.trim().toNativeUtf8();
      fn(hostPtr, ipPtr);
    } catch (e) {
      _lastError = 'initWithBootstrap: $e';
    } finally {
      if (hostPtr != nullptr) calloc.free(hostPtr);
      if (ipPtr != nullptr) calloc.free(ipPtr);
    }
  }

  /// ECH 预热状态（1 = 完成，0 = 进行中/未开始，-1 = 失败）。
  int initReady() {
    try {
      final lib = _open();
      final fn =
          lib.lookupFunction<Int32 Function(), int Function()>('ECHInitReady');
      return fn();
    } catch (_) {
      return -1;
    }
  }

  /// 获取最近一次 ECHInit 错误信息。
  String initLastError() {
    try {
      final lib = _open();
      final getErr = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('ECHInitLastError');
      final free = lib.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('FreeCString');
      final p = getErr();
      if (p == nullptr) return '';
      final s = p.toDartString();
      free(p);
      return s;
    } catch (_) {
      return '';
    }
  }

  /// 启动代理并绑定回环端口（返回端口号，0 = 失败）。
  ///
  /// 注意：**必须在主 isolate 直接调用**，不要放进 Isolate.run。
  /// go 运行时（c-shared）的 HTTP 服务 goroutine 是从这次 FFI 调用延伸出来的，
  /// 放在短命 isolate 里会在 isolate 销毁后与 Dart 线程生命周期冲突（实测
  /// 内核首个 panic 路径即整进程退出）。v0.3.0 起 StartProxy 不做站点探测，
  /// 绑定即就绪，调用很快，直接调用不会冻 UI。
  Future<int> start() async {
    try {
      final lib = _open();
      final start = lib.lookupFunction<Uint16 Function(Pointer<Utf8>),
          int Function(Pointer<Utf8>)>('StartProxy');
      final port = start(nullptr);
      _port = port;
      if (port <= 0) {
        _lastError = 'StartProxy 返回 0（内核启动失败）';
      }
      return port;
    } catch (e) {
      _lastError = '加载 echproxy.dll 失败：$e';
      return 0;
    }
  }

  void stop() {
    try {
      final lib = _open();
      final stopFn =
          lib.lookupFunction<Void Function(), void Function()>('StopProxy');
      stopFn();
      _port = 0;
    } catch (e) {
      _lastError = 'stop: $e';
    }
  }

  /// 当前监听端口（0 = 未启动）。
  int portNow() {
    try {
      final lib = _open();
      final get =
          lib.lookupFunction<Uint16 Function(), int Function()>('GetProxyPort');
      return get();
    } catch (_) {
      return 0;
    }
  }

  /// 内核就绪状态（1 = 就绪，0 = 未就绪，-1 = 初始化出错）。
  int readyState() {
    try {
      final lib = _open();
      final ready =
          lib.lookupFunction<Int32 Function(), int Function()>('IsEchReady');
      return ready();
    } catch (_) {
      return -1;
    }
  }

  /// 拉取内核环形日志（最近若干行）。
  List<String> logs() {
    try {
      final lib = _open();
      final count = lib
          .lookupFunction<Int32 Function(), int Function()>('ECHGetLogCount');
      final get = lib.lookupFunction<Pointer<Utf8> Function(Int32),
          Pointer<Utf8> Function(int)>('ECHGetLog');
      final free = lib.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('FreeCString');
      final n = count();
      final out = <String>[];
      for (var i = 0; i < n; i++) {
        final p = get(i);
        if (p != nullptr) {
          out.add(p.toDartString());
          free(p);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
