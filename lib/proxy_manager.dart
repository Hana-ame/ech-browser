import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

/// go 内核（engine/main.go）的 Dart FFI 绑定。
///
/// 每个方法现场 open + lookup：跨 isolate 安全，代价是可忽略的查找开销。
/// 本仓纪律：**禁止本地测试**，一切验证走 GitHub Actions CI。
class ProxyManager {
  ProxyManager._();
  static final ProxyManager instance = ProxyManager._();

  int _port = 0;
  String _lastError = '';

  int get port => _port;
  String get lastError => _lastError;

  /// 打开 go 内核动态库。
  ///
  /// Windows 上**必须按 exe 所在目录的绝对路径加载**：`DynamicLibrary.open`
  /// 传相对名时按进程当前目录解析，快捷方式/从别处启动时 cwd 不是 exe 目录，
  /// 会报 error 126「module could not be found」——即使 dll 就在 exe 旁边。
  static DynamicLibrary _open() {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return DynamicLibrary.open('$exeDir/echproxy.dll');
    }
    return DynamicLibrary.open('libechproxy.so');
  }

  /// ECH 预热（异步，不阻塞 UI）。返回后可用 [initReady] 轮询。
  void init() {
    try {
      final lib = _open();
      final init = lib.lookupFunction<Void Function(), void Function()>('ECHInit');
      init();
    } catch (e) {
      _lastError = '加载 echproxy.dll 失败：$e';
    }
  }

  /// 启动代理并绑定回环端口（返回端口号，0 = 失败）。
  /// 内核不做站点探测（通用浏览器，任意网址），绑定即就绪，ECH 懒初始化；
  /// 因此本调用很快，但仍在独立 isolate 执行以防将来变化冻住 UI。
  Future<int> start() async {
    try {
      final port = await Isolate.run<int>(() {
        final lib = _open();
        final start = lib.lookupFunction<Uint16 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)>('StartProxy');
        return start(nullptr);
      });
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
      final stop = lib.lookupFunction<Void Function(), void Function()>('StopProxy');
      stop();
    } catch (e) {
      _lastError = 'stop: $e';
    }
  }

  /// 当前监听端口（0 = 未启动）。
  int portNow() {
    try {
      final lib = _open();
      final get = lib
          .lookupFunction<Uint16 Function(), int Function()>('GetProxyPort');
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
      final count =
          lib.lookupFunction<Int32 Function(), int Function()>('ECHGetLogCount');
      final get = lib.lookupFunction<Pointer<Utf8> Function(Int32),
          Pointer<Utf8> Function(int)>('ECHGetLog');
      final free =
          lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
              'FreeCString');
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
