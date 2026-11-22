"""Merge the four-class index with the teacher's hand-centre labels.

The training loop reads one index file (`--index`) plus a summary next to it, and
the sampler stratifies on `class_id` / `semantic_pool`, which the four-class index
already carries. The position task additionally needs `hand_presence`, `hand_cx`
and `hand_cy` per row, so this tool writes a new index that is the old one with
those three columns added -- the source index is never rewritten, because the
four-class runs still read it and a derived index must not move underneath them.

Rows of the test split are deliberately left without position columns (the
teacher pass skips it), which is why the merge reports them separately instead of
failing: `tools/train_gpos.py` runs on train+val.
"""
import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--index', type=Path, default=PROJECT / 'datasets' / 'index.jsonl')
    parser.add_argument('--labels', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'labels_teacher.jsonl')
    parser.add_argument('--out', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'index_gpos.jsonl')
    parser.add_argument('--source-summary', type=Path, default=None,
                        help='summary of the source index; its split/composition '
                             'fields are inherited because no row is added or removed')
    parser.add_argument('--summary', type=Path, default=None)
    parser.add_argument('--crops-root', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144')
    parser.add_argument('--data-root', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144')
    args = parser.parse_args()

    rows = [json.loads(line) for line in open(args.index, encoding='utf-8')]
    labels = {}
    for line in open(args.labels, encoding='utf-8'):
        label = json.loads(line)
        labels[label['path']] = label
    print(f'index {len(rows):,d} rows  labels {len(labels):,d} rows')

    unlabelled = Counter()
    merged, counts = [], defaultdict(Counter)
    for row in rows:
        entry = dict(row)
        label = labels.get(row['path'])
        if label is None:
            unlabelled[row['split']] += 1
        else:
            entry.update(hand_presence=bool(label['presence']),
                         hand_cx=label['cx'], hand_cy=label['cy'],
                         hand_box_height_px=(None if not label['presence']
                                             else round(label['box'][3] - label['box'][1], 2)),
                         hand_teacher_confidence=label['conf'],
                         hand_teacher_boxes=label['n_boxes'])
            counts[row['split']]['rows'] += 1
            counts[row['split']]['presence' if label['presence'] else 'no_hand'] += 1
        merged.append(entry)

    source_summary = {}
    source_summary_path = (args.source_summary
                           or args.index.with_name('index_summary.json'))
    if source_summary_path.is_file():
        source_summary = json.loads(source_summary_path.read_text(encoding='utf-8'))
    else:
        print(f'warning: no source summary at {source_summary_path}; the derived '
              f'summary will lack the split/composition fields the trainer reads')

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as handle:
        for entry in merged:
            handle.write(json.dumps(entry, ensure_ascii=False) + '\n')

    summary = dict(source_summary)
    summary.update(
        tool='tools/build_gpos_index.py',
        layers=dict(**(summary.get('layers') or {}),
                    source_index=str(args.index),
                    source_index_sha256=sha256_file(args.index),
                    labels=str(args.labels), labels_sha256=sha256_file(args.labels)),
        index_path=str(args.out), index_rows=len(merged),
        index_sha256=sha256_file(args.out),
        data_root=str(args.data_root),
        counts_by_split={split: dict(values) for split, values in sorted(counts.items())},
        unlabelled_rows_by_split=dict(unlabelled),
        hand_columns=['hand_presence', 'hand_cx', 'hand_cy', 'hand_box_height_px',
                      'hand_teacher_confidence', 'hand_teacher_boxes'],
        note='Derived from the source index; the source index is left untouched.',
    )
    summary_path = args.summary or args.out.with_name(args.out.stem + '_summary.json')
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n',
                            encoding='utf-8')
    print(json.dumps({k: summary[k] for k in
                      ('index_rows', 'counts_by_split', 'unlabelled_rows_by_split')},
                     ensure_ascii=False, indent=1))
    print(f'index   -> {args.out}')
    print(f'summary -> {summary_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
