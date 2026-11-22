# 易灵绘 Agent Studio — 电脑端 UI（正式版本）

## 1. 运行

### 1.1 先启动真实接收端（8080）

在项目根目录执行（或双击 `second_board/software/pc_client/start.bat`）：

```powershell
Set-Location E:\.code\fpga
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
& 'C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe' -X utf8 -I -B `
  second_board\software\pc_client\launch.py --no-browser
```

接收端负责板2 的 UDP 视频/控制，提供：

- `http://127.0.0.1:8080/stream`：真实 MJPEG，供 Agent Studio 预览（单个客户端，30 fps）；
- `http://127.0.0.1:8080/snapshot.jpg`：最新完整 JPEG，场景分析点击时按需取一张（不持续轮询、不落盘）。

启动器在 Windows 下会把接收端进程设为 High 优先级，避免桌面编译/其他负载把 UDP 线程饿死；这是启动器的自动行为。

### 1.2 再启动 Agent Studio（8765）

```powershell
Set-Location E:\.code\fpga\second_board\software\agent
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
& 'C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe' -E -u .\server.py
```

打开：

**http://127.0.0.1:8765/**

第一次使用先点右上角「连接设置」，填 **DeepSeek API Key** 和模型名。Key 只保存在当前服务进程内存，不写入文件或浏览器存储。没有 Key 时聊天和场景分析会明确报错，不会退回离线规则。

---

## 2. 当前功能

### 实时画面

- **板2 实拍直通**：`<img>` 直接挂 8080 的 `/stream`，浏览器原生显示真实 MJPEG，约 30 fps。
- 不再有 Canvas 模拟风景、模拟风格、LUT 叠加或快照轮询显示；没有实拍信号时显示“等待板2 实拍视频”。
- 暂停会抓一张当前帧冻结显示；恢复后重新连接 8080 `/stream`。
- 画面里的分屏/风格由板1 自己的输出决定；本 UI 不叠加第二层假画面。

### 场景分析（一次性云端分析）

- 点击「画面扫描」时：
  1. 抓取**当前一帧**真实画面；
  2. 缩成 480px JPEG；
  3. 把这张图和提示词放进**同一个 `/api/chat` 请求**，直接发给 DeepSeek 视觉模型；
  4. 用云端返回的分析和推荐更新聊天区。
- 不再有浏览器端本地“场景分析”作为主结果，也不会持续轮询画面。
- 亮度/对比/饱和/冷暖/主色只是画面读数面板的本地参考；真正的分析/推荐以云端回复为准。
- 没有 API Key、网络失败或模型不支持视觉时，明确报错，不伪造分析结果。

### 风格 / 调色表 / 颜色模式

- 手动面板已接真实控制：模型和调色表用「上一/下一」，AI/FX/饱和用 ±5%，颜色模式绝对切换，Keep Color 切换，视图用「下一视图」，输入模式走 `video_mode_0..3`。
- 动作链路：8765 `/api/real-action` → 8080 `/api/control/action` → 板2 → UART → 板1，等 A 回执；失败会明确 toast。
- 26 个风格芯片和 13 张调色表卡片是**只读目录**（板端无绝对读回），点击只提示用上方「上一/下一」。

### Agent 对话

- 只支持 DeepSeek 云端，**没有离线模式**。
- 连接设置只包含模型名和 API Key，没有“离线规则”选项。

---

## 3. 目录关系与数据流

| 路径 | 角色 | 状态 |
| --- | --- | --- |
| `second_board/software/agent`（本目录） | **电脑端 UI 正式版** + 云 Agent | 可用；本文档 |
| `second_board/software/apk/android-client` | 安卓端 UI | **半成品**；不作 PC 基线 |
| `second_board/software/pc_client` | 8080 实板接收页 | 实板 MJPEG/控制接收端 |
| `hardware/.../source/net_web` | 接收后端 / 协议 / 控制面 | 实板视频链路 |

```text
板2 --UDP 5001--> pc_client 接收端 --/stream MJPEG (30 fps)--> Agent Studio (8765) 预览（浏览器只解码这一次）
                                      --/snapshot.jpg（点击时一张）--> 场景分析抓一帧
                                                                          |
                                                                   同一 /api/chat 请求发 DeepSeek
```

Agent Studio 不直接接 UDP、摄像头、HDMI 或 FPGA；实板视频统一由 8080 接收端提供。8080 同时只应保留一个 `/stream` 客户端（Agent Studio 预览）；不要再同时打开 8080 的另一个 MJPEG 页面，否则会增加接收端负载。

---

## 5. 文件导航

```text
server.py                 HTTP 后端、云 Agent、单帧场景分析、运行入口
core.py                   能力表、参数校验、LUT/配方、UART 帧
provider.py               固定 DeepSeek API 请求与严格 JSON 校验
gateway.py                内嵌/UDP 软件网关、HMAC、去重和状态版本
web/index.html            电脑端工作台页面（正式 UI）
web/app.js                会话、控制、实拍 MJPEG 直通与单帧云端分析
web/style.css             桌面优先样式与窄屏适配
tests/test_agent.py       参数、HTTP、DeepSeek mock、UDP 集成用例
docs/ARCHITECTURE.md      进程边界和失效处理
docs/PROTOCOL.md          HTTP、UDP、UART 格式
```

---

## 6. 已知边界

- **没有离线模式**：未配置 DeepSeek Key 时聊天/场景分析明确失败，不会退回本地规则。
- 预览依赖 8080 的 `/stream`；场景分析点击时向 8080 按需取一张 `/snapshot.jpg`，不持续轮询、不落盘。
- 本服务没有 TLS，只在可信局域网使用。
