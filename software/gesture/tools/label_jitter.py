"""How repeatable are the teacher's centres? The floor our student inherits.

Runs the teacher twice on the same crop, once as stored and once shifted by a
pixel (and once mirrored), and reports how far the chosen box centre moves. A
student trained on these labels cannot be more stable than they are: if the
teacher's own centre wanders by tens of pixels when the input moves by one, then
a centre error of that size is the label noise floor rather than a training
shortfall.

Runs under the teacher environment (needs ultralytics), not the project one:
  G=/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015
  export CUDA_VISIBLE_DEVICES=1 YOLO_CONFIG_DIR=$G/tmp/ultralytics_config
  $G/envs/teacher/bin/python ml/tools/label_jitter.py --sample 200
"""
import argparse
import json
import random
import sys
from pathlib import Path

import numpy as np

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--crops', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144')
    parser.add_argument('--labels', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'labels_teacher.jsonl')
    parser.add_argument('--weights', type=Path,
                        default=PROJECT / 'models' / 'teacher_hagrid' / 'YOLOv10n_hands.pt')
    parser.add_argument('--sample', type=int, default=200)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--out', type=Path,
                        default=PROJECT / 'tmp' / 'label_jitter.json')
    args = parser.parse_args()

    import torch
    from PIL import Image
    from ultralytics import YOLO

    if not torch.cuda.is_available():
        raise SystemExit('CUDA required')
    model = YOLO(str(args.weights))
    head = model.model.model[-1]
    if getattr(head, 'one2one_cv2', None) is None:
        raise SystemExit('the teacher has no one-to-one head; fusion must not run')

    rows = [json.loads(line) for line in open(args.labels, encoding='utf-8')]
    rows = [row for row in rows if row['presence']]
    rng = random.Random(20261016)
    rows = rng.sample(rows, min(args.sample, len(rows)))

    def centre_of(image):
        result = next(iter(model.predict(image, imgsz=640, conf=0.25,
                                         device=args.device, nms=False, verbose=False)))
        boxes = result.boxes
        if boxes is None or not len(boxes):
            return None
        best, key = None, None
        for box in boxes:
            x1, y1, x2, y2 = (float(v) for v in box.xyxy[0].tolist())
            score = float(box.conf[0])
            k = ((x2 - x1) * (y2 - y1), score)
            if key is None or k > key:
                best, key = ((x1 + x2) / 2, (y1 + y2) / 2), k
        return best

    spreads, lost = [], 0
    for row in rows:
        with Image.open(args.crops / row['path']) as handle:
            base = handle.convert('RGB')
        array = np.asarray(base)
        variants = {'stored': array,
                    'shift_x': np.roll(array, 1, axis=1),
                    'shift_y': np.roll(array, 1, axis=0),
                    'mirror': array[:, ::-1]}
        centres = {}
        for name, pixels in variants.items():
            found = centre_of(Image.fromarray(pixels))
            if found is None:
                continue
            centres[name] = found
        if 'stored' not in centres or len(centres) < 3:
            lost += 1
            continue
        base_centre = np.array(centres['stored'])
        dx = [(centres[k][0] - base_centre[0]) for k in ('shift_x', 'shift_y') if k in centres]
        dy = [(centres[k][1] - base_centre[1]) for k in ('shift_x', 'shift_y') if k in centres]
        spreads.append((abs(np.mean(dx)), abs(np.mean(dy)),
                        len(centres)))
    spreads = np.array([(s[0], s[1]) for s in spreads]) if spreads else np.zeros((0, 2))
    report = dict(weights=str(args.weights), sample=len(rows), usable=len(spreads),
                  lost_or_unstable=lost,
                  shift_centre_dx_px=dict(median=float(np.median(spreads[:, 0])),
                                          p90=float(np.percentile(spreads[:, 0], 90))),
                  shift_centre_dy_px=dict(median=float(np.median(spreads[:, 1])),
                                          p90=float(np.percentile(spreads[:, 1], 90))),
                  note=('A 1-px shift of the input moves the teacher centre by this much; '
                        'a student of these labels cannot be steadier than that.'))
    print(f"teacher centre movement under a 1-px shift, {len(spreads)} crops "
          f"({lost} unstable): x median {report['shift_centre_dx_px']['median']:.2f} px "
          f"p90 {report['shift_centre_dx_px']['p90']:.2f}; "
          f"y median {report['shift_centre_dy_px']['median']:.2f} px "
          f"p90 {report['shift_centre_dy_px']['p90']:.2f} (canvas 256x144)")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n',
                        encoding='utf-8')
    print(f'report -> {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
