# RISC-V 整帧控制

RISC-V 固件通过 APB 配置摄像头、模型和显示，领取完整输入帧，启动整帧任务并发布处理结果。PL 内的帧执行器调度 NPU 和后处理条带。像素流经 FPGA 数据通路，CPU 通过寄存器交换控制和状态。

控制窗口基址为 `0xF8100100`。寄存器及位定义见 [style_system.h](../software/style_system.h)，固件控制流程见 [style_control.c](../software/style_control.c)，领取、执行和发布的硬件条件见 [style_cpu_control.sv](../rtl/style_cpu_control.sv)。

| 命令 | 值 | 操作 |
| --- | --- | --- |
| `SYS_LOAD_FLASH` | 1 | 启动模型资产加载 |
| `SYS_CLAIM_CAMERA` | 2 | 领取最新完整摄像头帧 |
| `SYS_START_FRAME` | 16 | 启动已领取帧的处理 |
| `SYS_PUBLISH_FRAME` | 4 | 发布完成的结果 |
| `SYS_RELEASE_CAMERA` | 8 | 释放已领取的输入帧 |

输入模式编号 0 至 3 对应 1080p30、720p30、854×480p30 和 854×480p60。固件在安全帧间请求切换，等待匹配模式的新完整输入帧。HDMI 输出时序为 1080p60。
