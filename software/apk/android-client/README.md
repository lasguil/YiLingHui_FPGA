# Ti60 Android 视觉终端

Android 手机原生接收 VI v2 UDP 分片，完整 JPEG 原样交给手机本机 HTTP + WebView。日常运行无需电脑、Python、Internet 或云服务。

## 安装与使用

1. 安装 `deliverables/Ti60Mobile-1.3.2-debug.apk`（开发签名，允许本次来源安装）。最低 Android 10。
2. 打开“Ti60 视觉终端”，点顶部「连接板卡」；首次允许附近 Wi-Fi/定位权限，并在系统弹窗确认连接 `VONETS_2.4G_9C4C`。App 读到手机 IPv4 后会写板端 `0x0014`（手机 IP）和 `0x0018`（5000），收到 `NB01` 回执后启动 UDP 5001/5000，顶部状态应变为「视频接收中」。
3. 也可在「链路诊断 → 连接设置」里手动改 VONETS SSID/密码、板 IPv4（默认 `192.168.0.2`）、监听端口（默认 `5001`）后点「开始接收」；控制端口固定 5000。
4. “停止”只停止 App，不改变板端出流。离开 App 自动暂停，返回恢复。横竖屏旋转不重新创建接收器。
5. 快照保存至 `Pictures/Ti60`，统计 JSON 保存至 `Download/Ti60`，日志保存至 `Download/Ti60/Ti60_log_*.txt`，无需相册/存储权限。没有完整帧时不生成假 JPEG。

## 手机手动控制与 Agent

实板接收模式提供有限白名单的手动控制按钮。Agent 先生成可审阅的动作计划，用户再按“执行已预览计划”明确确认；更改计划需要重新生成和预览。离线规则是小型规则解析器，会明确标作“不是 LLM”。可选 DeepSeek 使用固定官方 HTTPS endpoint，API Key 仅留在 App 当前进程内存，不写设置、文件或日志。云端返回也必须通过严格 JSON/动作白名单验证；不提供 URL、命令或文件工具。

控制由板2 J7/UART 桥接至板1。每条命令等待同 token 的 `A_STATE=5`（accepted）后才执行下一条；拒绝、超时或 commit 结果未知会停止序列，非幂等 commit 不重发。accepted 只表示板1接收了命令，不证明 HDMI 画面已经应用。模拟源模式禁止发送真实板命令。没有参数读回时不承诺精确绝对值或指定命名模型；只支持可确认的相对和模式动作。

板视频与控制 UDP socket 单独绑定 Wi-Fi，手机可在 VM300-L 纯局域网 AP 上接收本地视频/控制；整个 App 不绑定到局域网 Wi-Fi。DeepSeek HTTPS 走具 Internet 且已验证的网络；若该 Wi-Fi 没有公网，App 会在系统允许时请求蜂窝 Internet，最多等待约 12 秒，不会自动开启移动数据。蜂窝回退使用 Android 普通 `CHANGE_NETWORK_STATE` 权限发出 `requestNetwork` 请求；这不代表 App 会打开移动数据。没有可用公网时云端计划会明确失败，不生成伪造 Agent 结果；离线规则与局域网视频仍可使用。

## 构建

锁定工具版本：AGP 8.9.2、Kotlin 2.1.20、Gradle 8.11.1（Wrapper JAR、distribution SHA256 已锁定），compile/targetSdk 35、minSdk 29、Java/Kotlin bytecode 17。使用 JDK 17 和仓库现有 Android SDK Platform 35、Build Tools 35.0.0。无第三方运行时依赖；JVM 测试使用 JUnit 4.13.2 与 `org.json`，版本锁定于 `app/gradle.lockfile`。Gradle 缓存和构建临时文件放在本项目 `tmp/` 下。

Windows PowerShell 可复现构建：

```powershell
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-17'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
$env:ANDROID_HOME = 'E:\.code\fpga\second_board\software\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:GRADLE_USER_HOME = Join-Path $PWD 'tmp\gradle-home'
$env:TEMP = Join-Path $PWD 'tmp\temp'
$env:TMP = $env:TEMP
# 可选：只在当前 PowerShell 进程中设置代理 host/port；不要把账号或密码写进脚本、gradle.properties 或仓库。
if ($env:HTTPS_PROXY) {
  $p = [uri]$env:HTTPS_PROXY
  $env:JAVA_TOOL_OPTIONS = "-Dhttps.proxyHost=$($p.Host) -Dhttps.proxyPort=$($p.Port) -Dhttp.proxyHost=$($p.Host) -Dhttp.proxyPort=$($p.Port)"
}
.\gradlew.bat testDebugUnitTest lintDebug assembleDebug --max-workers=2 --console=plain
```

