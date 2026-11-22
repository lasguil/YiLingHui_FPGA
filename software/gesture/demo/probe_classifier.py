"""用 HaGRID 官方手势对照图做分类器权重的可用性自检（诊断脚本，不参与部署）。

- 参考图 samples/hagrid_gestures.png 是原生分辨率、带标签的 33 手势对照图。
- 坐标不再手工估：先按"整行接近纯白"自动切出行带，再在每个行带内按"整列接近纯白"切出图块，
  最后与图中已知的手势标签顺序对齐。
- 预处理严格按官方 configs/MobileNetV3_small.yaml：
  LongestMaxSize(224) + PadIfNeeded(224, value=144) + Normalize(mean=[0.54,0.499,0.474],
  std=[0.234,0.235,0.231])，RGB（官方 dataset.py 用 Image.open(...).convert("RGB")）。

用法：
    python probe_classifier.py --model mobilenetv3_small
    python probe_classifier.py --model resnet18
"""
import argparse
import os

import numpy as np
import torch
import torchvision
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GRID = os.path.join(HERE, 'samples/hagrid_gestures.png')
CKPT = {
    'mobilenetv3_small': os.path.join(ROOT, 'models/classifier_mobilenetv3_small/hagrid/MobileNetV3_small.pth'),
    'resnet18': os.path.join(ROOT, 'models/reference/hagrid_ResNet18.pth'),
}
# 参考图从上到下的手势顺序（人工目视核对，名称已对齐 HaGRID 的 34 类类名：
# 图上的俗称 gun/pinkie/mid_finger/take_photo/heart/heart2 分别对应
# three_gun/little_finger/middle_finger/take_picture/hand_heart/hand_heart2）
ROW_NAMES = [
    'call dislike fist four like mute grabbing grip'.split(),
    'ok one palm peace peace_inverted rock point little_finger'.split(),
    'stop stop_inverted three three2 two_up two_up_inverted middle_finger three3'.split(),
    'three_gun thumb_index thumb_index2 holy timeout take_picture xsign hand_heart hand_heart2'.split(),
]
MEAN = np.array([0.54, 0.499, 0.474], dtype=np.float32)
STD = np.array([0.234, 0.235, 0.231], dtype=np.float32)


def white_runs(mask, thr=0.98, min_len=3):
    out, start = [], None
    for i, v in enumerate(mask > thr):
        if v and start is None:
            start = i
        elif not v and start is not None:
            if i - 1 - start >= min_len:
                out.append((start, i - 1))
            start = None
    if start is not None and len(mask) - 1 - start >= min_len:
        out.append((start, len(mask) - 1))
    return out


def segment_tiles(img):
    """返回 [(name, (x1,y1,x2,y2)), ...]：先切行带，再在行带内切列。"""
    gray = img.mean(2)
    rows = white_runs((gray > 250).mean(1))
    # 行带 = 两条白带之间的内容区
    bands = []
    prev_end = 0
    for s, e in rows:
        if s - prev_end > 60:          # 内容区足够高才是图块行
            bands.append((prev_end, s - 1))
        prev_end = e + 1
    if len(img) - 1 - prev_end > 60:
        bands.append((prev_end, len(img) - 1))

    tiles = []
    for band, names in zip(bands, ROW_NAMES):
        y1, y2 = band
        sub = gray[y1:y2 + 1]
        cols = white_runs((sub > 250).mean(0))
        xspans, prev = [], 0
        for s, e in cols:
            if s - prev > 40:
                xspans.append((prev, s - 1))
            prev = e + 1
        if sub.shape[1] - 1 - prev > 40:
            xspans.append((prev, sub.shape[1] - 1))
        for (x1, x2), name in zip(xspans, names):
            tiles.append((name, (x1, y1, x2, y2)))
    return tiles


