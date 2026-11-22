# Agent 与软件网关协议

## HTTP API

- `GET /api/status`：读取服务端最近已知快照，不保证外部网关没有变化。
- `POST /api/refresh`：空对象请求；向网关发送新 status 请求并更新状态/版本。状态读回失败时返回未知状态，设备操作保持锁定。
- `POST /api/chat`：`{"text":"...","revision":N}`，上限 2000 字符；返回已验证计划、模拟执行和快照。模型等待期间 revision 改变则拒绝旧计划。
- `POST /api/control`：`{"revision":N,"changes":{...}}`，revision 不符则拒绝。
- `POST /api/settings`：设置 offline/deepseek、模型名及可选 Key。空 Key 保留现有 Key，`clear_key:true` 清除。
- API 必须带 `X-Session-Token`。请求体最多 16 KiB，全部为同源 JSON。

控制请求示例：

```json
{"revision": 7, "changes": {"style": "ink", "ai_strength": 65}}
```

对话请求示例：

```json
{"revision": 7, "text": "切换到水墨，AI强度65%"}
```

revision 必须为 JSON 整数（布尔值不接受）。成功提交后返回 `revision=8`；若本地触摸或另一控制端先提交，旧版本返回冲突，客户端应读取新状态、展示给用户，再由用户重新发起操作。HTTP API Key 由 UI 提交给 PC 后端，仅服务端内存持有；浏览器不直接向模型服务或 UDP 网关发请求。

参数字段在 `core.py` 的 DEFAULT/ENUMS/RANGES 中登记。整数验证使用精确类型检查，避免 Python 中 `bool` 被当作 `int` 接受。未知字段、超界值和部分无效 patch 整体拒绝。

## UDP 软件网关

消息以规范 JSON UTF-8 编码，并包裹 `{payload, mac}`；MAC 为 HMAC-SHA256。payload 带 v1、唯一请求 ID、unix 时间和 op。apply 另带 boot_id、revision 与 changes。网关校验时间窗、认证、版本和全部字段后原子更新语义状态，并缓存 256 个请求 ID；完全相同的重传返回原响应，ID 内容不同则拒绝。

客户端以同一 ID/正文重试最多三次。没有收到确认时报告结果未知，不能把发送成功解释为提交成功。服务读回完整状态后由上层处理。这个网关只用于软件演示，不是第一板协议实现。

逻辑 envelope 示例（MAC 是占位说明，需由共享密钥对规范 payload 实际计算）：

```json
{
  "payload": {
    "v": 1,
    "id": "7e87c4d3f2d84d6e9d15c1b650000001",
    "time": 1792600000.0,
    "op": "apply",
    "boot_id": "simulator-boot-id",
    "revision": 7,
    "changes": {"style": "ink", "ai_strength": 65}
  },
  "mac": "HMAC-SHA256(canonical(payload), shared_secret)"
}
```

UDP 仅在 PC 后端与 loopback 软件网关之间使用。手机浏览器控制路径是 HTTP JSON；浏览器无裸 UDP 传输能力，也不连接板载 Ethernet PHY。

## UART 帧预览

以 A5 5A 同步字开头，后接版本 1、消息类型、LE uint16 序号、LE uint16 payload 长度、0–54 字节 payload 与 LE CRC-16/CCITT-FALSE。CRC 覆盖版本至 payload，poly 0x1021、init 0xFFFF、无反射、xorout 0。当前确定的消息类型来源于 `hardware/network_board/software/gesture_firmware/docs/return_uart_protocol.md`。仅展示能够按该注册表与既有编码生成的帧；本软件模拟器不会把 preview 写入串口。

当前工作树的登记编码：输入模式使用 `0x10 VIDEO_MODE_SET`；空间效果与颜色模式使用 `0x13 EFFECT_SET`。AI/FX 强度、视图、饱和度、曲线等不得凭空补 opcode 或把百分数猜成 native 值，UI 会标出 unmapped。最终第一板固件应回复 `APPLIED` ACK 和带 boot/revision 的状态快照后，Agent 才可报告设备侧确认；当前候选没有第一板接收命令实现，因此本 demo 中的状态只是软件提交。