首次构建须访问 Google Maven、Maven Central 和 Gradle 下载服务；代理配置只作用于当前 PowerShell 进程。源码不包含本机 SDK、Gradle 缓存或私钥。debug APK 仅供开发安装，不是商店发行包。构建签名由构建环境提供。

## 数据与安全

- 视频头大端 20 字节，UDP 最大 1472，payload 最大 1452。pkt_total 必须为 0xffff。有限在途窗口 3，硬上限 4，4 MiB/帧，最多 8192 个片段/帧；JPEG 尺寸最大 4096×4096 且总像素不超过 8 Mi。
- 首片 SOF、EOF index+1 定片数，完整无缝覆盖才发布。乱序、EOF 先到、交错、相同重复均支持，冲突/重叠/超时整帧丢弃。只扫描 JPEG 头及首尾标记，不解码再编码；不修饰 FPGA 的块状失真。
- `missing` 是帧序号落后最高已见 ID 至少 3 个之后、仍完全未见任何包的帧数；收到部分包计 `incomplete`。统计可能有窗口滞后，最后几帧无后续 ID 时不推断。超大跳跃（>10000）重新建基线，避免重启伪造海量丢帧。长间断/连续回退超过 2 秒无发布后，新 SOF 可建立新会话。
- JPEG immutable buffer 交给最新帧存储；HTTP 读者各自取最新帧，无帧队列。最多 4 个视频读者，最多 8 个 HTTP worker，写阻塞 2 秒关闭慢连接。
- 本机 HTTP 只监听 `127.0.0.1:8080`，冲突自动选空闲端口。所有静态资源离线。POST 校验精确 Host、Origin 和随机会话令牌。无任意寄存器写接口、JS 原生桥、文件访问和外站导航。
- 视频/控制只使用 Wi-Fi，不要求 Wi-Fi 已验证 Internet；UDP socket 在 connect 前调用 `Network.bindSocket`，保持回环 HTTP 正常。云端 HTTPS 单独选择已验证的 Internet Network；无公网时可按系统授权请求蜂窝 Network，不将整个进程绑网。Wi-Fi 改变时重启接收/控制 socket并释放旧 socket。
- 当前 targetSdk 35。按[官方局域网权限指南](https://developer.android.com/privacy-and-security/local-network-permission)，target ≤36 不声明/请求 ACCESS_LOCAL_NETWORK；升级 target 37 前必须补充并验证其运行时授权/拒绝/撤销流程。Android 16 opt-in 可通过页面“权限诊断”入口请求 NEARBY_WIFI_DEVICES。
- 明文配置仅允许回环域，参考 [Network Security Configuration](https://developer.android.com/privacy-and-security/security-config)。为自动连接 VONETS，Android 10–12 请求定位权限、Android 13+ 请求附近 Wi-Fi 权限；不索取摄像头或麦克风。开发签名版本开启 WebView 远程调试便于 QA；正式发布应使用 release 构建。

## HTTP 接口

`GET /` 中文视频页；`GET /stream` MJPEG；`GET /snapshot.jpg` 原始 JPEG，无图 503；`GET /api/status` 完整状态；`GET /api/regs` 只读寄存器；`GET /export.json` 统计。

`POST /api/session` JSON 示例：

```json
{"action":"start","board":"192.168.0.2","port":5001,"timeout_ms":100,"simulation":false}
```

停止：`{"action":"stop"}`。请求须带同源 Origin 和 `X-Session-Token`。令牌只注入本机页面。`POST /api/decode-error` 记录网页 `<img>` 流错误，无法区分网络/浏览器解码原因，**不是精确解码失败计数**：`decode_errors=null`，`web_stream_errors` 单列。

`fps_complete` 为完整 JPEG/单调秒；`fps_http` 为全部 HTTP 读者成功写出帧的总速率，多读者时可能高于接收速率；`fps_display=null`。`assembly_ms` 仅首片到组帧完成。`ts_us` 与手机不同源，禁止直接解释成端到端延迟。UDP Mbps 包含 VI 头，不含 IP/UDP/以太网头。寄存器失败 `value=null`、保留错误；计数器差值按无符号计算，失败/重连/重启重新建基线。