def letterbox(crop, size=224, pad=144):
    h, w = crop.shape[:2]
    scale = size / max(h, w)
    nh, nw = max(1, int(round(h * scale))), max(1, int(round(w * scale)))
    resized = np.array(Image.fromarray(crop).resize((nw, nh), Image.BILINEAR))
    canvas = np.full((size, size, 3), pad, dtype=np.uint8)
    top, left = (size - nh) // 2, (size - nw) // 2
    canvas[top:top + nh, left:left + nw] = resized
    x = canvas.astype(np.float32) / 255.0
    x = (x - MEAN) / STD
    return torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0)


def load_labels():
    src = open(os.path.join(HERE, 'config/hagrid_constants.py'), encoding='utf-8').read()
    body = src.split('targets = {')[1].split('}')[0]
    lab = {}
    for item in body.replace('\n', ' ').split(','):
        if ':' in item:
            k, v = item.split(':', 1)
            lab[int(k.strip())] = v.strip().strip('"')
    return [lab[i] for i in sorted(lab)]


def build(name):
    ck = torch.load(CKPT[name], map_location='cpu', weights_only=False)
    state = ck['MODEL_STATE'] if isinstance(ck, dict) and 'MODEL_STATE' in ck else ck
    if name == 'mobilenetv3_small':
        model = torchvision.models.mobilenet_v3_small(weights=None)
        model.classifier[3] = torch.nn.Linear(1024, 34)
    else:
        model = torchvision.models.resnet18(weights=None)
        model.fc = torch.nn.Linear(512, 34)
    missing, unexpected = model.load_state_dict(state, strict=False)
    model.eval()
    return model, missing, unexpected


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=sorted(CKPT), default='mobilenetv3_small')
    ap.add_argument('--sheet', default=None, help='把切出的图块存成对照图用于目视核对')
    args = ap.parse_args()

    img = np.array(Image.open(GRID).convert('RGB'))
    tiles = segment_tiles(img)
    print(f'自动切出 {len(tiles)} 块参考图')

    labels = load_labels()
    assert labels[14] == 'fist' and labels[20] == 'palm' and labels[33] == 'no_gesture', labels[:16]
    model, missing, unexpected = build(args.model)
    print(f'模型 {args.model} | missing={len(missing)} unexpected={len(unexpected)} '
          f'| 参数 {sum(p.numel() for p in model.parameters()):,}')

    hit = 0
    conf = []
    rows = []
    with torch.no_grad():
        for name, (x1, y1, x2, y2) in tiles:
            crop = img[y1:y2 + 1, x1:x2 + 1]
            probs = model(letterbox(crop)).softmax(-1)[0]
            top = probs.topk(3)
            pred = labels[top.indices[0]]
            hit += (pred == name)
            conf.append(float(top.values[0]))
            rows.append((name, pred, [(labels[i], float(v)) for v, i in zip(top.values, top.indices)], crop))

    for name, pred, top3, _ in rows:
        mark = 'OK ' if pred == name else 'X  '
        print(f'  {mark} 真值 {name:15s} -> ' + ', '.join(f'{n} {v*100:.0f}%' for n, v in top3))
    print(f'\n  top-1 命中 {hit}/{len(rows)} = {hit/len(rows)*100:.1f}% | 平均置信度 {np.mean(conf)*100:.1f}%')

    if args.sheet:
        cols = 8
        rows_n = (len(rows) + cols - 1) // cols
        sheet = Image.new('RGB', (cols * 168, rows_n * 190), (0, 0, 0))
        d = ImageDraw.Draw(sheet)
        for i, (name, pred, top3, crop) in enumerate(rows):
            r, c = divmod(i, cols)
            tile = Image.fromarray(crop).resize((160, 160), Image.BILINEAR)
            sheet.paste(tile, (c * 168, r * 190 + 26))
            color = (0, 255, 0) if pred == name else (255, 60, 60)
            d.text((c * 168 + 2, r * 190 + 4), f'GT {name}', fill=(255, 255, 0))
            d.text((c * 168 + 2, r * 190 + 14), f'{pred}', fill=color)
        sheet.save(args.sheet)
        print(f'  对照图: {args.sheet}')


if __name__ == '__main__':
    main()
