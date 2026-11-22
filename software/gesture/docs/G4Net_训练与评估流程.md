# G4Net 训练与评估流程

> 更新：2026-10-15。**当前模型为 v4**（手掌 / 一根手指朝上 / 拇指朝下 / 其他，方形 192×192 输入），定义见 [单模型方案](手势交互_单模型方案.md)。
> 采样与损失口径见 [四分类训练策略](四分类训练策略_采样与负样本.md)，网络与量化约定见 [G4Net 模型设计](G4Net_v1_模型设计.md)。

## 1. 构成

仓库 `gesture/` 是源码，服务器 `ml/` 只运行代码。代码与数据一律通过
[server/sync.sh](../server/sync.sh) 部署，凭据留在 gitignore 的 `tmp/gssh.py`，不进版本控制。

| 环节 | 文件 |
|---|---|
| 数据索引与划分 | `src/index.py`、`tools/build_index.py` |
| 外部负样本裁切 | `tools/ingest_external_negatives.py` |
| 手部尺寸测量（v1 用过，v2 未启用） | `tools/build_hand_size_table.py`、`tools/build_small_hand_overrides.py` |
| 数据集与增强 | `src/data.py`（PIL，letterbox 之前施加） |
| 分层采样 | `src/sampler.py` |
| 损失 | `src/losses.py`（CE / focal） |
| 指标 | `src/metrics.py` |
| 训练循环 | `src/train.py`、`tools/train_g4net.py` |
| 评估 | `src/evaluate.py`、`tools/eval_g4net.py` |
| 判定规则 | `src/decision.py`、`configs/g4net_v*_decision.json` |
| 进度与诊断 | `tools/training_progress.py`、`tools/sweep_target_threshold.py`、`tools/analyze_confusion_by_subclass.py` |
| 摄像头 demo | `tools/webcam_demo.py` |
| 回归自检 | `tools/selfcheck_pipeline.py`、`tools/smoke_train_g4net.py` |
| 服务器启动 | `server/run_baseline.sh` |

**`src/model.py`、`src/preprocess.py` 未被改动**，`src/spec.py` 只增加了 v2 的类别表（网络体两版共用）。
预处理仍是训练/部署一致性的唯一权威：增强只在 letterbox 之前施加，因此无增强样本与推理路径逐元素相同（自检里有这条断言）。

**类别表属于 checkpoint 的身份。** `src/train.py` 的 `load_model_from_checkpoint` 按 checkpoint 内嵌的
`model_id` 取类别表再建模型——不能拿当前默认配置去加载旧版权重，否则权重形状相同、加载不报错，
但四个输出的含义已经错位。

## 2. 服务器工作区

```text
/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015/
├── ml/                 # 代码
├── datasets/           # 图片、external_negatives/、index.jsonl、历史索引摘要
├── runs/               # 每次训练的产物
├── logs/               # 长跑日志
└── tmp/                # TMPDIR：临时文件必须落在项目目录内，不能用 /tmp
```

专用解释器：`/data1/fpga_style_transfer_2026_tmp/envs/starry/bin/python`。

## 3. v4 索引

`datasets/index.jsonl`，**169,941 行**，`index_sha256` 见 `datasets/index_summary.json`。

| 类别 | train | val | test | 合计 |
|---|---:|---:|---:|---:|
| 手掌 | 6,346 | 352 | 352 | 7,050 |
| 一根手指朝上 | 18,922 | 1,051 | 1,051 | 21,024 |
| 拇指朝下 | 6,326 | 351 | 351 | 7,028 |
| 其他 | 121,355 | 6,742 | 6,742 | 134,839 |

划分按类别分层随机，`seed=20261015`，比例 90/5/5，不按人物（口径见训练策略 §2）。

**相对 v3 少 7,183 行，就是整份 `其它/four`。** 它是配置里显式丢弃的（见下），不是漏掉：
`169,941 = 177,124 − 7,183`，去重丢弃仍是 60。`other` 从 142,190 变成 134,839
（−palm 7,050 转正类，+fist 6,882 转负样本，−four 7,183 丢弃）。
**因为构成变了，v4 的 `other` 误报率与 v3 不可直接比**，预期会上升。

### 3.1 丢弃目录：`drop_subdirs`

"整份不要"这件事在 v4 之前没有表达能力。`exclude_subdirs` 的语义是**"由别的 root 认领"**
（like/one/mute 归 finger_up、dislike 归 thumb_down 就是这么做的），拿它丢数据会让配置产生歧义——
读的人分不清某个名字是被移走还是被扔掉。

所以 v4 引入了 `drop_subdirs`：**被丢弃的目录没人认领，也不进索引**。四条规则由代码强制：

| 规则 | 触发 |
|---|---|
| 被丢弃的目录必须在磁盘上存在 | 否则报"可能是过期规则，会把图悄悄放回来" |
| 丢弃后索引里不得再出现该目录的图 | 否则报"有别的 root 把它认领回来了"——这条才是真正堵住静默失败的那条 |
| 同一个名字不能既 exclude 又 drop | 两种语义互斥 |
| 必须记录在索引摘要里 | `index_summary.json` 的 `dropped_subdirs`，`build_index.py` 直接打印 `dropped by config: 其它/four` |

四条都在 `tools/selfcheck_pipeline.py` 里，共 5 条不变量。

索引构建另外会拒绝三类过期/危险配置：排除项不在磁盘上、覆盖路径不在数据集里、**同一张图被两个 root 认领**。
最后一条在 v2 上救过一次：v2 的训练配置最初漏了 `手掌/palm`、`手掌/stop`、`手背/stop_inverted`，
索引总数从 177,124 掉到 156,039 —— **每次改类别定义后第一件事是核总数**。

