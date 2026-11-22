"""Train G4Net v1 on the indexed four-class gesture data.

Run on the training server with the project interpreter, GPU1 pinned explicitly:

  export CUDA_VISIBLE_DEVICES=1
  /data1/fpga_style_transfer_2026_tmp/envs/starry/bin/python -u tools/train_g4net.py \
      --index   /data1/.../gesture_four_class_20261015/datasets/index.jsonl \
      --run-dir /data1/.../gesture_four_class_20261015/runs/baseline_ce_20261015 \
      --device cuda:0

Preflight (a few hundred steps, one evaluation, no long commit):

  ... --max-steps 300 --eval-every 300 --eval-limit 2000
"""
import argparse
import json
import sys
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.index import TRAIN_CONFIG, read_index, load_train_config  # noqa: E402
from src.train import train  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index', type=Path, required=True)
    parser.add_argument('--index-summary', type=Path,
                        help='defaults to index_summary.json next to --index')
    parser.add_argument('--data-root', type=Path,
                        help='defaults to the data_root recorded in the summary')
    parser.add_argument('--config', type=Path,
                        default=TRAIN_CONFIG)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--max-steps', type=int, default=0, help='0 = config budget')
    parser.add_argument('--log-every', type=int, default=25)
    parser.add_argument('--eval-every', type=int, default=0, help='0 = config cadence')
    parser.add_argument('--num-workers', type=int, default=0, help='0 = config value')
    parser.add_argument('--eval-limit', type=int, default=0,
                        help='cap the val split, 0 = all (preflight use)')
    parser.add_argument('--resume', type=Path)
    args = parser.parse_args()

    import torch
    if not args.device.startswith('cuda'):
        raise SystemExit('an explicit CUDA device is required, e.g. --device cuda:0')
    if not torch.cuda.is_available():
        raise SystemExit('CUDA unavailable; CPU fallback is forbidden.')
    device = torch.device(args.device)
    if device.index is None or device.index >= torch.cuda.device_count():
        raise SystemExit(f'bad device index: {args.device}')
    print(f'torch {torch.__version__}  device {device}  '
          f'{torch.cuda.get_device_name(device)}', flush=True)

    summary_path = args.index_summary or args.index.parent / 'index_summary.json'
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    data_root = args.data_root or Path(summary['data_root'])
    spec = load_train_config(args.config)
    rows = read_index(args.index)
    if len(rows) != summary['index_rows']:
        raise SystemExit(f'index has {len(rows)} rows but the summary says '
                         f'{summary["index_rows"]}')

    print(f'index  : {args.index}  ({len(rows)} rows, sha256 {summary["index_sha256"][:16]}...)',
          flush=True)
    print(f'run dir: {args.run_dir}', flush=True)
    result = train(spec, rows, data_root, summary, args.run_dir, device,
                   train_config_path=args.config,
                   max_steps=args.max_steps or None,
                   log_every=args.log_every,
                   eval_every=args.eval_every or None,
                   num_workers=args.num_workers or None,
                   eval_limit=args.eval_limit or None,
                   resume=args.resume)
    print(json.dumps({k: v for k, v in result.items() if k != 'candidates'},
                     ensure_ascii=False))


if __name__ == '__main__':
    main()
