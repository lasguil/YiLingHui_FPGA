
# 板 2 扩展板工程

本工程通过 HDMI 接收板 1 的画面，执行手势推理和 MJPEG 编码，通过以太网传输视频，并通过板间 UART 向板 1 转发手势和控制命令。

- Efinity 2026.1 工程入口为 `ti60f225_oob.xml`，RTL 清单为 `sources.f`。
- Windows 完整构建入口为 `build_ok_pause_all.bat`，板 2 RISC-V 固件位于 `software/gesture_firmware`，板 2 手势部署模型位于 `software/gesture_firmware/model`。
- 接口见 [网络控制协议](docs/network_control_protocol.md) 和 [板间 UART](software/gesture_firmware/docs/return_uart_protocol.md)。
- [手势模型工具](tools/gesture_model/) 用于重新提取和打包模型，以及在 CUDA 上验证整数推理。
