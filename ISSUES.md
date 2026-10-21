# 已知问题与限制（截至 v0.3.5）

> 本文件如实记录本项目从 v0.1.0 到 v0.3.5 期间发现的**全部问题**：已修的、
> 未修的、平台硬限制、环境性问题、以及工程/CI 踩过的坑。每条都写明取证方式与
> 当前状态，不掩饰、不夸大。
>
> 状态标记：`FIXED` 已修 / `OPEN` 未解 / `ENV` 环境性（非产品缺陷）/
> `PLATFORM` 平台硬限制 / `NOTE` 记录在案的设计行为。
>
> **仓库即将归档（只读）**，此文件作为最终状态留存。

---

## A. Windows 启动 / 崩溃类

| # | 问题 | 状态 | 取证与说明 |
|---|---|---|---|
| A1 | v0.2.0 的 Windows 包缺运行库 dll，双击即报缺 dll | FIXED (v0.2.1) | 只打了 `exe + echproxy.dll`，缺 `flutter_windows.dll`、插件 dll、`data/`、VC++ runtime。改为整目录打包 + app-local VC runtime + `zipinfo` 完整性校验（缺一即 CI 红） |
| A2 | `echproxy.dll` 用相对名加载，从非 exe 目录启动报 error 126 | FIXED (v0.2.2) | `DynamicLibrary.open` 相对名按进程 cwd 解析；改为 `Platform.resolvedExecutable` 目录拼绝对路径 |
| A3 | Windows Impeller + 重度 FFI → heap corruption `0xC0000005` | FIXED (v0.3.2) | 上游 [flutter#188635](https://github.com/flutter/flutter/issues/188635)。`FLUTTER_ENGINE_SWITCH_1=--enable-impeller=false` 在 **release 被过滤**（引擎头文件注释明确），改用 embedder 公开 API：runner 里 `project.set_impeller_switch(flutter::ImpellerSwitch::Disabled)`；CI 日志中 Impeller 行消失 |
| A4 | 连续双击（间隔 3s）两次 → 两个实例抢同一 `<exe>.WebView2` 用户数据目录 → 秒退 | FIXED (v0.3.5) | 用户机 20:42 两次崩溃都停在 `Proxy started`，无 WER 事件、无 crash.log；我用 `UseShellExecute=true`（双击等价）单实例连跑 5 次全存活 → 定位为 profile 冲突。修复：`CreateMutexW(Global\ech-browser-single-instance)` 单实例锁，已存在则静默退出。用户机实测：双启动 12s 后只剩 1 个实例、内核 `Starting proxy` 只出现 1 次 |
| A5 | 首次 WebView2 初始化偶发秒退（一次） | OPEN（低复现） | 用户机 18:46 的 `kernel.log` 停在 `Proxy started`、无 `ECHInit: success`；v0.3.5 之后未能复现（单实例 60s 长跑、双启动对照均正常）。怀疑首次 WebView2 profile 初始化竞态，尚未拿到崩溃转储 |
| A6 | 无头 CI 环境里 WebView2 渲染必崩 `0xC0000005` | ENV | 已做对照：关闭 Impeller 仍崩、关闭拦截桥（`ECH_NO_INTERCEPT=1`）仍崩；同一构建在真实桌面不崩。故 CI 的 GUI 硬门禁用「不创建 WebView2」模式验证 Flutter GUI 与内核，全量模式单独观测记录 |
| A7 | 用户解压目录顶层 exe/dll 消失（只剩 `data/` 与 WebView2 目录） | OPEN（未取证） | 核对该次发布的 zip 顶层文件齐全（`unzip -l`）→ 高度怀疑杀软隔离（未签名 exe + mingw dll 常见误报），但用户机无 Defender 检测记录，未能确证 |

## B. 功能正确性

| # | 问题 | 状态 | 取证与说明 |
|---|---|---|---|
| B1 | 页面显示 gzip 压缩体乱码 | FIXED (v0.3.3) | 内核把上游 `Content-Encoding: gzip` 的响应体原样交给拦截层，而拦截层不做内容解码。修复：内核强制上游 `Accept-Encoding: identity` 并剥离 `Content-Encoding`。用户机实测：`Content-Type: text/html`、无 `Content-Encoding`、body 以 `<!DOCTYPE html>` 开头 |
| B2 | pixiv 主文档 403/503 | FIXED (v0.3.4) | 同一内核 e-hentai 200、cloudflare.com 200；KB 记录 pixiv 对 IPv6 出口静态 403。改为默认 `ip_mode=v4`（`ECH_IP_MODE` 可覆盖）。用户机 60s 长跑日志出现 `dl=https://www.pixiv.net/` 与日文页面标题，确认页面实际加载 |
| B3 | pixiv 首跳返回 Cloudflare 挑战（403/503） | NOTE | 挑战脚本（`cdn-cgi/challenge-platform`）返回 200、`s.pximg.net` 资源 200，脚本执行后页面正常。用 `curl`（无 JS）永远拿不到 200，属预期 |
| B4 | 8443 被旧 `ech-proxy-windows-386` 占用时回退随机端口 | NOTE | 设计行为（日志 `Port 8443 in use, trying random port...`）；拦截桥按实际端口工作 |
| B5 | 本地 DoH 默认值 | NOTE | 主用 `https://moonchan.xyz/doh`，兜底 `1.1.1.1/dns-query`；**故意移除** alidns/doh.pub（国内 DoH 不能用于穿墙场景，用户明确要求） |

## C. 平台硬限制（未修，留作后续方向）

| # | 限制 | 状态 | 说明 / 正解方向 |
|---|---|---|---|
| C1 | 原生 `<form method="POST">` 整页提交走直连 | PLATFORM | `shouldInterceptRequest`（Android WebView / WebView2）拿不到请求 body。`fetch/XHR` 的 POST/PUT/PATCH/DELETE 已由注入 JS 桥（`echFetch`）经内核转发，覆盖现代 SPA 站点；传统整页表单仍直连 |
| C2 | WebSocket / WebRTC / QUIC / Service Worker 不在拦截范围 | PLATFORM | 各平台 webview 请求拦截 API 均不覆盖这些协议。普通站点直连可用；被墙站点的 WS 类功能不可用。方向：Windows 自研 WebView2 原生插件（`WebResourceRequested` 可取 body + `IRandomAccessStream` 流式响应）、Android 换 GeckoView；或 JS 覆写 `window.WebSocket` 走内核 |
| C3 | 响应整包缓冲，不支持流式 | PLATFORM | flutter_inappwebview 6.1.5 的 `WebResourceResponse.data` 是 `Uint8List?`。大媒体靠 Range 分块缓解（播放器按段请求），完整流式需原生插件 |
| C4 | Linux 不发布 | PLATFORM | 取证：flutter_inappwebview 6.1.5 的平台依赖里没有 `flutter_inappwebview_linux`（6.2.0-beta 才加入）。现在构建只会产出没有 webview 的废包，故不发布 |
| C5 | iOS 不发布 | PLATFORM | 需 macOS runner + 签名证书；WebView 层（flutter_inappwebview_ios）已具备 |

## D. 工程 / CI 踩坑（已修，留档防复发）

| # | 坑 | 状态 | 说明 |
|---|---|---|---|
| D1 | flutter_inappwebview 6.1.5 实际 API 与预期不符 | FIXED | `WebResourceResponse.data` 是 `Uint8List?`（非 Stream）；`WebResourceRequest` 无 `body` 字段；`headers` 是 `Map<String,String>?`（map 可空、值非空）；`HttpClient` 被插件同名类遮蔽需 `dart:io as io`；`onDownloadStart` 已弃用改用 `onDownloadStartRequest` |
| D2 | MSVC 14.51（VS 18）`STL1011` 硬错误 | FIXED | 插件用 `<experimental/coroutine>` + `/await`，新版 MSVC 把弃用升级为 C2338。CI 里在 pub 缓存给插件 `CMakeLists.txt` 幂等注入 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` |
| D3 | Android 构建 `proguard-android.txt` 不被新 AGP 支持 | FIXED | pub get 后幂等替换为 `proguard-android-optimize.txt` |
| D4 | GitHub Release 同名资产（`libechproxy.so` ×2）上传 404 | FIXED | 发布资产改唯一名（`ech-browser-<os>-<arch>.so/.dll`）；zip 内 dll 必须仍叫 `echproxy.dll`（运行时按名加载） |
| D5 | `gh release create` 多文件上传中途 404 导致整体失败 | FIXED | 拆成「先 create（不带资产）→ 再逐文件 `gh release upload`（失败仅警告）」 |
| D6 | go.mod 依赖声明错误（utls v1.6.7 但代码用 1.8 的 `EncryptedClientHelloConfigList`） | FIXED | `go vet` 直接失败；升 utls v1.8.2 / x/net v0.58 / go 1.26 |
| D7 | Flutter 3.27.4 无法在该 runner 构建 | FIXED（回滚） | 3.27 模板要求 VS2019 生成器，runner 只有 VS18/2022+；回滚到 stable 3.47.7 并改用 D3/A3 的 API 方案 |
| D8 | YAML `run: \|` 块内多行文本缩进丢失 | FIXED | 两次踩到，导致 workflow 解析失败 |
| D9 | PowerShell `Write-Host "..." -f $x` 需括号 | FIXED | 否则报参数错误，诊断输出丢失 |
| D10 | WER / LocalDumps 在本环境无输出 | OPEN（诊断受限） | 无头 runner 与用户机（疑似关闭错误报告）均未产生 dump；因此崩溃定位依赖应用内落盘日志（`kernel.log` / `crash.log`）与进程退出码 |

## E. 验证现状（截至归档）

- **CI 硬门禁**：`go vet + go test -race`、linux/windows(mingw 静态)/android(NDK) 三平台 c-shared、`flutter analyze`、`flutter test`、Windows GUI 硬门禁（真实窗口句柄 → 内核 ECH 真实请求 → `/__panic` 必须 500 且进程不退 → `/health` 200 → 稳定 10s）
- **用户机实测（2026-10-22，v0.3.5）**：单实例锁生效（双启动后只剩 1 个实例、内核只启动 1 次）、60 秒长跑全程存活、gzip 乱码修复、pixiv 页面实际加载
- **未验证**：Android APK 真机、iOS、Linux（后两者不发布，见 C4/C5）

## F. 调试开关（保留，便于复现）

| 开关 | 作用 |
|---|---|
| `ECH_IP_MODE=v4/v6/auto` | 上游出口协议族（默认 v4） |
| `ECH_HEADLESS=1` | 不创建 WebView2（CI GUI 门禁用） |
| `ECH_NO_KERNEL=1` | 完全不加载 go 内核（二分用） |
| `ECH_NO_CRASHHOOK=1` | 跳过崩溃钩子/守护 zone |
| `ECH_NO_LOGFILE=1` | 内核不写 `kernel.log` |
| `ECH_NO_INTERCEPT=1` | 关闭拦截桥（webview 直连） |

## 日志位置

- 内核日志：`%USERPROFILE%\.ech-browser\kernel.log`（每次启动/每个请求，4 MiB 轮转）
- Dart 异常：`%USERPROFILE%\.ech-browser\crash.log`
- 设置：`%USERPROFILE%\.ech-browser\settings.json`
