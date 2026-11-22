"""生成 gesture/manifest.json：为每项保留资产记录来源、许可、大小与 sha256。

数据集（dataset/）与第三方源码目录用"相对路径+大小"的目录摘要；单文件用 sha256。
改动素材后重新运行本脚本即可刷新指纹。
"""
import hashlib
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ENTRIES = [
    # ---------------------------------------------------------------- 数据
    dict(
        path='dataset',
        role='★ 训练数据集：HaGRID 512p 镜像全量归成 4 类（手掌/手背/握拳/其它）',
        source='https://huggingface.co/datasets/cj-mills/hagrid-classification-512p-no-gesture-150k',
        license='CC BY-SA 4.0（HaGRID 系）',
        measured=dict(note='153,735 张 / 3.9 GB；手掌 palm 7,050+stop 6,893、手背 stop_inverted 7,142、'
                           '握拳 fist 6,882、其它 no_gesture 27,823 + 14 个手势类 97,945'),
    ),
    dict(
        path='licenses/hagrid_license_en_us.pdf',
        role='HaGRID 许可原文（判断 ShareAlike 是否传染）',
        source='https://github.com/hukenovs/hagrid/blob/master/license/en_us.pdf',
        license='—（许可文本本身）',
        measured=dict(),
    ),
    # ---------------------------------------------------------------- 设计与图
    dict(
        path='docs/手势交互_单模型方案.md',
        role='★ 四分类任务边界：手掌正面/手背/握拳/其他，时序归 CPU；网络详见 G4Net v1 设计',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(),
    ),
    *[
        dict(path=path, role=role, source='本项目自写',
             license='—（本项目）', measured=dict())
        for path, role in [
            ('README.md', '手势子系统资产与开发状态入口'),
            ('docs/README.md', '手势专项文档统一索引'),
            ('docs/G4Net_v1_模型设计.md', '★ G4Net v1 模型结构、预算、量化约定与训练计划'),
            ('docs/四分类训练策略_采样与负样本.md', '★ 分层采样、外部负样本、CE/focal 对照及困难回放训练计划'),
            ('docs/G4Net_训练与评估流程.md', '★ 已建成的训练管线、索引与划分、服务器启动方式、运行产物与实测数字'),
            ('docs/FPGA_低资源手势识别_设计与训练指南.md', '从根 docs 迁入的训练与部署指南'),
            ('configs/g4net_v2.json', '★ G4Net v2 结构、输入与四类 ID 的配置（网络体与 v1 相同，类别定义不同）'),
            ('configs/g4net_v2_train.json', '★ 采样配额、语义池、增强、超参、损失与划分比例的配置'),
            ('configs/g4net_v2_decision.json', '部署判定规则（v2，当前为占位阈值，待标定）'),
            ('configs/g4net_v1.json', '历史：G4Net v1 结构、输入与四类 ID 的配置（掌心正/背/拳/其他）'),
            ('configs/g4net_v1_train.json', '历史：v1 的训练配置（含 four 并入与小手划出两条规则）'),
            ('configs/g4net_v1_decision.json', '历史：v1 标定过的判定级联，demo 与离线报告共用'),
            ('src/__init__.py', '当前模型 Python 包入口'),
            ('src/spec.py', '配置读取、校验与类别顺序契约'),
            ('src/model.py', 'G4Net v1 PyTorch 模型与 FP32 BN 折叠'),
            ('src/preprocess.py', 'RGB letterbox 与输入归一化参考；训练与部署一致性的唯一权威'),
            ('src/index.py', '数据索引：枚举、sha256 去重、按类别分层划分与清单指纹'),
            ('src/data.py', '索引驱动的数据集与 PIL 增强（仅在 letterbox 之前施加）'),
            ('src/sampler.py', '池感知分层批采样：类别配额、语义池配额与空池重分配'),
            ('src/losses.py', 'softmax CE 与单标签 focal（系数参与梯度）'),
            ('src/metrics.py', '混淆矩阵、逐类 precision/recall/F1 与目标类误报率'),
            ('src/train.py', '训练循环、warmup+cosine、原子 checkpoint 与两类候选选择'),
            ('src/evaluate.py', '无增强、无类别平衡的确定性评估'),
            ('tools/profile_model.py', '解析统计与显式 CUDA 结构检查'),
            ('tools/build_index.py', '工具：构建训练索引与划分清单'),
            ('tools/build_hand_size_table.py', '★ 工具：用仓库自带手部检测器量每张图的手占画面面积'),
            ('tools/build_small_hand_overrides.py', '★ 工具：按配置阈值生成把手部过小的图划入其他的覆盖表'),
            ('tools/render_hand_size_sheet.py', '工具：渲染按手部尺寸分箱的模型输入对照图，供肉眼定阈值'),
            ('tools/ingest_external_negatives.py', '★ 工具：从风格迁移语料裁 16:9 负样本（只读源，写入本工作区）'),
            ('tools/train_g4net.py', '★ 工具：训练入口（显式 CUDA，无 CPU 回退）'),
            ('tools/eval_g4net.py', '工具：checkpoint 评估入口，输出指标与来源拆分'),
            ('tools/analyze_confusion_by_subclass.py', '工具：按源子类拆分误报，定位是哪些非目标手势在误触发'),
            ('tools/training_progress.py', '工具：从训练日志打印进度表，列名随类别集自适应'),
            ('tools/selfcheck_pipeline.py', '工具：55 项管线不变量自检（仓库与服务器均可运行）'),
            ('tools/smoke_train_g4net.py', '工具：六步端到端冒烟测试（合成数据，需 CUDA）'),
            ('tools/webcam_demo.py', '★ 工具：本地摄像头实时四分类 demo，可截存带分数的样本用于建同域测试集'),
            ('server/sync.sh', '工具：把代码部署到训练服务器（凭据留在 gitignore 的 tmp/gssh.py）'),
            ('server/run_baseline.sh', '★ 工具：服务器启动脚本（GPU1 剩余显存守卫、预检/完整两档）'),
            ('reports/g4net_v2.json', '★ 当前模型的结构统计、源码指纹与随机权重 CUDA 检查；无训练精度'),
            ('reports/g4net_v1.json', '历史：v1 的结构统计与源码指纹'),
        ]
    ],
    dict(
        path='docs/figs/four_classes_examples.png',
        role='四类对照图：每行左侧 HaGRID 官方示意图 + 右侧真实数据样例',
        source='本项目自绘（素材来自 HaGRID）',
        license='CC BY-SA 4.0（HaGRID 系）',
        measured=dict(),
    ),
    dict(
        path='demo/samples/hagrid_gestures.png',
        role='HaGRID 官方手势对照图（原生分辨率、带标签）：类定义参考 + 分类器探针集',
        source='https://github.com/hukenovs/hagrid/blob/master/images/gestures.png',
        license='CC BY-SA 4.0（HaGRID 系）',
        measured=dict(note='probe_classifier.py 按白边自动切出 33 块，标签与 HaGRID 类名对齐'),
    ),
    # ---------------------------------------------------------------- 工具
    dict(
        path='tools/extract_four_classes.py',
        role='★ 从 HaGRID parquet 分片抽取四类图片（生成/增补 dataset/，支持 --only）',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(),
    ),
    dict(
        path='tools/browse_class.py',
        role='★ 随机幻灯片式浏览某个类的图片（看数据集质量用，默认 10 张/秒）',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(),
    ),
    dict(
        path='tools/count_tflite.py',
        role='工具：TFLite 逐层 MAC/参数/算子统计（清点开源模型用）',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(),
    ),
    dict(
        path='tools/count_onnx.py',
        role='工具：ONNX 逐层 MAC/参数/算子统计（含 shape inference）',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(),
    ),
    dict(
        path='tools/make_manifest.py',
        role='工具：刷新本 manifest 的哈希与大小',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(),
    ),
    # ---------------------------------------------------------------- 当前训练产物
    dict(
        path='models/g4net_v1_trained',
        role='历史：v1 四分类权重，步 36,500 的 best_deploy 候选（与 best_macro_f1 同权重）',
        source='本项目自训：run baseline_ce_smallhand_20261015，40,000 步 / 2.25 小时，GPU1',
        license='—（本项目）',
        measured=dict(note='验证集 macro-F1 0.816 / 最差目标召回 0.806 / other 误报 0.068；'
                           '训练索引 sha256 cf951c1d39339c9e（含 four 并入与小手划出）；'
                           '同目录另存运行配置与评估报告'),
    ),
    # ---------------------------------------------------------------- 调研期参照资产（方案已不采用，留作对照/教师）
    dict(
        path='models/detector_blazepalm',
        role='参照：BlazePalm 掌心检测（本方案不采用）',
        source='https://storage.googleapis.com/mediapipe-assets/ + https://huggingface.co/opencv/palm_detection_mediapipe',
        license='Apache-2.0',
        measured=dict(note='lite 283.171 MMAC / full 337.333 MMAC（本仓实测）；含 2016 anchor、PRelu、5×5 DW'),
    ),
    dict(
        path='models/classifier_mobilenetv3_small',
        role='参照：MobileNetV3-small 手势分类权重（HaGRID 版 + timm/ImageNet 版；本方案不采用）',
        source='https://rndml-team-cv.obs.ru-moscow-1.hc.sbercloud.ru/datasets/hagrid_v2/models/MobileNetV3_small.pth + https://huggingface.co/onnx-community/mobilenetv3_small_100.lamb_in1k',
        license='HaGRID 版：CC BY-SA 4.0 变体；timm 版：timm 仓库 Apache-2.0',
        measured=dict(note='11.1 MMAC@96 / 55.5 MMAC@224（本仓实测）；含 HardSwish/SE/5×5 DW，需改造才能上板'),
    ),
    dict(
        path='models/teacher_hagrid/YOLOv10n_hands.pt',
        role='参照：手部检测教师（mAP 87.9，GFLOPs 级，不部署）',
        source='https://rndml-team-cv.obs.ru-moscow-1.hc.sbercloud.ru/datasets/hagrid_v2/models/YOLOv10n_hands.pt',
        license='HaGRID 材料按 CC BY-SA 4.0 变体；训练框架 YOLOv10 为 AGPL-3.0，勿并入提交物',
        measured=dict(note='Ultralytics 训练检查点（含优化器状态）'),
    ),
    dict(
        path='models/reference/hand_landmark_full.tflite',
        role='参照：MediaPipe 手部关键点模型（历史调研资产，当前四分类不使用关键点输出）',
        source='https://storage.googleapis.com/mediapipe-assets/hand_landmark_full.tflite',
        license='Apache-2.0 (MediaPipe)',
        measured=dict(note='331.0 MMAC@224（本仓实测）'),
    ),
    dict(
        path='demo/run_demo.py',
        role='参照：PC 端端到端 demo（BlazePalm ONNX 检测 + HaGRID 分类器；服务的是早期方案）',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(note='实测单帧：检测 10.3 ms + 分类 18~21 ms（每只手）'),
    ),
    dict(
        path='demo/probe_classifier.py',
        role='参照：分类器可用性自检（用带标签对照图算 top-1 与平均置信度）',
        source='本项目自写',
        license='—（本项目）',
        measured=dict(note='33 块探针：HaGRID ResNet18 14/33、76%；MobileNetV3-small 6/33、35%'),
    ),
    dict(
        path='demo/config/mp_palmdet.py',
        role='参照：OpenCV Zoo 的 BlazePalm 解码实现（内联 2016 个 anchor），run_demo.py 复用',
        source='https://huggingface.co/opencv/palm_detection_mediapipe',
        license='Apache-2.0 (OpenCV Zoo)',
        measured=dict(),
    ),
    dict(
        path='demo/config/hagrid_constants.py',
        role='参照：HaGRID 类名表（0..33），分类器输出索引的权威映射',
        source='https://raw.githubusercontent.com/hukenovs/hagrid/master/constants.py',
        license='CC BY-SA 4.0 变体（HaGRID 系）',
        measured=dict(note='14=fist，20=palm，33=no_gesture'),
    ),
    dict(
        path='demo/third_party/hagrid_src',
        role='参照：HaGRID 官方源码快照（查证模型构建与预处理契约；已删去其 images 目录）',
        source='https://github.com/hukenovs/hagrid',
        license='CC BY-SA 4.0 变体（HaGRID 系）',
        measured=dict(note='models/__init__.py 用 torchvision.models.mobilenet_v3_small；'
                           'dataset.py 用 PIL RGB、不做 bbox 裁剪'),
    ),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def dir_digest(path):
    """目录：按相对路径+大小排序后求摘要（大目录用，不逐文件存哈希）。"""
    entries = []
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for fn in sorted(files):
            full = os.path.join(root, fn)
            entries.append((os.path.relpath(full, path).replace('\\', '/'), os.path.getsize(full)))
    h = hashlib.sha256()
    for rel, size in entries:
        h.update(f'{rel}\t{size}\n'.encode())
    return h.hexdigest(), len(entries), sum(s for _, s in entries)


def main():
    out = []
    for e in ENTRIES:
        full = os.path.join(ROOT, e['path'])
        if not os.path.exists(full):
            raise SystemExit(f'缺文件: {e["path"]}')
        rec = dict(e)
        if os.path.isdir(full):
            digest, count, total = dir_digest(full)
            rec['bytes'] = total
            rec['file_count'] = count
            rec['sha256_manifest'] = digest
        else:
            rec['bytes'] = os.path.getsize(full)
            rec['sha256'] = sha256(full)
        out.append(rec)
    dest = os.path.join(ROOT, 'manifest.json')
    with open(dest, 'w', encoding='utf-8') as f:
        json.dump(dict(version=2, artifacts=out), f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'写入 {dest}：{len(out)} 项')


if __name__ == '__main__':
    main()
