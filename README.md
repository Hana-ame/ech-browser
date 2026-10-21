# ech-browser

**点开即用的通用 ECH 独立浏览器**：flutter+webview 做外壳，go 内核在 webview
拦截层背后按 Host 全自动做 ECH / TCP ClientHello 分片 / SNI 伪装直连。

- **任意 http(s) 网址与关键词搜索**都可访问（地址栏输入网址或搜索词即用），不限单一站点
- **无需修改系统 hosts**：webview 只与本地回环代理打交道
- **无需手动安装证书**：上游 TLS 由 go 内核用系统信任根完成严格校验，webview 层全程明文回环
- 跨平台：Windows（WebView2）/ Android（WebView）/ iOS（WKWebView）/ Linux（WebKitGTK）/ macOS

## 架构

```
Flutter 壳（智能地址栏 + webview + JS Fetch 桥 + 状态/设置/日志）
  └─ 拦截桥：webview 请求 → 127.0.0.1:<port>（保留原始 Host 与 X-ECH-Scheme，代理内闭环跟随 3xx 重定向）
go 内核（engine/，c-shared，多 DoH 容灾 + ECH + TCP 分片 + uTLS Chrome 指纹）
  └─ RoundTrip 全自动路由：
     • Cloudflare 站点 → ECH (Encrypted Client Hello) → 分片真实 SNI → SNI 伪装 → 直连兜底
     • 非 Cloudflare 站点 → DoH 真实 IP + TCP ClientHello 分片 + 真实 SNI → SNI 伪装 → 直连兜底
真实上游（任意站点）
```

- `engine/main.go`：c-shared 入口，12 个 FFI 导出
  （`ECHSetDohURL/ECHInit/StartProxy/StopProxy/GetProxyPort/IsEchReady/ECHGetLog*/…`），
  回环明文 HTTP 监听（优先 8443，占用则随机端口），支持请求体缓冲重放、HTML 转义错误页与 SSRF 防护
- `engine/ech/`、`engine/netdial/`：DoH 主用 moonchan.xyz（国内 DoH 不能用于穿墙场景），Cloudflare DoH 兜底，可自定义、
  ECH 配置自动拉取与握手机制失效重拉、TCP ClientHello 分片、服务端证书链信任根校验
- `lib/`：Flutter 外壳（智能地址栏、webview、连接池化拦截桥、POST/PUT/PATCH/DELETE JS Fetch 桥、防盗链下载、DoH 设置与日志）
- Dart 侧 FFI 绑定见 `lib/proxy_manager.dart`，拦截与重定向改写见 `lib/interceptor.dart`

## 使用

### Windows 桌面版
1. 从 Releases 下载 `ech-browser-windows-x64.zip`，**整个解压**（包内已含
   `flutter_windows.dll`、插件 dll、`data/` 运行库与 VC++ runtime）
2. 双击 `ech_browser.exe`（`echproxy.dll` 与运行库与 exe 同目录）
3. 地址栏输入任意网址或搜索词即可；右上角设置按钮可自定义首选 DoH 或重启内核

### Android 移动版
1. 从 Releases 下载 `ech-browser-android-arm64.apk` 直接安装（已内置 `libechproxy.so` 与回环明文许可）

## 能力矩阵（v0.3.0 生产就绪版）

### 已完整支持
- **任意网址（Cloudflare 与非 Cloudflare 站点）**：
  - Cloudflare 站点走 ECH 加密 ClientHello；
  - 非 Cloudflare 站点走 DoH 真实 IP + TCP ClientHello 分片 + 真实 SNI（带完整证书校验），彻底解决非 CF 站点因伪造 SNI 被拒或误送 CF 报 530 的问题
- **Gzip / Deflate / Brotli 透明传输**：拦截器禁用 `dart:io` 默认二次解压，消除 `ERR_CONTENT_DECODING_FAILED`
- **3xx 重定向闭环跟随**：在拦截器内部逐跳经本地 Go 内核跟随 301/302/303/307/308 重定向并同步 `Set-Cookie`，防止 `dart:io` 直连跳出代理或丢失 Host
- **GET / HEAD / OPTIONS 及 Fetch POST/PUT/PATCH/DELETE**：
  - `GET/HEAD/OPTIONS`（含 CORS 预检）由 `shouldInterceptRequest` 直接转发；
  - 带请求体的 `fetch`（`POST/PUT/PATCH/DELETE`）由顶层注入的 JS 桥经 `echFetch` 通道转发至 Go 内核
