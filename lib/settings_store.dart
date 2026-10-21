import 'dart:convert';
import 'dart:io';

/// 本地配置持久化（`~/.ech-browser/settings.json`）与下载落盘辅助。
///
/// 纯 Dart 实现，便于单测；所有 IO 失败都静默回退，不阻塞浏览器启动。
class SettingsStore {
  SettingsStore({String? homeDir}) : _home = homeDir ?? defaultHome();

  final String? _home;

  /// 当前 DoH 地址（默认 moonchan.xyz；国内 DoH 不能用于穿墙场景）。
  String dohUrl = 'https://moonchan.xyz/doh';

  static String? defaultHome() =>
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];

  String? get _dirPath {
    final h = _home;
    if (h == null || h.isEmpty) return null;
    return '$h${Platform.pathSeparator}.ech-browser';
  }

  File? get _filePath {
    final d = _dirPath;
    return d == null ? null : File('$d${Platform.pathSeparator}settings.json');
  }

  /// 读取配置；不存在或损坏时保持默认值。
  Future<void> load() async {
    try {
      final f = _filePath;
      if (f == null || !await f.exists()) return;
      final parsed = jsonDecode(await f.readAsString());
      if (parsed is Map && parsed['doh_url'] is String) {
        final v = (parsed['doh_url'] as String).trim();
        if (v.isNotEmpty) dohUrl = v;
      }
    } catch (_) {
      // 配置损坏 → 用默认值继续
    }
  }

  /// 保存配置；失败静默（下次启动回落默认值）。
  Future<void> save() async {
    try {
      final d = _dirPath;
      final f = _filePath;
      if (d == null || f == null) return;
      await Directory(d).create(recursive: true);
      await f.writeAsString(jsonEncode({'doh_url': dohUrl}));
    } catch (_) {}
  }

  /// 下载目录：优先用户 Downloads；不可写时回落系统临时目录。
  static Future<Directory> downloadDir() async {
    final home = defaultHome();
    if (home != null && home.isNotEmpty) {
      final d = Directory('$home${Platform.pathSeparator}Downloads');
      try {
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      } catch (_) {
        // 桌面环境可能无写权限 → 回落
      }
    }
    return Directory.systemTemp.createTemp('ech-browser-dl');
  }

  /// 重名文件追加 " (n)" 后缀（纯函数，便于单测）。
  /// 例：`a.jpg` 已存在 → `a (1).jpg`。
  static String uniqueFileName(String name, bool Function(String) exists) {
    if (!exists(name)) return name;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var i = 1;
    while (exists('$base ($i)$ext')) {
      i++;
    }
    return '$base ($i)$ext';
  }
}
