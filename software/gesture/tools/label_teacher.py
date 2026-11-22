"""Label the 16:9 crops with the hand detector, for the v5 position head.

The teacher is `models/teacher_hagrid/YOLOv10n_hands.pt`, run through its
one-to-one head (`nms=False`), which returns one box per hand instead of the
nested duplicates the classic NMS path produces on a single hand. The label is
the centre of the **largest-area box**, so the rule is fixed rather than chosen
per image; ties break on confidence.

Two decisions worth stating because they change what the numbers mean:

  * The teacher runs on the *stored* 256x144 crop, not on the 512x288 window
    before downscaling. The label then describes exactly the bytes training will
    read, which is the same "labels on our own pixels" rule the hand-size table
    used.
  * A crop with no detection is recorded as `presence: false` rather than
    dropped. Cutting the hand out of the frame is the point of the crop, and a
    frame with no hand is a legitimate training sample for a heatmap.

`--sample-squares N` additionally runs the teacher on the square source of N
random rows, which is how the "the crop cut the hand" rate gets measured.

Output is JSONL, one row per index row. The test split is skipped by default:
its pixels are not needed to train, and keeping them out of every statistic
keeps the split unspent.

Run on the training server:
  G=/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015
  export CUDA_VISIBLE_DEVICES=1
  export YOLO_CONFIG_DIR=$G/tmp/ultralytics_config   # else it writes /tmp
  nohup nice -n 19 $G/envs/teacher/bin/python tmp/label_teacher.py --batch 16 \
      --out $G/datasets_16x9_256x144/labels_teacher.jsonl \
      > $G/logs/label_teacher.log 2>&1 &
"""
import argparse
import hashlib
import json
import os
import random
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')
DEFAULT_CROPS = PROJECT / 'datasets_16x9_256x144'
DEFAULT_SOURCES = PROJECT / 'datasets'
DEFAULT_INDEX = PROJECT / 'datasets' / 'index.jsonl'
DEFAULT_WEIGHTS = PROJECT / 'models' / 'teacher_hagrid' / 'YOLOv10n_hands.pt'
CROP_WIDTH, CROP_HEIGHT = 256, 144


def gpu_report():
    """Which physical GPU this process is on, resolved through the UUID.

    `CUDA_VISIBLE_DEVICES` renumbers the devices, so the only trustworthy answer
    is the UUID the driver reports for this pid.
    """
    query = subprocess.run(['nvidia-smi', '--query-gpu=index,uuid,name',
                            '--format=csv,noheader'], capture_output=True, text=True)
    by_uuid = {}
    for line in query.stdout.strip().splitlines():
        index, uuid, name = [part.strip() for part in line.split(',', 2)]
        by_uuid[uuid] = dict(index=index, name=name)
    apps = subprocess.run(['nvidia-smi', '--query-compute-apps=gpu_uuid,pid,used_memory',
                           '--format=csv,noheader'], capture_output=True, text=True)
    mine, others = [], []
    for line in apps.stdout.strip().splitlines():
        uuid, pid, memory = [part.strip() for part in line.split(',', 2)]
        entry = dict(physical_index=by_uuid.get(uuid, {}).get('index', '?'),
                     gpu=by_uuid.get(uuid, {}).get('name', '?'), pid=pid,
                     used_memory=memory)
        (mine if pid == str(os.getpid()) else others).append(entry)
    return dict(cuda_visible_devices=os.environ.get('CUDA_VISIBLE_DEVICES'),
                pid=os.getpid(), this_process=mine, other_compute_apps=others)


def require_one_to_one_head(model):
    """Fail loudly unless the checkpoint still carries its one-to-one head.

    `model.fuse()` rewrites v10Detect and drops that head: with it gone,
    `nms=False` silently falls back to the one-to-many branch (measured locally:
    one palm goes from a single box at 0.82 to three nested boxes at
    0.53/0.52/0.39), which is a different teacher for the same weights. Nothing
    here may depend on fusion, and this check is what makes that a hard error
    instead of a quiet change of meaning.
    """
    head = model.model.model[-1] if hasattr(model.model, 'model') else None
    has_one_to_one = getattr(head, 'one2one_cv2', None) is not None
    info = dict(head_type=type(head).__name__ if head is not None else None,
                has_one_to_one_head=has_one_to_one,
                one_to_many_present=getattr(head, 'cv2', None) is not None,
                notes='no fuse() is applied: fusion would remove the head')
    if not has_one_to_one:
        raise SystemExit(f'the teacher has no one-to-one head, so `nms=False` would '
                         f'mean one-to-many: {info}')
    return info


def choose_box(boxes):
    """Largest-area box; ties break on the higher score. None when there is none."""
    best, best_key = None, None
    for box in boxes:
        x1, y1, x2, y2 = (float(v) for v in box.xyxy[0].tolist())
        score = float(box.conf[0])
        key = ((x2 - x1) * (y2 - y1), score)
        if best_key is None or key > best_key:
            best, best_key = (x1, y1, x2, y2, score), key
    return best


