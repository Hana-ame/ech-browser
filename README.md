# ech-browser

**点开即用的通用 ECH 独立浏览器**：flutter+webview 做外壳，go 内核在 webview
拦截层背后按 Host 全自动做 ECH/SNI 伪装直连。

- **任意 http(s) 网址**都可访问（地址栏输入即用），不限单一站点
- **无需修改系统 hosts**：webview 只与本地回环代理打交道
- **无需手动安装证书**：上游 TLS 由 go 内核用系统信任根完成，webview 层全程明文回环
- 跨平台：Windows（WebView2）/ Android（WebView）/ iOS（WKWebView）/ Linux（WebKitGTK）

## 架构

```
Flutter 壳（地址栏 + webview + 状态/日志）
  └─ 拦截桥：webview 请求 → 127.0.0.1:<port>（保留原始 Host）
go 内核（engine/，c-shared，复用 ech-proxy 的 ech 核心 + utls）
  └─ RoundTrip 全自动：Cloudflare 站点 → ECH；非 CF → SNI 伪装直连；失败自动切换/兜底直连
真实上游（任意站点）
```

- `engine/main.go`：c-shared 入口，12 个 FFI 导出
  （`ECHInit/StartProxy/StopProxy/GetProxyPort/IsEchReady/ECHGetLog*/…`），
  回环明文 HTTP 监听（优先 8443，占用则随机端口）
- `engine/ech/`、`engine/netdial/`：ech-proxy 仓库 `echproxy/ech` + `echproxy/netdial`
  的复制（ECH/SNI 探测、utls 指纹、DoH 解析、IP 族选择）
- `lib/`：flutter 壳（地址栏、webview、拦截桥、日志）
- Dart 侧 FFI 绑定见 `lib/proxy_manager.dart`，拦截改写规则见 `lib/interceptor.dart`

## 开发纪律

**本仓禁止本地测试。** 所有编译、测试、静态检查只在 GitHub Actions CI 执行：

- `build` workflow：go c-shared 三平台（linux/windows/android）+ flutter analyze + flutter test
- `release` workflow：打 `v*` tag 自动构建并发布正式 Release（绝不 draft），
  资产含 Windows 桌面 zip（exe + echproxy.dll）与三平台 go 内核库

## 使用

1. 从 Releases 下载 `ech-browser-windows-x64.zip`，**整个解压**（包内已含
   `flutter_windows.dll`、插件 dll、`data/` 运行库与 VC++ runtime）
2. 双击 `ech_browser.exe`（`echproxy.dll` 与运行库必须与 exe 同目录）
3. 地址栏输入任意网址即可；状态栏显示内核端口，日志页可看内核诊断

## 已知边界与平台能力（v0.2.0）

目标是与普通浏览器体验无异；边界按「已解决 / 降级 / 平台硬限制」三档如实列出。

### 已解决（代码层）

- **任意网址 + 非标准端口**：拦截桥保留原始 Host 头含端口（`example.com:8080`）
- **GET/HEAD 全协议**：页面/图片/媒体/字体/API（GET）均经内核 ECH/SNI 直连
- **Range/媒体分段**：视频播放器按段请求，每段经内核转发（整包缓冲由分段缓解）
- **下载**：`onDownloadStart` → 经内核拉取并保存到系统临时目录（提示路径）
- **新窗口/弹窗**（`target=_blank`）：在当前 webview 内打开
- **导航**：后退/前进/刷新/主页 + 地址栏；历史状态同步
- **错误页**：内核失败时展示可读 HTML 错误页（替代裸 502）
- **Cookie/登录态**：webview 自有 Cookie 存储，请求/响应原样透传

### 降级（功能可用，不经 ECH）

- **POST/PUT/PATCH/DELETE（带 body）**：flutter_inappwebview 6.1.5 的
  `shouldInterceptRequest` 拿不到请求 body（平台 API 限制）→ **放行直连**：
  表单提交可用，但对被墙站点（如 pixiv 登录）会失败；状态栏有提示。
  正解（路线图）：Windows 自研 WebView2 原生插件（`WebResourceRequested` 可取
  body + 流式响应）；Android 换 GeckoView（扩展 webRequest 可取 body）。

### 平台硬限制（拦截层不可见，文档化）

- **WebSocket / WebRTC / QUIC / Service Worker**：webview 请求拦截 API
  （Android `shouldInterceptRequest`、WebView2 `WebResourceRequested`、
  iOS `WKURLSchemeHandler`）均不含这些协议。
  普通站点走直连可正常使用；被墙站点的 WS 类功能（实时聊天等）不可用。
  正解（路线图）：以上原生插件路径 + 必要时 JS 桥（覆写 `window.WebSocket` 走内核）。

### 流式响应

- 6.1.5 `WebResourceResponse.data` 为 `Uint8List?`（整包缓冲）。大文件/长视频
  以 Range 分块为主缓解；完整流式留给 Windows 原生插件（`IRandomAccessStream`）。

## 构建（CI 内执行，勿本地运行）

```bash
# linux amd64
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -buildmode=c-shared -o libechproxy.so ./engine/
# windows amd64（mingw 交叉）
CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go build -buildmode=c-shared -o echproxy.dll ./engine/
# android arm64（NDK r27）
CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=aarch64-linux-android21-clang go build -buildmode=c-shared -o libechproxy.so ./engine/
```
