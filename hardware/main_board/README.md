# 核心板工程

工程入口为 `ti60f225_oob.xml`，RTL 源码清单为 `sources.f`，RISC-V 固件位于 `software`。`compile.bat` 使用 Efinity 2026.1 和 RISC-V 工具链，先生成固件 ROM，再进行综合、布局布线和时序检查。脚本包含原开发机路径，使用前请按环境调整。

`assets/model_bundle_29x16k_lut12.bin` 包含 29 个模型槽及 12 个 LUT，可通过 `tools/generate_model_assets.py` 从仓库内的部署数据重新生成。FPGA 配置默认通过 `program_jtag.bat` 临时加载。模型和 LUT 通过 `tools/program_model_bundle_hiftdi.py` 写入外部 Flash 的 `0x00400000` 区域，脚本默认只检查部署计划。

工程集成摄像头、NPU、颜色处理、显示及交互控制；当前软件为裸机主循环。实际运行效果依赖板卡、模型资产和完整构建结果。

- [RISC-V 整帧控制](docs/RISC-V整帧控制.md)
- [板间 UART 协议](software/GESTURE_UART.md)
- [UI 寄存器接口](software/UI_PROTOCOL.md)
- [布线后时序检查](docs/BOARD1_TIMING_SIGNOFF_GATE.md)