def label_from_result(result, width, height):
    """Label fields for one prediction result."""
    boxes = result.boxes
    row = dict(presence=False, cx=None, cy=None, box=None, conf=None,
               n_boxes=0 if boxes is None else int(len(boxes)))
    chosen = choose_box(boxes) if boxes is not None and len(boxes) else None
    if chosen is not None:
        x1, y1, x2, y2, score = chosen
        row.update(presence=True,
                   cx=round((x1 + x2) / 2 / width, 6),
                   cy=round((y1 + y2) / 2 / height, 6),
                   box=[round(x1, 2), round(y1, 2), round(x2, 2), round(y2, 2)],
                   conf=round(score, 4))
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--index', type=Path, default=DEFAULT_INDEX)
    parser.add_argument('--crops', type=Path, default=DEFAULT_CROPS)
    parser.add_argument('--sources', type=Path, default=DEFAULT_SOURCES)
    parser.add_argument('--weights', type=Path, default=DEFAULT_WEIGHTS)
    parser.add_argument('--out', type=Path, default=DEFAULT_CROPS / 'labels_teacher.jsonl')
    parser.add_argument('--report', type=Path, default=None)
    parser.add_argument('--size', default='256,144',
                        help='the frame the labels are expressed in, WxH; pass '
                             '512,512 when labelling the source mirrors')
    parser.add_argument('--splits', default='train,val',
                        help='comma-separated splits to label; test stays unspent')
    parser.add_argument('--conf', type=float, default=0.25)
    parser.add_argument('--batch', type=int, default=16)
    parser.add_argument('--device', default='cuda:0',
                        help='device as seen under CUDA_VISIBLE_DEVICES')
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--chunk', type=int, default=1000,
                        help='paths per predict() call; the streaming source is '
                             'not safe with a 160k-item list (measured: unbounded '
                             'RSS growth), so the caller does the chunking')
    parser.add_argument('--max-rss-gb', type=float, default=24.0,
                        help='abort if resident memory exceeds this; this is a '
                             'shared machine')
    parser.add_argument('--sample-squares', type=int, default=0,
                        help='also label N random square sources, to measure how '
                             'often the crop cuts the hand out of the frame')
    args = parser.parse_args()

    import numpy as np
    import torch
    from PIL import Image
    from ultralytics import YOLO

    label_width, label_height = (int(v) for v in args.size.split(','))

    if not torch.cuda.is_available():
        raise SystemExit('torch reports no CUDA; this labelling has no CPU path')
    if not args.weights.is_file():
        raise SystemExit(f'missing teacher weights: {args.weights}')
    if not torch.cuda.device_count():
        raise SystemExit('no visible CUDA device')

    print(json.dumps(gpu_report(), ensure_ascii=False, indent=1), flush=True)
    print(f'torch {torch.__version__}  device {args.device}  '
          f'{torch.cuda.get_device_name(args.device)}', flush=True)

    model = YOLO(str(args.weights))
    head_info = require_one_to_one_head(model)
    print(f'teacher head: {json.dumps(head_info, ensure_ascii=False)}', flush=True)

    split_wanted = {s.strip() for s in args.splits.split(',') if s.strip()}
    rows = []
    with open(args.index, encoding='utf-8') as handle:
        for line in handle:
            row = json.loads(line)
            if row['split'] in split_wanted:
                rows.append(row)
    if args.limit:
        rows = rows[:args.limit]
    print(f'{len(rows):,d} rows to label (splits {sorted(split_wanted)}); '
          f'conf {args.conf}; one-to-one head; largest box wins', flush=True)

    paths = [str(args.crops / row['path']) for row in rows]
    by_path = {path: row for path, row in zip(paths, rows)}

    def resident_gb():
        with open('/proc/self/statm') as handle:
            pages = int(handle.read().split()[1])
        return pages * os.sysconf('SC_PAGE_SIZE') / 2 ** 30

    def predict(source, batch=1):
        return model.predict(source, imgsz=640, conf=args.conf, device=args.device,
                             nms=False, verbose=False, batch=batch, stream=True)

    # Warm up so the first measured images are not a clock-ramp artefact.
    for _ in predict(paths[:3]):
        pass

    counters, by_pool, by_class = Counter(), defaultdict(Counter), defaultdict(Counter)
    heights, widths, confidences = [], [], []
    started = time.time()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as handle:
        number = 0
        for start in range(0, len(paths), args.chunk):
            resident = resident_gb()
            if resident > args.max_rss_gb:
                raise SystemExit(f'resident memory {resident:.1f} GB exceeds '
                                 f'--max-rss-gb {args.max_rss_gb}; aborting rather '
                                 f'than growing on a shared machine')
            for result in predict(paths[start:start + args.chunk], args.batch):
                number += 1
                row = by_path[str(result.path)]
                label = label_from_result(result, label_width, label_height)
                handle.write(json.dumps(dict(path=row['path'], split=row['split'],
                                             class_id=row['class_id'],
                                             semantic_pool=row['semantic_pool'],
                                             **label), ensure_ascii=False) + '\n')
                key = 'presence' if label['presence'] else 'no_hand'
                counters[key] += 1
                by_pool[row['semantic_pool']][key] += 1
                by_class[row['class_id']][key] += 1
                if label['presence']:
                    x1, y1, x2, y2 = label['box']
                    heights.append(y2 - y1)
                    widths.append(x2 - x1)
                    confidences.append(label['conf'])
            handle.flush()
            rate = number / max(time.time() - started, 1e-6)
            print(f'  {number:,d}/{len(rows):,d}  {rate:,.0f} img/s  '
                  f'presence {counters["presence"]:,d} '
                  f'({counters["presence"] / max(number, 1):.1%})  '
                  f'rss {resident:.1f} GB', flush=True)

    elapsed = time.time() - started
    report = dict(
        tool='tools/label_teacher.py', weights=str(args.weights),
        weights_sha256=hashlib.sha256(args.weights.read_bytes()).hexdigest(),
        index=str(args.index), crops=str(args.crops), out=str(args.out),
        splits=sorted(split_wanted), conf=args.conf, head='one-to-one (nms=False)',
        head_info=head_info, box_rule='largest area, ties on confidence',
        labelled=sum(counters.values()), presence=counters['presence'],
        no_hand=counters['no_hand'],
        presence_rate=round(counters['presence'] / max(sum(counters.values()), 1), 6),
        by_pool={pool: dict(counts) for pool, counts in sorted(by_pool.items())},
        by_class={str(cls): dict(counts) for cls, counts in sorted(by_class.items())},
        seconds=round(elapsed, 1),
        seconds_per_image=round(elapsed / max(sum(counters.values()), 1), 4),
        gpu=gpu_report(), interpreter=sys.executable,
    )
    if heights:
        heights, widths = np.array(heights), np.array(widths)
        confidences = np.array(confidences)
        report['box_height_px'] = dict(
            min=float(heights.min()), p10=float(np.percentile(heights, 10)),
            median=float(np.median(heights)), p90=float(np.percentile(heights, 90)),
            max=float(heights.max()))
        report['box_width_px'] = dict(
            min=float(widths.min()), p10=float(np.percentile(widths, 10)),
            median=float(np.median(widths)), p90=float(np.percentile(widths, 90)),
            max=float(widths.max()))
        report['confidence'] = dict(
            p10=float(np.percentile(confidences, 10)),
            median=float(np.median(confidences)),
            p90=float(np.percentile(confidences, 90)))
        report['hand_height_over_frame_height'] = dict(
            p10=float(np.percentile(heights, 10) / label_height),
            median=float(np.median(heights) / label_height))

    if args.sample_squares:
        # Same rows, but on the square source. Per-row records are kept so the
        # "the crop cut the hand" cases can be looked at, not just counted.
        rng = random.Random(20261016)
        sample = rng.sample(rows, min(args.sample_squares, len(rows)))
        squares, square_heights, square_rows = Counter(), [], []
        square_out = args.out.with_name(args.out.stem + '_squares.jsonl')
        with open(square_out, 'w', encoding='utf-8') as square_handle:
            for row in sample:
                source = args.sources / row['path']
                record = dict(path=row['path'], split=row['split'],
                              class_id=row['class_id'],
                              semantic_pool=row['semantic_pool'])
                try:
                    with Image.open(source) as handle:
                        width, height = handle.size
                    result = next(iter(model.predict(str(source), imgsz=640, conf=args.conf,
                                                     device=args.device, nms=False,
                                                     verbose=False)))
                    label = label_from_result(result, width, height)
                    squares['presence' if label['presence'] else 'no_hand'] += 1
                    if label['presence']:
                        square_heights.append(label['box'][3] - label['box'][1])
                    record.update(source_wh=[width, height], **label)
                except Exception as error:            # noqa: BLE001 - counted, not hidden
                    squares['error'] += 1
                    record.update(status='error', error=f'{type(error).__name__}: {error}')
                    print(f'  square sample error on {row["path"]}: {error}', flush=True)
                square_rows.append(record)
                square_handle.write(json.dumps(record, ensure_ascii=False) + '\n')
                if len(square_rows) % 500 == 0:
                    print(f'  squares {len(square_rows):,d}/{len(sample):,d}', flush=True)
        report['square_sample'] = dict(n=len(sample), out=str(square_out), **dict(squares))
        if square_heights:
            report['square_sample']['box_height_px_median'] = float(
                np.median(square_heights))
        print(f'square sample: {dict(squares)} -> {square_out}', flush=True)

    report_path = args.report or args.out.with_suffix('.report.json')
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n',
                           encoding='utf-8')
    print(json.dumps({k: report[k] for k in
                      ('labelled', 'presence', 'no_hand', 'presence_rate',
                       'seconds', 'seconds_per_image')}, ensure_ascii=False))
    print(f'report -> {report_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
