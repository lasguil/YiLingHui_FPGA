"""手势检测 + 分类端到端 demo（PC 端 CPU 即可运行）。

检测：OpenCV Zoo 导出的 BlazePalm ONNX（onnxruntime）
分类：HaGRIDv2 官方 MobileNetV3_small 权重（torchvision 结构，34 类）

用法：
    python run_demo.py 图片 [图片2 ...] [--out 输出图] [--score 0.5] [--top 5]

输入分辨率默认按项目预算同时给出 224 与 96 两种分类结果，用于判断
“分类器降到 96x96 会不会掉类别”这个部署问题。
"""
import argparse
import os
import sys

import numpy as np
import onnxruntime as ort
import torch
import torchvision
from PIL import Image, ImageDraw
from torchvision import transforms

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DETECTOR_ONNX = os.path.join(
    ROOT, 'models/detector_blazepalm/opencv_onnx/palm_detection_mediapipe_2023feb.onnx')
CLASSIFIER_PTH = os.path.join(
    ROOT, 'models/classifier_mobilenetv3_small/hagrid/MobileNetV3_small.pth')
LABELS_PY = os.path.join(HERE, 'config/hagrid_constants.py')

INPUT_SIZE = 192  # 检测器输入（letterbox，保持长宽比）
NMS_IOU = 0.3


# ---------------------------------------------------------------- 类别表
def load_labels():
    ns = {}
    with open(LABELS_PY, encoding='utf-8') as f:
        exec(f.read(), ns)
    targets = ns['targets']
    return [targets[i] for i in sorted(targets)]


# ---------------------------------------------------------------- 检测器
def letterbox(img_rgb):
    """按 OpenCV Zoo 实现：保持长宽比缩放到 192x192，居中补零。返回 (blob, pad_bias, ratio)。"""
    h, w = img_rgb.shape[:2]
    ratio = min(INPUT_SIZE / h, INPUT_SIZE / w)
    new_h, new_w = int(h * ratio), int(w * ratio)
    resized = np.array(Image.fromarray(img_rgb).resize((new_w, new_h), Image.BILINEAR))
    pad_h, pad_w = INPUT_SIZE - new_h, INPUT_SIZE - new_w
    top, left = pad_h // 2, pad_w // 2
    canvas = np.zeros((INPUT_SIZE, INPUT_SIZE, 3), dtype=np.uint8)
    canvas[top:top + new_h, left:left + new_w] = resized
    blob = (canvas.astype(np.float32) / 255.0)[np.newaxis]
    pad_bias = np.array([left, top], dtype=np.float32) / ratio
    return blob, pad_bias, ratio


