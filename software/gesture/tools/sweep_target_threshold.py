"""Sweep the deployment decision threshold on a validation split.

One forward pass collects the scores; the sweep then re-decides without touching
the GPU. Reports the trade-off that matters: target recall against false
positives on true `other`, per threshold.

  T = -1  reproduces plain argmax (the baseline evaluation)

Run on the training server:

  python tools/sweep_target_threshold.py \
      --checkpoint <run>/checkpoints/best_deploy.pt \
      --index      <datasets>/index.jsonl --split val
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.data import GestureDataset                      # noqa: E402
from src.decision import decide                          # noqa: E402
from src.index import (TRAIN_CONFIG, load_train_config,   # noqa: E402
                       read_index)
from src.spec import CURRENT_MODEL, model_config_for      # noqa: E402
from src.train import load_model_from_checkpoint          # noqa: E402

OTHER = 3


def collect(model, rows, data_root, spec, device, batch_size, num_workers,
            limit, model_config=None):
    import torch
    from torch.utils.data import DataLoader
    if limit:
        rows = rows[:limit]
    loader = DataLoader(GestureDataset(rows, data_root, spec, train=False,
                                       model_config=model_config),
                        batch_size=batch_size, shuffle=False,
                        num_workers=num_workers, pin_memory=(device.type == 'cuda'))
    model.eval()
    scores, targets = [], []
    with torch.inference_mode():
        for images, target, _ in loader:
            probabilities = model(images.to(device, non_blocking=True)).softmax(dim=1)
            scores.append(probabilities.cpu().numpy())
            targets.append(target.numpy())
    was = model.training
    if was:
        model.train()
    return np.concatenate(scores), np.concatenate(targets)


def table(preds, targets, n):
    confusion = np.bincount(targets * n + preds, minlength=n * n).reshape(n, n)
    diag = np.diag(confusion).astype(float)
    support = confusion.sum(axis=1).astype(float)
    predicted = confusion.sum(axis=0).astype(float)
    recall = np.divide(diag, support, out=np.zeros(n), where=support > 0)
    precision = np.divide(diag, predicted, out=np.zeros(n), where=predicted > 0)
    total = precision + recall
    f1 = np.divide(2 * precision * recall, total, out=np.zeros(n), where=total > 0)
    row = confusion[OTHER].astype(float)
    row_total = row.sum()
    fpr = row[:3] / row_total if row_total else np.zeros(3)
    return dict(recall=recall, macro_f1=float(f1[support > 0].mean()),
                accuracy=float(diag.sum() / max(1.0, confusion.sum())),
                fpr=fpr, any_fpr=float(row[:3].sum() / row_total) if row_total else 0.0)


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
    parser.add_argument('--batch-size', type=int, default=256)
    parser.add_argument('--num-workers', type=int, default=8)
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()

    import torch
    if not args.device.startswith('cuda') or not torch.cuda.is_available():
        raise SystemExit('CUDA is required; CPU fallback is forbidden.')
    device = torch.device(args.device)
    if device.index is None or device.index >= torch.cuda.device_count():
        raise SystemExit(f'bad device index: {args.device}')

    summary_path = args.index_summary or args.index.parent / 'index_summary.json'
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    data_root = args.data_root or Path(summary['data_root'])
    spec = load_train_config(args.config)
    rows = [r for r in read_index(args.index) if r['split'] == args.split]

    model, step, _, run_config = load_model_from_checkpoint(args.checkpoint, device)
    model_config = model_config_for((run_config or {}).get('model_id', CURRENT_MODEL))
    keys = list(model.class_keys)
    print(f'checkpoint {args.checkpoint.name} step {step}   '
          f'split {args.split}: {len(rows)} rows')

    scores, targets = collect(model, rows, data_root, spec, device,
                              args.batch_size, args.num_workers, args.limit or None,
                              model_config=model_config)
    print(f'collected {len(scores)} score rows\n')

    grid = [None] + [round(0.01 * i, 2) for i in range(0, 61)]
    results = {}
    for threshold in grid:
        preds = decide(scores, threshold)
        results['argmax' if threshold is None else f'{threshold:.2f}'] = \
            table(preds, targets, len(keys))

    print(f'{"T":>7} {"macroF1":>8} {"acc":>7} '
          f'{"palmR":>7} {"backR":>7} {"fistR":>7} '
          f'{"palmFP":>7} {"backFP":>7} {"fistFP":>7} {"anyFP":>7}')
    print('-' * 88)
    shown = [None] + [round(0.05 * i, 2) for i in range(1, 11)]
    for threshold in shown:
        key = 'argmax' if threshold is None else f'{threshold:.2f}'
        r = results[key]
        print(f'{key:>7} {r["macro_f1"]:>8.4f} {r["accuracy"]:>7.4f} '
              f'{r["recall"][0]:>7.4f} {r["recall"][1]:>7.4f} {r["recall"][2]:>7.4f} '
              f'{r["fpr"][0]:>7.4f} {r["fpr"][1]:>7.4f} {r["fpr"][2]:>7.4f} '
              f'{r["any_fpr"]:>7.4f}')

    best_f1 = max(results, key=lambda k: results[k]['macro_f1'])
    print(f"\nbest macro-F1      {results[best_f1]['macro_f1']:.4f} at T={best_f1}")
    baseline = results['argmax']
    print(f"argmax baseline    {baseline['macro_f1']:.4f}  "
          f"palmR {baseline['recall'][0]:.4f} fistR {baseline['recall'][2]:.4f}  "
          f"anyFP {baseline['any_fpr']:.4f}")

    floor = spec['checkpoint']['target_recall_floor']
    eligible = [k for k in results
                if min(results[k]['recall'][:3]) >= floor]
    if eligible:
        pick = min(eligible, key=lambda k: results[k]['any_fpr'])
        print(f"meets the {floor} worst-recall floor: "
              + ', '.join(sorted(eligible, key=lambda k: results[k]['any_fpr'])[:6]))
        print(f"  lowest FPR among them  T={pick}  macro-F1 "
              f"{results[pick]['macro_f1']:.4f}  anyFP {results[pick]['any_fpr']:.4f}")
    else:
        print(f"no threshold reaches a {floor} worst-class recall")

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(dict(
            checkpoint=str(args.checkpoint), checkpoint_step=step, split=args.split,
            rows=len(scores), class_order=keys,
            results={k: dict(macro_f1=v['macro_f1'], accuracy=v['accuracy'],
                             recall=list(v['recall']), other_fpr=list(v['fpr']),
                             any_fpr=v['any_fpr']) for k, v in results.items()},
        ), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(f'\nwrote {args.out}')


if __name__ == '__main__':
    main()
