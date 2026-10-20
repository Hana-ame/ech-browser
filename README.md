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

1. 从 Releases 下载 `ech-browser-windows-x64.zip`
2. 解压双击 `ech_browser.exe`（`echproxy.dll` 必须与 exe 同目录）
3. 地址栏输入任意网址即可；状态栏显示内核端口，日志页可看内核诊断

## 已知边界（MVP）

- WebSocket / WebRTC / Service Worker / QUIC 不在 webview 拦截范围内（各平台一致）
- Android `shouldInterceptRequest` 拿不到 POST body，登录表单在 Android 端需
  专项处理（Windows WebView2 可取 body，无此限制）

## 构建（CI 内执行，勿本地运行）

```bash
# linux amd64
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -buildmode=c-shared -o libechproxy.so ./engine/
# windows amd64（mingw 交叉）
CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go build -buildmode=c-shared -o echproxy.dll ./engine/
# android arm64（NDK r27）
CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=aarch64-linux-android21-clang go build -buildmode=c-shared -o libechproxy.so ./engine/
```