def nms(boxes, scores, iou_thres):
    order = scores.argsort()[::-1]
    keep = []
    while order.size:
        i = order[0]
        keep.append(i)
        if order.size == 1:
            break
        xx1 = np.maximum(boxes[i, 0], boxes[order[1:], 0])
        yy1 = np.maximum(boxes[i, 1], boxes[order[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[order[1:], 2])
        yy2 = np.minimum(boxes[i, 3], boxes[order[1:], 3])
        inter = np.maximum(0, xx2 - xx1) * np.maximum(0, yy2 - yy1)
        area_i = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        area_o = (boxes[order[1:], 2] - boxes[order[1:], 0]) * (boxes[order[1:], 3] - boxes[order[1:], 1])
        iou = inter / (area_i + area_o - inter + 1e-9)
        order = order[1:][iou <= iou_thres]
    return np.array(keep, dtype=np.int64)


class PalmDetector:
    def __init__(self, score_thresh=0.5):
        self.sess = ort.InferenceSession(DETECTOR_ONNX, providers=['CPUExecutionProvider'])
        self.in_name = self.sess.get_inputs()[0].name
        self.provider = self.sess.get_providers()[0]
        shapes = {o.name: o.shape for o in self.sess.get_outputs()}
        self.box_out = [n for n, s in shapes.items() if len(s) == 3 and s[2] == 18][0]
        self.score_out = [n for n, s in shapes.items() if len(s) == 3 and s[2] == 1][0]
        self.score_thresh = score_thresh
        self.anchors = self._anchors()

    @staticmethod
    def _anchors():
        """从 OpenCV 实现中直接读取 2016 个 anchor（避免自己重推 SSD 锚点生成逻辑）。"""
        ns = {'np': np}
        src = open(os.path.join(HERE, 'config/mp_palmdet.py'), encoding='utf-8').read()
        start = src.index('def _load_anchors')
        end = src.index('dtype=np.float32)', start) + len('dtype=np.float32)')
        body = src[start:end].replace('def _load_anchors(self):', 'def f():')
        exec(body, ns)
        return ns['f']()

    def __call__(self, img_rgb):
        blob, pad_bias, _ = letterbox(img_rgb)
        boxes_raw, score_raw = self.sess.run([self.box_out, self.score_out], {self.in_name: blob})
        scores = 1 / (1 + np.exp(-score_raw[0, :, 0].astype(np.float64)))
        deltas = boxes_raw[0]
        h, w = img_rgb.shape[:2]
        scale = float(max(h, w))
        cxy = deltas[:, :2] / INPUT_SIZE
        wh = deltas[:, 2:4] / INPUT_SIZE
        xy1 = (cxy - wh / 2 + self.anchors) * scale
        xy2 = (cxy + wh / 2 + self.anchors) * scale
        boxes = np.concatenate([xy1, xy2], axis=1)
        boxes -= np.array([pad_bias[0], pad_bias[1], pad_bias[0], pad_bias[1]])
        landmarks = (deltas[:, 4:].reshape(-1, 7, 2) / INPUT_SIZE + self.anchors[:, None, :]) * scale
        landmarks -= pad_bias
        keep_scores = scores >= self.score_thresh
        boxes, scores, landmarks = boxes[keep_scores], scores[keep_scores], landmarks[keep_scores]
        if boxes.size == 0:
            return np.empty((0, 4)), np.empty(0), np.empty((0, 7, 2))
        keep = nms(boxes, scores, NMS_IOU)
        return boxes[keep], scores[keep], landmarks[keep]


# ---------------------------------------------------------------- 分类器
CKPTS = {
    # name -> (权重文件, 构建函数, 分类头替换)
    'hagrid_mnv3s': (os.path.join(ROOT, 'models/classifier_mobilenetv3_small/hagrid/MobileNetV3_small.pth'), 'mnv3s'),
    'hagrid_resnet18': (os.path.join(ROOT, 'models/reference/hagrid_ResNet18.pth'), 'resnet18'),
}


class GestureClassifier:
    """HaGRIDv2 手势分类器（MobileNetV3-small 或 ResNet18）。

    预处理严格按官方 configs/*.yaml（两个模型配置相同）：
      LongestMaxSize(224) + PadIfNeeded(224x224, value=144) + Normalize(mean/std=数据集统计)
    注意：不是 ImageNet 的 mean/std，也不是直接 resize 成正方形。
    """

    MEAN = np.array([0.54, 0.499, 0.474], dtype=np.float32)
    STD = np.array([0.234, 0.235, 0.231], dtype=np.float32)
    PAD_VALUE = 144

    def __init__(self, name='hagrid_mnv3s', device='cpu'):
        path, kind = CKPTS[name]
        ckpt = torch.load(path, map_location='cpu', weights_only=False)
        state = ckpt['MODEL_STATE'] if isinstance(ckpt, dict) and 'MODEL_STATE' in ckpt else ckpt
        num_classes = 34  # HaGRIDv2: 33 手势 + no_gesture
        if kind == 'mnv3s':
            self.model = torchvision.models.mobilenet_v3_small(weights=None)
            self.model.classifier[3] = torch.nn.Linear(1024, num_classes)
        else:
            self.model = torchvision.models.resnet18(weights=None)
            self.model.fc = torch.nn.Linear(512, num_classes)
        missing, unexpected = self.model.load_state_dict(state, strict=False)
        assert not missing and not unexpected, f'权重不匹配 missing={missing[:3]} unexpected={unexpected[:3]}'
        self.device = torch.device(device)
        self.model.to(self.device).eval()
        self.name = name
        self.labels = load_labels()

    def _preprocess(self, crop_rgb, size):
        h, w = crop_rgb.shape[:2]
        scale = size / max(h, w)
        nh, nw = max(1, int(round(h * scale))), max(1, int(round(w * scale)))
        resized = np.array(Image.fromarray(crop_rgb).resize((nw, nh), Image.BILINEAR))
        canvas = np.full((size, size, 3), self.PAD_VALUE, dtype=np.uint8)
        top, left = (size - nh) // 2, (size - nw) // 2
        canvas[top:top + nh, left:left + nw] = resized
        x = canvas.astype(np.float32) / 255.0
        x = (x - self.MEAN) / self.STD
        return torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0)

    @torch.no_grad()
    def __call__(self, crop_rgb, size=224):
        probs = self.model(self._preprocess(crop_rgb, size).to(self.device)).softmax(-1)[0]
        top = probs.topk(3)
        return [(self.labels[i], float(p)) for p, i in zip(top.values, top.indices)]


# ---------------------------------------------------------------- 主流程
def expand_box(box, img_w, img_h, factor=1.4):
    x1, y1, x2, y2 = box
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    half_w = max(x2 - x1, 1) * factor / 2
    half_h = max(y2 - y1, 1) * factor / 2
    return (max(0, int(cx - half_w)), max(0, int(cy - half_h)),
            min(img_w, int(cx + half_w)), min(img_h, int(cy + half_h)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('images', nargs='+')
    ap.add_argument('--out', default=None)
    ap.add_argument('--score', type=float, default=0.5)
    ap.add_argument('--top', type=int, default=5)
    ap.add_argument('--classifier', choices=sorted(CKPTS), default='hagrid_mnv3s')
    ap.add_argument('--device', choices=('auto', 'cpu', 'cuda'), default='auto',
                    help='分类器设备；auto=cuda 可用则用 cuda（按项目规则本地推理走 CUDA）')
    ap.add_argument('--roi', choices=('full', 'det'), default='full',
                    help='full=整帧送分类器（HaGRID 官方训练方式）；det=按检测框裁剪')
    args = ap.parse_args()

    detector = PalmDetector(args.score)
    device = args.device
    if device == 'auto':
        device = 'cuda' if torch.cuda.is_available() else 'cpu'
    classifier = GestureClassifier(args.classifier, device)
    print(f'检测器: {os.path.basename(DETECTOR_ONNX)} [{detector.provider}]'
          f' | 分类器: {args.classifier} (34 类) [{device}: '
          f'{torch.cuda.get_device_name(0) if device == "cuda" else "CPU"}]\n')

    for path in args.images:
        img = Image.open(path).convert('RGB')
        rgb = np.array(img)
        h, w = rgb.shape[:2]
        boxes, scores, _ = detector(rgb)
        order = np.argsort(-scores)[:args.top]
        print(f'== {os.path.basename(path)}  {w}x{h}  检出 {len(boxes)} 只手')

        draw = ImageDraw.Draw(img)
        for rank, idx in enumerate(order, 1):
            x1, y1, x2, y2 = boxes[idx]
            if args.roi == 'det':
                cx1, cy1, cx2, cy2 = expand_box(boxes[idx], w, h)
                crop = rgb[cy1:cy2, cx1:cx2]
            else:
                crop = rgb
            if crop.size == 0:
                continue
            top224 = classifier(crop, 224)
            top96 = classifier(crop, 96)
            draw.rectangle([x1, y1, x2, y2], outline=(0, 255, 0), width=2)
            tag = f'{top224[0][0]} {top224[0][1]*100:.0f}%'
            draw.text((x1 + 2, max(0, y1 - 12)), tag, fill=(0, 255, 0))
            fmt = lambda r: ', '.join(f'{n} {p*100:.1f}%' for n, p in r)
            print(f'  #{rank} 检测分 {scores[idx]:.3f} | 框 ({x1:.0f},{y1:.0f})-({x2:.0f},{y2:.0f})')
            print(f'     分类@224: {fmt(top224)}')
            print(f'     分类@96 : {fmt(top96)}')

        out = args.out or os.path.splitext(path)[0] + '_demo.png'
        img.save(out)
        print(f'  → 标注图: {out}\n')

    return 0


if __name__ == '__main__':
    sys.exit(main())
