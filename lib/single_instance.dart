import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';

/// 单实例锁（Windows 命名 mutex）。
///
/// 为什么必须有：两个 ech_browser.exe 实例会同时打开同一个 WebView2 用户数据
/// 目录（`<exe>.WebView2`），WebView2 不允许，会表现为"双击后窗口一闪就退"
/// （无 WER 事件、无 Dart 异常、内核日志停在 StartProxy）。
///
/// 返回 true = 本实例是唯一实例；false = 已有实例在运行，调用方应直接退出。
bool acquireSingleInstanceLock({String name = r'Global\ech-browser-single-instance'}) {
  if (!Platform.isWindows) return true;
  try {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final createMutex = kernel32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.Int32, ffi.Pointer<ffi.Uint16>),
        int Function(int, int, ffi.Pointer<ffi.Uint16>)>('CreateMutexW');
    final getLastError =
        kernel32.lookupFunction<ffi.Uint32 Function(), int Function()>('GetLastError');

    final namePtr = name.toNativeUtf16();
    try {
      final handle = createMutex(0, 1, namePtr.cast());
      if (handle == 0) {
        // 创建失败：不阻塞启动（宁可多实例也别起不来）
        return true;
      }
      const errorAlreadyExists = 183;
      return getLastError() != errorAlreadyExists;
    } finally {
      calloc.free(namePtr);
    }
  } catch (_) {
    return true;
  }
}
