"""Measure how much of each frame the hand occupies, with the in-repo detector.

Why the official HaGRID boxes are not used: our images are 512x512 crops of the
original 1920x1080 frames, so the normalised annotation coordinates do not
transfer. Rendering them puts the boxes on fingers, shoulders and background
rather than around the hand, and any area computed from them describes the
original frame. The detector runs on our own pixels and needs no transform.

Only the classes that could be demoted to `other` need a size; an image already
in `other` stays there whatever its hand size.

Run from the repository root:

  python gesture/tools/build_hand_size_table.py
  python gesture/tools/build_hand_size_table.py --groups 手掌/palm --limit 64
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))

IMAGE_EXTS = ('.jpeg', '.jpg', '.png', '.bmp', '.webp')
DEFAULT_GROUPS = ('手掌/palm', '手掌/stop', '其它/four',
                  '手背/stop_inverted', '握拳/fist')
DEFAULT_WEIGHTS = GESTURE / 'models/teacher_hagrid/YOLOv10n_hands.pt'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-root', type=Path,
                        default=GESTURE / 'dataset')
    parser.add_argument('--weights', type=Path, default=DEFAULT_WEIGHTS)
    parser.add_argument('--groups', nargs='*', default=list(DEFAULT_GROUPS))
    parser.add_argument('--out', type=Path,
                        default=GESTURE / 'reports' / 'hand_sizes.jsonl')
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--imgsz', type=int, default=640)
    parser.add_argument('--conf', type=float, default=0.25)
    parser.add_argument('--batch', type=int, default=32)
    parser.add_argument('--limit', type=int, default=0,
                        help='max images per group, 0 = all')
    args = parser.parse_args()

    if not args.device.startswith('cuda'):
        raise SystemExit('an explicit CUDA device is required, e.g. --device cuda:0')
    # Ultralytics writes its settings into the user profile by default; keep it
    # inside the repository's scratch directory instead.
    os.environ.setdefault('YOLO_CONFIG_DIR', str(GESTURE.parent / 'tmp' / 'yolo'))

    import torch
    from ultralytics import YOLO
    if not torch.cuda.is_available():
        raise SystemExit('CUDA unavailable; CPU fallback is forbidden.')
    device = torch.device(args.device)
    if device.index is None or device.index >= torch.cuda.device_count():
        raise SystemExit(f'bad device index: {args.device}')
    print(f'torch {torch.__version__}  device {device}  '
          f'{torch.cuda.get_device_name(device)}')
    print(f'weights {args.weights}')

    tasks = []
    for group in args.groups:
        directory = args.data_root / group
        if not directory.is_dir():
            raise SystemExit(f'missing group: {directory}')
        files = sorted(p for p in directory.iterdir()
                       if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
        if args.limit:
            files = files[:args.limit]
        tasks.extend((group, path) for path in files)
        print(f'  {group:<22s} {len(files):>7,d}')
    print(f'total {len(tasks):,d} images\n')

    model = YOLO(str(args.weights))
    started = time.time()
    rows = []
    for start in range(0, len(tasks), args.batch):
        chunk = tasks[start:start + args.batch]
        results = model.predict([str(path) for _, path in chunk],
                                device=device.index, imgsz=args.imgsz,
                                conf=args.conf, verbose=False, save=False)
        for (group, path), result in zip(chunk, results):
            height, width = result.orig_shape[:2]
            boxes = result.boxes
            areas, confidences = [], []
            for box, score in zip(boxes.xyxy, boxes.conf):
                x1, y1, x2, y2 = (float(v) for v in box)
                areas.append((x2 - x1) * (y2 - y1) / (width * height))
                confidences.append(float(score))
            rows.append(dict(
                path=path.relative_to(args.data_root).as_posix(),
                group=group,
                width=width,
                height=height,
                n_boxes=len(areas),
                area_max=round(max(areas), 6) if areas else None,
                area_min=round(min(areas), 6) if areas else None,
                conf_max=round(max(confidences), 4) if confidences else None,
            ))
        done = min(start + args.batch, len(tasks))
        if done % (args.batch * 20) == 0 or done == len(tasks):
            elapsed = time.time() - started
            print(f'  {done:,d}/{len(tasks):,d}  {elapsed:.0f}s  '
                  f'{done / max(elapsed, 1e-9):.0f} img/s', flush=True)

    rows.sort(key=lambda row: row['path'])
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open('w', encoding='utf-8') as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + '\n')
    print(f'\nwrote {len(rows):,d} rows to {args.out}')

    missing = sum(1 for row in rows if row['area_max'] is None)
    print(f'detector found no hand in {missing:,d} rows ({missing / len(rows):.2%})')
    areas = sorted(row['area_max'] for row in rows if row['area_max'] is not None)
    print(f'\nhand area as a fraction of our 512x512 frame '
          f'(largest hand per image, n={len(areas):,d}):')
    for quantile in (0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.99):
        print(f'  p{quantile * 100:>4.0f}  {areas[min(len(areas) - 1, int(quantile * len(areas)))]:.4f}')
    print()
    for threshold in (0.01, 0.02, 0.03, 0.05, 0.08):
        below = sum(1 for a in areas if a < threshold)
        print(f'  below {threshold:.2f}: {below:>7,d}  ({below / len(areas):5.2%})')
    print()
    print('by group, share below 0.03:')
    for group in args.groups:
        subset = [row['area_max'] for row in rows
                  if row['group'] == group and row['area_max'] is not None]
        if not subset:
            continue
        below = sum(1 for a in subset if a < 0.03)
        print(f'  {group:<22s} n={len(subset):>6,d}  '
              f'median={sorted(subset)[len(subset) // 2]:.4f}  '
              f'below 0.03: {below:>6,d} ({below / len(subset):5.1%})')


if __name__ == '__main__':
    main()
