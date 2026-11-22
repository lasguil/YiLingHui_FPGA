"""Evaluate a G4Net v1 checkpoint on one index split.

Run on the training server with the project interpreter, GPU1 pinned explicitly:

  export CUDA_VISIBLE_DEVICES=1
  /data1/fpga_style_transfer_2026_tmp/envs/starry/bin/python -u tools/eval_g4net.py \
      --checkpoint /data1/.../runs/baseline_ce_20261015/checkpoints/best_macro_f1.pt \
      --index      /data1/.../gesture_four_class_20261015/datasets/index.jsonl \
      --split test --out /data1/.../runs/baseline_ce_20261015/test_metrics.json

The test split is meant to be read once, after the checkpoint and the CPU-side
acceptance threshold are frozen.
"""
import argparse
import json
import sys
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.evaluate import evaluate_model, write_report  # noqa: E402
from src.index import (TRAIN_CONFIG, read_index, load_train_config)  # noqa: E402
from src.spec import CURRENT_MODEL, model_config_for  # noqa: E402
from src.train import load_model_from_checkpoint, sha256_file  # noqa: E402


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
    parser.add_argument('--limit', type=int, default=0, help='cap rows, 0 = all')
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
    if not rows:
        raise SystemExit(f'no rows for split {args.split}')

    model, step, trained_metrics, run_config = load_model_from_checkpoint(
        args.checkpoint, device)
    if run_config is not None and run_config.get('index_sha256') != summary['index_sha256']:
        raise SystemExit('checkpoint was trained on a different index')
    print(f'checkpoint {args.checkpoint.name} from step {step}', flush=True)
    print(f'split {args.split}: {len(rows)} rows', flush=True)

    # The checkpoint owns the geometry; the module default tracks the newest
    # model and would resize an older checkpoint's inputs differently.
    model_config = model_config_for((run_config or {}).get('model_id', CURRENT_MODEL))
    print(f'geometry: {model_config.name}', flush=True)
    result = evaluate_model(model, rows, data_root, spec, device,
                            batch_size=args.batch_size,
                            num_workers=args.num_workers,
                            limit=args.limit or None,
                            model_config=model_config)
    provenance = dict(
        checkpoint=str(args.checkpoint),
        checkpoint_sha256=sha256_file(args.checkpoint),
        checkpoint_step=step,
        checkpoint_val_metrics=trained_metrics,
        split=args.split,
        index_sha256=summary['index_sha256'],
        index_rows=summary['index_rows'],
        evaluated_rows=result['n'],
        notes='FP32 CUDA inference; no augmentation, no threshold applied. '
              'False-positive rates are raw argmax acceptance on true `other`.',
    )
    out = args.out or args.checkpoint.parent.parent / f'{args.split}_metrics.json'
    write_report(result, out, title=f'G4Net v1 {args.split}', extra=provenance)
    print(f'\nwrote {out}')
    print(json.dumps(provenance, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
