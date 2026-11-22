"""Emit the per-image override table that demotes small-hand images to `other`.

The rule lives in the training config (`small_hand_rule`): a measured hand-area
threshold applied to a detector table. Only images whose hand is too small to
read keep their gesture label; the rest join `other`, where the model is asked
to reject them rather than to classify a pose it cannot see.

Every emitted row carries the measurement that triggered it, so the table is its
own audit trail, and `src/index.py` fails the build if any listed path is gone.

Run from the repository root:
  python gesture/tools/build_small_hand_overrides.py
"""
import argparse
import json
import sys
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.index import load_train_config  # noqa: E402

OTHER_CLASS_ID = 3
OTHER_POOL = 'hagrid_hand'
OTHER_SUBCLASS = 'small_hand'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path,
                        default=GESTURE / 'configs/g4net_v1_train.json')
    parser.add_argument('--data-root', type=Path, default=GESTURE / 'dataset')
    parser.add_argument('--table', type=Path,
                        help='detector table; defaults to the config path '
                             'resolved against --data-root')
    parser.add_argument('--out', type=Path,
                        help='defaults to the first entry of config overrides')
    args = parser.parse_args()

    spec = load_train_config(args.config)
    rule = spec.get('small_hand_rule')
    if not rule:
        raise SystemExit('config has no small_hand_rule')
    table_path = args.table or (args.data_root / rule['table'])
    if not table_path.is_file():
        raise SystemExit(f'missing detector table: {table_path} '
                         f'(run tools/build_hand_size_table.py first)')
    out = args.out or args.data_root / spec['overrides'][0]

    threshold = float(rule['max_area'])
    rows = [json.loads(line) for line
            in table_path.read_text(encoding='utf-8').splitlines() if line.strip()]
    selected = [row for row in rows
                if row.get('area_max') is not None and row['area_max'] < threshold]

    with out.open('w', encoding='utf-8') as handle:
        for row in sorted(selected, key=lambda r: r['path']):
            handle.write(json.dumps(dict(
                path=row['path'],
                class_id=OTHER_CLASS_ID,
                semantic_pool=OTHER_POOL,
                source_subclass=OTHER_SUBCLASS,
                label_review_status='size_derived',
                previous_group=row['group'],
                area_max=row['area_max'],
                reason=f'hand occupies {row["area_max"]:.4f} of the frame, '
                       f'below the {threshold} cut',
            ), ensure_ascii=False) + '\n')

    by_group = {}
    for row in selected:
        by_group[row['group']] = by_group.get(row['group'], 0) + 1
    print(f'rule      : hand area < {threshold} ({rule["note"][:60]}...)')
    print(f'table     : {table_path}  ({len(rows):,d} rows)')
    print(f'wrote     : {out}  ({len(selected):,d} rows, '
          f'{len(selected) / len(rows):.1%} of the table)')
    for group in sorted(by_group):
        total = sum(1 for row in rows if row['group'] == group)
        print(f'  {group:<22s} {by_group[group]:>6,d} of {total:>7,d} '
              f'({by_group[group] / total:5.1%})')
    no_hand = sum(1 for row in rows if row.get('area_max') is None)
    print(f'  (not demoted: {no_hand:,d} rows where the detector found no hand; '
          f'they are not "small", they are undetected)')


if __name__ == '__main__':
    main()