## 4. 外部负样本

`tools/ingest_external_negatives.py` 从风格迁移正在使用的 `datasets/coco20k/source`、
`div2k/source/DIV2K_train_HR`、`flickr2k/source` **只读**取原生分辨率图，
各裁一张**居中的方形**、边长上限 512、存 JPEG，写入我们自己的 `datasets/external_negatives/`。

**v3 把它从 16:9 改成了方形**，因为其它训练图都是方的、输入也是方的：一张 16:9 的负样本会是全 batch 里唯一需要
letterbox 的样本。改法是**从原生分辨率重新裁**（23,449 张，0 失败，80.6 秒），
而不是把旧的 512×288 再居中裁一刀——那样会丢掉 44% 的画面。
v2 那批 16:9 负样本完整保留在 `datasets/external_negatives_v2_16x9/`（1.9 GB），所以 v2 的索引仍然可重建。

取原生分辨率而不是 256×256 的 `main_256`，是因为后者对边长 512 的方形裁切来说尺寸本身就不够，等于先降采样一次。

标签状态记为 `source_attested`（源级认定无手，未逐图审核），HaGRID 记为 `auto`。逐来源指标就是用来暴露这个差异的。

## 5. 如何启动

```bash
# 1) 部署代码（本地执行）
bash gesture/server/sync.sh

# 2) 预检：300 步 + 一次评估，前台跑，约 1 分钟
bash ml/server/run_baseline.sh preflight

# 3) 完整基线：40,000 步，后台跑
bash ml/server/run_baseline.sh full
```

`run_baseline.sh` 有三道守卫：GPU1 剩余显存低于 `MIN_FREE_MB`（默认 4000）拒绝、
本阶段要写的运行目录已存在拒绝、索引/摘要/配置缺失拒绝。GPU1 与本项目其它任务共享，
判据是**剩余显存**而不是是否被占用。启动后务必复查进程确实落在目标卡：

```bash
nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv
ps -ww -p <pid> -o user=,cmd=
```

**脚本必须保持 LF 换行。** 在 Windows 上用会做换行转换的写文件方式改 `.sh`，bash 会把
`set -euo pipefail` 读成 `pipefail\r` 并报"无效的选项名"。

## 6. 运行产物

```text
runs/<tag>/
├── config.json              # 本次运行的完整身份：配置/模型/索引指纹、采样构成、精度串
├── train.jsonl              # 每 25 步一行 loss，每次评估一行指标
├── progress.json            # 最新状态，原子覆盖
├── COMPLETE.json            # 仅训练结束后写入
├── latest_val_metrics.json  # 最近一次评估的完整指标
└── checkpoints/
    ├── step_%06d.pt         # 每次评估存一份，内嵌 config 与指标
    ├── best_macro_f1.pt     # 验证 macro-F1 最优
    └── best_deploy.pt       # 满足目标召回下限时，其他类误报率最低
```

两个候选并存，是为了避免只用总体准确率选模型——其他类占约八成，
只报总准确率会掩盖目标类的漏检。`target_recall_floor` 在训练配置里，当前 0.8。

## 7. 指标口径

必须同时看这几项，`tools/eval_g4net.py` 都会输出：

- 4×4 混淆矩阵、逐类 precision/recall/F1、macro-F1。
- **目标类误报率** =（真实其他被误判成该类数）/（真实其他总数），另有 `any_target` 是三者的并集。
- 按 `source_dataset` 拆分的误报率（`hagrid` 与三个外部来源分开）。

`accuracy` 会被记录，但不作为选择依据。softmax 数值也不等于已校准概率，
接收阈值由 `src/decision.py` 的规则决定，要等真实摄像头验证，见训练策略 §7。

## 9. 判定规则与摄像头标定

`src/decision.py` 支持三种规则：纯 argmax、单一阈值（最强目标类达标即胜出）、
以及按优先级排列的级联（`configs/g4net_v1_decision.json` 是 v1 标定过的级联示例）。
规则放在 `configs/g4net_v4_decision.json`，**demo 与离线报告共用同一个函数**，不会出现演示与验收两套。
**阈值属于几何**：v3 换了输入尺寸，分数分布跟着变，v2 标定的阈值不能沿用。

**几何跟着 checkpoint 走。** 输入尺寸是 checkpoint 身份的一部分（网络体与输入尺寸无关，所以拿错配置不会报错、
只会静默地按错误尺寸预处理）。`src/spec.py` 的 `INPUT_BY_MODEL` 按 `model_id` 固定每个版本的输入，
`GestureDataset`、`evaluate_model`、`webcam_demo` 都从 checkpoint 的 `model_id` 解析几何，不读模块默认值。

**服务端与本地推理的耗时（RTX 3060 Laptop，b300 权重）**：整条链路 720p 下约 23 ms（44 fps），
其中 PIL letterbox 11.6 ms、模型前向 8.0 ms。前向是固定开销主导——批量 1 到 32 都是约 8 ms，
真正计算每帧约 0.25 ms。给 30 fps 摄像头用有余量，瓶颈在预处理而不在模型。

**标定流程**：`tools/webcam_demo.py` 起摄像头（**默认先取画面中央的方形**，这是必须的，整幅 16:9 送进去就是失败情形；
`c` 键可切换对照）→ `s` 键截存带分数的样本到
`gesture/camera_sessions/<会话>/`（`frame_XXXX.jpg` + `predictions.jsonl`，
记录里带 `crop`、`crop_box`、`model_config` 与 `model_input_geometry`，存的是**整帧**，
所以以后要按别的框重裁或做同域验收集都不用猜）→ 用这些样本定阈值。
自采数据要按会话分组，一部分进训练、另一部分留作验收，**不能既训练又验收**。
