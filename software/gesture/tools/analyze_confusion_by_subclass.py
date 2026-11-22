"""Break a checkpoint's validation errors down by source subclass.

Aggregate metrics say how often a true `other` frame is accepted as a gesture.
They do not say which non-target gesture causes it, because every HaGRID
`other` subclass collapses into one class. This attributes the false positives
to concrete gestures (`four`, `three`, `two_up`, ...) and shows where each
target class loses its recall.

Read-only: it evaluates an existing checkpoint and writes nothing.

Run on the training server:

  python tools/analyze_confusion_by_subclass.py \
      --checkpoint .../runs/baseline_ce_20261015/checkpoints/best_macro_f1.pt \
      --index      .../datasets/index.jsonl --split val
"""
import argparse
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.data import GestureDataset                     # noqa: E402
from src.index import (TRAIN_CONFIG, load_train_config,  # noqa: E402
                        read_index)
from src.spec import CURRENT_MODEL, model_config_for           # noqa: E402
from src.train import load_model_from_checkpoint, sha256_file   # noqa: E402

OTHER = 3


def collect(model, rows, data_root, spec, device, batch_size, num_workers,
            limit, model_config=None):
    import torch
    from torch.utils.data import DataLoader
    if limit:
        rows = rows[:limit]
    dataset = GestureDataset(rows, data_root, spec, train=False,
                             model_config=model_config)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False,
                        num_workers=num_workers, pin_memory=(device.type == 'cuda'))
    was_training = model.training
    model.eval()
    preds, targets, subclasses, sources = [], [], [], []
    with torch.inference_mode():
        for images, target, index in loader:
            logits = model(images.to(device, non_blocking=True))
            preds.append(logits.argmax(dim=1).cpu().numpy())
            targets.append(target.numpy())
            for i in index.tolist():
                subclasses.append(rows[i]['source_subclass'])
                sources.append(rows[i]['source_dataset'])
    if was_training:
        model.train()
    return (np.concatenate(preds), np.concatenate(targets),
            np.asarray(subclasses), np.asarray(sources))


def _table(header, rows, widths):
    lines = ['  ' + '  '.join(f'{name:<{width}}' for name, width in zip(header, widths))]
    lines.append('  ' + '  '.join('-' * width for width in widths))
    for row in rows:
        lines.append('  ' + '  '.join(f'{value:<{width}}' for value, width in zip(row, widths)))
    return lines


def report_false_positives(preds, targets, subclasses, class_keys, top=None):
    """Truth is `other`: which source subclass is accepted as a gesture."""
    mask = targets == OTHER
    groups = defaultdict(lambda: np.zeros(len(class_keys) - 1, dtype=int))
    totals = defaultdict(int)
    for group in np.unique(subclasses[mask]):
        selected = mask & (subclasses == group)
        totals[group] = int(selected.sum())
        for predicted in preds[selected]:
            if predicted != OTHER:
                groups[group][predicted] += 1
    rows = []
    for group, counts in groups.items():
        total = totals[group]
        cells = [f'{int(counts[i])}' for i in range(len(class_keys) - 1)]
        rate = counts.sum() / total if total else 0.0
        rows.append((group, f'{total}', *cells, f'{int(counts.sum())}', f'{rate:.4f}'))
    rows.sort(key=lambda r: -int(r[-2]))
    grand = sum(int(r[-2]) for r in rows)
    # Column names come from the checkpoint, not from a hardcoded version: the
    # three targets are not the same classes in v1 and v2/v3.
    targets = [key for key in class_keys if key != class_keys[OTHER]]
    lines = [f'  total false positives: {grand} of {int(mask.sum())} true other',
             '']
    lines += _table(['subclass', 'n', *[f'->{key}' for key in targets], 'FP',
                     'FP rate'],
                    rows, [24, 6, 6, 6, 6, 6, 8])
    if top:
        cumulative = 0
        lines += ['', f'  top {top} contributors:']
        for row in rows[:top]:
            cumulative += int(row[-2])
            share = cumulative / grand if grand else 0.0
            lines.append(f'    {row[0]:<24} {row[-2]:>5}  ({share:.0%} cumulative)')
    return lines


def report_target_recall(preds, targets, subclasses, class_keys):
    """Target classes: one confusion row per source subclass.

    Every destination column is shown, including the correct one, so the labels
    cannot drift out of step with the values.
    """
    rows = []
    for class_id, key in enumerate(class_keys):
        if class_id == OTHER:
            continue
        mask = targets == class_id
        for group in np.unique(subclasses[mask]):
            selected = mask & (subclasses == group)
            n = int(selected.sum())
            predicted = preds[selected]
            cells = [f'{int((predicted == other).sum())}'
                     for other in range(len(class_keys))]
            correct = int((predicted == class_id).sum())
            rows.append((f'{key}/{group}', f'{n}', *cells, f'{correct / n:.4f}'))
    header = ['class/subclass', 'n', *class_keys, 'recall']
    widths = [28, 6, 10, 10, 6, 8, 8]
    return _table(header, rows, widths[:len(header)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--index', type=Path, required=True)
    parser.add_argument('--index-summary', type=Path)
    parser.add_argument('--data-root', type=Path)
    parser.add_argument('--config', type=Path,
                        default=TRAIN_CONFIG)
    parser.add_argument('--split', default='val', choices=['train', 'val', 'test'])
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--batch-size', type=int, default=128)
    parser.add_argument('--num-workers', type=int, default=8)
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--top', type=int, default=8)
    args = parser.parse_args()

    import json
    import torch
    if not args.device.startswith('cuda') or not torch.cuda.is_available():
        raise SystemExit('CUDA is required; CPU fallback is forbidden.')
    device = torch.device(args.device)

    summary_path = args.index_summary or args.index.parent / 'index_summary.json'
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    data_root = args.data_root or Path(summary['data_root'])
    spec = load_train_config(args.config)
    rows = [r for r in read_index(args.index) if r['split'] == args.split]

    model, step, _, run_config = load_model_from_checkpoint(args.checkpoint,
                                                            device)
    if run_config and run_config.get('index_sha256') != summary['index_sha256']:
        raise SystemExit('checkpoint was trained on a different index')
    print(f'checkpoint {args.checkpoint.name} step {step} '
          f'sha256 {sha256_file(args.checkpoint)[:16]}...')
    print(f'split {args.split}: {len(rows)} rows\n')

    model_config = model_config_for((run_config or {}).get('model_id', CURRENT_MODEL))
    preds, targets, subclasses, sources = collect(
        model, rows, data_root, spec, device, args.batch_size,
        args.num_workers, args.limit or None, model_config=model_config)
    class_keys = model.class_keys

    accuracy = float((preds == targets).mean())
    print(f'  accuracy {accuracy:.4f} over {len(preds)} rows\n')

    print('=== true `other`, by source subclass ===')
    for line in report_false_positives(preds, targets, subclasses, class_keys,
                                       top=args.top):
        print(line)

    print('\n=== target classes, by source subclass ===')
    for line in report_target_recall(preds, targets, subclasses, class_keys):
        print(line)

    print('\n=== true `other` false positives, by source_dataset ===')
    mask = targets == OTHER
    rows_by_source = []
    for source in np.unique(sources[mask]):
        selected = mask & (sources == source)
        hits = int((preds[selected] != OTHER).sum())
        rows_by_source.append((source, f'{int(selected.sum())}', f'{hits}',
                               f'{hits / max(1, int(selected.sum())):.4f}'))
    for line in _table(['source', 'n', 'FP', 'FP rate'], rows_by_source,
                       [24, 8, 8, 8]):
        print(line)


if __name__ == '__main__':
    main()
