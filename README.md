# 易灵绘：FPGA 实时视频风格化系统

本仓库是 2026 年全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道项目的源码快照。系统以 Ti60F225I3 为核心，包含摄像头采集、FPGA 风格化推理、视频后处理、HDMI 显示和交互控制，并包含扩展板与客户端代码。

## 目录

- [板 1 · 核心板](hardware/main_board/)：摄像头采集、风格化推理、显示及 RISC-V 控制。
- [板 2 · 扩展板](hardware/network_board/)：HDMI 输入、手势推理、MJPEG 推流及远控。
- `software`：Android、PC、Agent 客户端和手势软件。
- `assets/styles/deploy`：按顺序编号的 29 个风格部署包；`assets/luts/lut` 为 LUT。核心板 `assets` 内包含已打包文件。
- `training/style_model`：部分模型训练代码。
- [赛题原文摘录](docs/赛题1_原文摘录.md)
- [外壳建模与加工文件](enclosure/)：FreeCAD 装配、亚克力切割图和 3D 打印模型。
- [`showcase`](showcase/)：初赛海报、技术文档、视频和图片。海报与视频使用 Git LFS。

核心板编译使用 Efinity 2026.1 和 Efinity RISC-V 工具链，具体路径参见工程脚本。模型包可用核心板 `tools/generate_model_assets.py` 生成。运行程序需要对应硬件及外设，设备配置和凭据应由使用者自行提供。
