# 手势识别专区（第二块板）

当前目标：**一个模型、一个分类头，只识别单帧的「手掌 / 一根手指朝上 / 拇指朝下 / 其他」四类**（v4）。
时序和事件触发归 CPU，具体动作映射另行定义。

文档统一由 [gesture/docs 索引](docs/README.md) 管理。任务边界见 [单模型方案](docs/手势交互_单模型方案.md)，网络见 [G4Net 模型设计](docs/G4Net_v1_模型设计.md)，训练与部署流程见 [训练与评估流程](docs/G4Net_训练与评估流程.md)。

## 手部跟踪路线（MediaPipe landmark，2026-10-16）

**demo**：[tools/webcam_landmark_poll.py](tools/webcam_landmark_poll.py)。推理跑在独立线程、最小间隔 1/inf-per-sec（默认 **15 张/秒**，`--inf-per-sec 30` 可提），**显示帧率不设限**；界面实时显示 display fps / infer 张-秒 / conf / 单张耗时 / 裁剪模式 / 五指判据。`--model` 同时支持 `.tflite`（ai-edge-litert）与 `.onnx`（onnxruntime）。依赖 `ai-edge-litert`、`onnxruntime`。

**五指张开判据**（纯几何 ~30 行、无需训练、不占算力）：三个尺度无关度量——四指里最弯那根的直度（三节骨长和 ÷ 首末直线距离）、相邻手指平均夹角、拇指尖到食指根 ÷ 掌宽。**几何分不出掌心/手背**（剪影 180° 翻转不变，v1 的老问题），要分只能靠外观模型。三个阈值在 demo 里现场调（`--palm-straight/--palm-spread/--palm-thumb`）。

## 目录

```text
gesture/
├── docs/                        # 任务、模型设计、训练策略与流程，见 docs/README.md
│   └── figs/four_classes_examples.png
├── configs/g4net_v4.json         # ★ 当前模型：网络、方形输入预处理、固定类别 ID
├── configs/g4net_v4_train.json   # ★ 采样配额、池、增强、损失、划分比例、drop_subdirs
├── configs/g4net_v4_decision.json# 部署判定规则
├── configs/g4net_v3*.json        # 历史：v3（方形，正类 fist）
├── configs/g4net_v1*.json        # 历史：v1 的三份配置（16:9）
├── configs/g4net_v2*.json        # 历史：v2 的三份配置（16:9）
├── src/                         # 模型、预处理、索引、采样、损失、指标、判定、训练评估
├── tools/                       # 索引/裁切/训练/评估/诊断/demo/自检、统计与清单生成
│   └── webcam_landmark_poll.py  # ★ 手部跟踪 demo：轮询+跟踪、限速在“每秒算多少张图”
├── server/                      # 部署与启动脚本（凭据不入库，见 tmp/gssh.py）
├── models/                      # g4net 权重 + reference/（hand_landmark_lite 的 tflite/fp32/int8）
├── demo/                        # 历史 PC 调研代码、配置与 HaGRID 源码快照
├── licenses/                    # 已保存的许可原文
└── manifest.json                # 资产来源
```

## 模型：G4Net v1 / v2 / v3（共用同一网络体）

3×3 Conv/DW + 1×1 PW，通道 16→24→32→48→64→96，GAP 后 FC 输出四类。
所有卷积使用 BN/ReLU6，部署先折叠 BN；末层局部理论感受野 247×247。**三者只有"四个输出的含义"和"输入尺寸"不同**——所以输入几何和类别表一样，都是 checkpoint 的身份，加载权重必须按 checkpoint 里的 `model_id` 解析，见 [训练与评估流程](docs/G4Net_训练与评估流程.md) §3。

| 版本 | 输入 | 类别 | MAC/帧 | 训练参数 | INT8 权重 | 特征缓冲峰值 |
|---|---|---:|---:|---:|---:|---:|
| v1 | 256×144 (16:9) | 手掌正面/手背/握拳/其他 | 9,761,792 | 29,716 | 27,984 B | 258,048 B |
| v2 | 256×144 (16:9) | 拳/指朝上/拇朝下/其他 | 9,761,792 | 29,716 | 27,984 B | 258,048 B |
| v3 | 192×192 (方形) | 拳/指朝上/拇朝下/其他 | 9,685,824 | 29,716 | 27,984 B | 258,048 B |
| **v4** | **192×192 (方形)** | **掌/指朝上/拇朝下/其他** | **9,685,824** | 29,716 | 27,984 B | 258,048 B |

换成方形输入**不增加任何硬件开销**：192×192 与 256×144 的像素面积相同（36,864），所以每一级特征图的面积、MAC、权重和缓冲峰值都不变，最后一级还从 8×5 变成 6×6，对寻址更友好。手在输入里的线性尺寸反而大 1.33 倍（512→192 是 0.375，512→144 是 0.28125）。

[模型代码](src/model.py) · [详细设计](docs/G4Net_v1_模型设计.md)。

许可原文保存在 `licenses/` 及第三方源码目录；资产来源和既有许可记录见 `manifest.json`。