- **Cookie / 登录态同步**：多条 `Set-Cookie` 独立解析并同步至 WebView `CookieManager`，避免逗号折叠破坏 `Expires`
- **防盗链下载（如 Pixiv 原图）**：自动携带当前页 `Referer`、`Cookie` 与 `User-Agent` 经内核下载，并对文件名做安全清洗
- **多 DoH 节点自动容灾**：默认内置阿里 DoH、腾讯 DoH、Cloudflare DoH 等多节点自动故障切换，且可在 UI 设置中动态修改

### 平台边界说明
- **原生 HTML `<form method="POST">` 整页同步提交与 WebSocket / WebRTC**：
  现代站点（SPA / AJAX）使用的 `fetch()` POST 已通过内置 JS 桥走 ECH 内核；传统非 JS `<form>` 整页 POST 及原生 WebSocket 仍受平台 WebView API 限制走直连。

## 构建（CI 内执行）

```bash
# 运行 Go 静态检查与单元测试
go vet ./...
go test -v -race ./...

# linux amd64
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -buildmode=c-shared -o libechproxy.so ./engine/
# windows amd64（mingw 交叉）
CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go build -buildmode=c-shared -o echproxy.dll ./engine/
# android arm64（NDK r27）
CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=aarch64-linux-android21-clang go build -buildmode=c-shared -o libechproxy.so ./engine/
```

## CI 验证（本仓禁止本地测试）

- `go-test`：`go vet` + `go test -race`（离线单测：SSRF 防护/路由/错误页 XSS/ClientHello 分片等）
- `go-cshared`：linux / windows(mingw 静态) / android(NDK) 三平台 c-shared 构建
- `flutter-analyze` / `flutter-test`
- `windows-smoke`（每次 push）：构建 exe → 整目录 stage → 启动 exe → 等内核 8443 →
  用 `Host: www.pixiv.net` curl 内核**真发一次 ECH 请求**，断言 2xx；崩溃码分级
  （缺 dll/坏镜像失败，无头会话 WebView2 访问违例仅警告）
- `release`（v* tag）：Android APK 构建 + Windows 包 smoke 通过后发布正式 Release

## 平台支持矩阵

| 平台 | 产物 | 状态 |
|---|---|---|
| Windows x64 | `ech-browser-windows-x64.zip` | ✅ 发布前经 CI 启动 smoke + 真实 ECH 请求验证 |
| Android arm64 | `ech-browser-android-arm64.apk` | ✅ CI 构建（两套 WebView 平台 API 差异见边界说明） |
| Linux | — | ⏸ 暂不发布：flutter_inappwebview 6.1.x 无 Linux 实现（6.2.0-beta 才加入），构建出的包没有 webview |
| iOS | — | ⏸ 暂不发布：iOS 需要 macOS runner + 签名证书；WebView 层已具备（flutter_inappwebview_ios） |

### 下载与设置

- 下载文件落到**用户 Downloads 目录**（不可写时回落系统临时目录），重名自动追加 ` (n)` 后缀
- DoH 地址在「设置」里可改并**持久化**到 `~/.ech-browser/settings.json`，重启内核仍生效

## 故障排查（Windows 闪退）

按顺序排查：

1. **解压目录里 exe/dll 是否还在**。若运行过之后顶层文件消失（只剩 `data/`、
   `ech_browser.exe.WebView2/`）→ 99% 是**杀毒软件隔离**（exe 未签名，会被误报）。
   - 打开「Windows 安全中心 → 病毒和威胁防护 → 保护历史记录」确认
   - 把解压目录加入排除项，重新解压运行
2. **看内核落盘日志**：`%USERPROFILE%\.ech-browser\kernel.log`
   （go 内核每次启动/每个请求都写；闪退前的最后一行就是现场）
3. **看 Dart 崩溃日志**：`%USERPROFILE%\.ech-browser\crash.log`
   （未捕获的 Dart 异常会落盘）
4. 仍无法定位时，把上面两个日志文件回传即可。
5. 若提示缺少 WebView2 运行时：安装 Microsoft Edge WebView2 Evergreen Runtime
   （Win10/11 通常随 Edge 自带）。

> v0.3.2 起：请求处理链的 panic 已被兜底（返回 500 错误页而不 abort 整个进程），
> 并新增上述两个落盘日志；CI smoke 也会验证 panic 兜底生效。

## 已知问题

全部问题（已修 / 未修 / 平台限制 / 环境性 / 工程坑）如实记录在
[ISSUES.md](ISSUES.md)，含每条取证方式与当前状态。
