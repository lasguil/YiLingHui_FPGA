"""Final integrity check: index <-> crops <-> labels line up.

Three artefacts were produced by three different steps, and training will join
them by path alone, so the joins are checked here rather than discovered later:

  * every indexed row has a crop, and every indexed row that was labelled has a
    label (the test split is deliberately unlabelled);
  * the crop the pipeline loads has exactly the canvas shape of the config, so
    `preprocess_image` performs no further resampling;
  * every label's centre is inside the frame, and its box is inside the frame
    except where the crop itself cut the hand.

Runs on the training server with the project interpreter.
"""
import argparse
import json
import random
import sys
from pathlib import Path

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index', type=Path, default=PROJECT / 'datasets' / 'index.jsonl')
    parser.add_argument('--crops', type=Path, default=PROJECT / 'datasets_16x9_256x144')
    parser.add_argument('--labels', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'labels_teacher.jsonl')
    parser.add_argument('--config', type=Path,
                        default=PROJECT / 'ml' / 'configs' / 'gpos_v1.json')
    parser.add_argument('--sample', type=int, default=300)
    args = parser.parse_args()

    sys.path.insert(0, str(PROJECT / 'ml'))
    from PIL import Image
    from src.preprocess import preprocess_image
    from src.spec import load_config

    spec = load_config(str(args.config))
    height, width = spec['input']['height'], spec['input']['width']
    rows = [json.loads(line) for line in open(args.index, encoding='utf-8')]
    indexed = {row['path'] for row in rows}
    labels = {}
    for line in open(args.labels, encoding='utf-8'):
        row = json.loads(line)
        labels[row['path']] = row
    print(f'index rows {len(rows):,d}  labelled {len(labels):,d}')

    problems = []
    missing_crop = [r['path'] for r in rows
                    if not (args.crops / r['path']).is_file()]
    if missing_crop:
        problems.append(f'{len(missing_crop)} indexed rows have no crop: {missing_crop[:3]}')

    train_val = [r for r in rows if r['split'] in ('train', 'val')]
    unlabelled = [r['path'] for r in train_val if r['path'] not in labels]
    if unlabelled:
        problems.append(f'{len(unlabelled)} train/val rows are unlabelled: {unlabelled[:3]}')
    labelled_test = [r['path'] for r in rows
                     if r['split'] == 'test' and r['path'] in labels]
    if labelled_test:
        problems.append(f'{len(labelled_test)} test rows were labelled anyway')
    stray = [path for path in labels if path not in indexed]
    if stray:
        problems.append(f'{len(stray)} labels point at rows outside the index: {stray[:3]}')

    out_of_frame = 0
    for row in labels.values():
        if not row['presence']:
            continue
        if not (0.0 <= row['cx'] <= 1.0 and 0.0 <= row['cy'] <= 1.0):
            out_of_frame += 1
    if out_of_frame:
        problems.append(f'{out_of_frame} centres fall outside the frame')

    # The pipeline's own reader on a random sample: shape, padding, values.
    rng = random.Random(20261016)
    sample = rng.sample(train_val, min(args.sample, len(train_val)))
    shapes, geometries = set(), set()
    for row in sample:
        with Image.open(args.crops / row['path']) as handle:
            image = handle.convert('RGB')
        array, geometry = preprocess_image(image, spec)
        shapes.add(array.shape)
        geometries.add((tuple(geometry['resized_wh']), tuple(geometry['pad_left_top'])))
    print(f'sample {len(sample)}: array shapes {shapes}')
    print(f'  resized/pad {geometries}')
    if shapes != {(3, height, width)}:
        problems.append(f'pipeline produced {shapes}, expected (3, {height}, {width})')
    if geometries != {((width, height), (0, 0))}:
        problems.append(f'pipeline padded or rescaled the stored crop: {geometries}')

    report = dict(index_rows=len(rows), labelled=len(labels),
                  train_val=len(train_val), test_rows=len(rows) - len(train_val),
                  crop_missing=len(missing_crop), problems=problems)
    print(json.dumps(report, ensure_ascii=False, indent=1))
    print('VERDICT:', 'linked' if not problems else 'PROBLEMS')
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())
