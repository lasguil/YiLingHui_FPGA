"""Build the G4Net v1 training index: enumerate, hash, deduplicate, split.

Run on the training server, from the deployed code directory:

  python tools/build_index.py \
      --data-root /data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015/datasets \
      --out       /data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015/datasets

Writes index.jsonl and index_summary.json. The summary carries the split seed,
the counts and the content fingerprint that every checkpoint records.
"""
import argparse
import json
import sys
import time
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.index import TRAIN_CONFIG, build_index, load_train_config  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-root', type=Path, required=True,
                        help='directory holding the class folders')
    parser.add_argument('--out', type=Path,
                        help='output directory (defaults to --data-root)')
    parser.add_argument('--config', type=Path,
                        default=TRAIN_CONFIG)
    args = parser.parse_args()

    spec = load_train_config(args.config)
    out = args.out or args.data_root
    started = time.time()
    print(f'data root: {args.data_root}')
    print(f'config   : {args.config}')

    rows, summary = build_index(args.data_root, spec, out,
                                progress=lambda n: print(f'  enumerated {n}', flush=True))
    print(f'\nindexed {len(rows)} rows in {time.time() - started:.0f}s')
    print(f'  duplicates dropped : {summary["duplicates_dropped"]}')
    if summary['duplicate_conflicts']:
        print(f'  DUPLICATE CONFLICTS: {len(summary["duplicate_conflicts"])} '
              f'across class ids (first 3: {summary["duplicate_conflicts"][:3]})')
    for split in ('train', 'val', 'test'):
        counts = summary['counts_by_split'][split]
        print(f'  {split:<5s}: ' + '  '.join(f'class{k}={v}' for k, v in counts.items()))
    if summary['dropped_subdirs']:
        print('  dropped by config: ' + '  '.join(
            f"{b['root']}/{b['subdir']}" for b in summary['dropped_subdirs']))
    print('  pool totals: ' + '  '.join(
        f'{k}={v}' for k, v in summary['counts_by_pool'].items()))
    print('  source totals: ' + '  '.join(
        f'{k}={v}' for k, v in summary['counts_by_source_total'].items()))
    print(f'  index_sha256: {summary["index_sha256"]}')
    print(f'\nwrote {out / "index.jsonl"}\nwrote {out / "index_summary.json"}')
    print(json.dumps(summary['counts_by_subclass_total'], ensure_ascii=False))


if __name__ == '__main__':
    main()
