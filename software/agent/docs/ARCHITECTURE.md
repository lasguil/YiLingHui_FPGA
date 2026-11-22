# 软件演示架构

```text
桌面/手机浏览器（薄客户端）
  ├─ Canvas 风景示意与参数控件
  ├─ 会话令牌请求头
  └─ 同源 HTTP JSON API
         └─ ThreadingHTTPServer（同源+token、超时、请求体上限、操作锁、版本检查）
             ├─ 离线规则 / 固定 DeepSeek API provider
             └─ Transport → 内嵌 Gateway 或认证 UDP 软件网关
                    ├─ 原子语义状态与 boot_id/revision
                    └─ 已登记 UART v1 帧预览
```

所有状态均为 Python 软件对象。页面采用原生 HTML/CSS/JS，不使用 CDN、包管理器或第三方运行时。服务默认仅绑定 loopback；启用 LAN 绑定时，每次启动生成随机会话令牌，API 请求要求该令牌及同源 Origin。模型 Key 仅存于服务进程内存；HTTP handler 不记录请求正文、header 或来源地址。模型请求只能访问 `provider.py` 中固定的 DeepSeek HTTPS endpoint，不接受任意 URL、工具调用或命令执行。

控制过程先生成 plan，服务端再严格校验参数名、类型、枚举及范围，随后以本地 revision/boot_id 作为乐观并发条件执行。每条聊天带有计划生成时的 revision；模型等待期间再次向网关读回版本，发生变化就拒绝旧计划。HTTP `/api/status` 只返回本进程已知快照；`POST /api/refresh` 才会真正向网关请求状态。状态读回失败会将 `state_known` 置为 false，并锁住设备控制，避免旧 UI 状态继续执行。多轮模型历史只包含最近已验证的请求、最终计划和实际模拟结果。DeepSeek 请求失败或返回非法内容时直接失败，不降级执行离线规则。

UART 预览遵照工程现有 v1 envelope 与 CRC 定义。当前 serializer 登记了 0x10 输入模式和 0x13 空间效果/颜色标志，强度、视图等缺少经过固件单位核对的完整编码，故明确列为 unmapped。Gateway 的语义提交、ACK、读回和重传去重都只是接口样例，不表示真实板卡接收。

浏览器只承担控制 UI、Key 输入和低分辨率 Canvas 视觉示意。Canvas 在约 4 Hz 的节拍上绘制 320×180 原图，再做颜色/效果/风格示意运算；这不是摄像头流或模型推理。暂停会冻结最后已绘制画面，暂停中的控制仅更新待应用语义状态，恢复后才重绘。并排画面把相同场景分别 letterbox 到左右视口，以免比较时源图几何不同。

最终系统建议采用 PC Agent 后端和手机薄 Web UI。手机浏览器不直接持模型 API Key 请求 DeepSeek，也不直接使用裸 UDP；Key 发给 PC 后端进程内存。第二板通过外接 Wi-Fi AP/路由器桥接 RJ45 有线网络，当前 V4 板 PHY 是 YT8531SC，硬件资料没有显示板载 Wi-Fi 射频。网络控制应与 HDMI/NPU 数据通路隔离，网络掉线不得暂停本地视频。多入口仲裁建议由第一板单一 revision/提交点处理：本地触摸最后一次已提交操作优先，旧 revision 的 Agent 计划拒绝。压缩视频预览列为控制闭环之后的独立阶段。
