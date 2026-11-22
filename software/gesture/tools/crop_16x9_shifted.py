"""Re-cut the 16:9 window so it moves vertically to keep the hand whole.

The first crop was always the centred band of the mirror, and it cut the hand in
about a third of the frames. Those labels describe the centre of a hand that is
half out of frame, which is not a well-defined point, and the model answered
with a diffuse blob -- measured: a 16% false-positive rate on no-hand frames and
a ~105 px centre bias.

This tool keeps the window **the same size** (full width, 16:9) and moves it
vertically to the smallest extent that contains the hand:

  * hand already inside the centred window  -> no movement at all (offset stays
    at the centred value). Moving it further would push the hand towards the
    middle of the canvas, and since the model only ever sees the window, that
    would erase the position information the swipe logic depends on: 97% of the
    labels are already inside cy 0.25-0.75, and recentring the rest would make
    the distribution collapse on 0.5.
  * hand partly outside -> move it just far enough to fit.
  * hand taller than the window -> centre the box, which minimises how much of it
    is cut; no offset can contain it, so this is the best available framing.

The label is the teacher's box on the mirror, moved with the window and scaled to
the canvas, so it stays the box of the same pixels. Labels are written in the
same schema as the first pass, which is what `tools/build_gpos_index.py` reads.

Modes: selftest (synthetic checks), run (parallel), verify (dimensions + parity).
"""
import argparse
import hashlib
import json
import os
import sys
import time
from collections import Counter
from multiprocessing import Pool
from pathlib import Path

OUT_WIDTH, OUT_HEIGHT = 256, 144
# Preferred breathing room between the hand and the window edge, in source
# pixels. A hand that just fits sits flush against the edge, which is contained
# but leaves the model no boundary to look at; when the range allows, leave this
# much instead. When it does not, fall back to the exact fit.
MARGIN = 12
JPEG_QUALITY = 95
SOURCE_EXTENSIONS = {'.jpeg', '.jpg', '.png'}

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')
DEFAULT_SOURCE = PROJECT / 'datasets'
DEFAULT_LABELS = PROJECT / 'datasets' / 'labels_teacher_mirror.jsonl'
DEFAULT_INDEX = PROJECT / 'datasets' / 'index.jsonl'
DEFAULT_DEST = PROJECT / 'datasets_16x9_shifted_256x144'

_RUN = {}


def window_for(width, height):
    """(window height, maximum offset) for a source of this size.

    Full width, 16:9, capped by the source height so a short source is never
    upscaled into a taller window than it has pixels for.
    """
    window_h = min(height, int(round(width * OUT_HEIGHT / OUT_WIDTH)))
    return window_h, max(0, height - window_h)


def offset_range(box, width, height, margin=MARGIN):
    """(low, high, margin_used): offsets that contain the hand, if any.

    `low = ceil(y2 - window_h)` is the smallest offset whose window bottom is at
    or below the hand, `high = floor(y1)` the largest whose top is at or above
    it. The margin shrinks that interval when there is room, so the hand does not
    sit flush against the edge.
    """
    window_h, max_offset = window_for(width, height)
    _, y1, _, y2 = box
    low = max(0, int(-(window_h - int(y2))))          # ceil(y2 - window_h)
    high = min(max_offset, int(y1))
    if low > high:
        return None
    if margin and low + margin <= high - margin:
        return (low + margin, high - margin, True)
    return (low, high, False)


def choose_offset(box, presence, width, height):
    """The vertical window offset: the least movement that contains the hand.

    Returns (offset, reason) where reason is one of `centred` (nothing to fit or
    no hand), `moved` (a shift was enough), `taller_than_window` (no offset can
    contain it, so the box is centred instead, which cuts the least).
    """
    window_h, max_offset = window_for(width, height)
    centred = min(max_offset, max(0, (height - window_h) // 2))
    if not presence or box is None:
        return centred, 'centred'
    span = offset_range(box, width, height)
    if span is not None:
        low, high, _ = span
        offset = min(max(low, centred), high)
        return offset, ('centred' if offset == centred else 'moved')
    y1, _, y2, _ = (box[0], box[1], box[2], box[3])
    wanted = int(round((box[1] + box[3]) / 2 - window_h / 2))
    return min(max(0, wanted), max_offset), 'taller_than_window'


def shift_label(label, offset, width, height):
    """Move the mirror-space label into the window, in canvas coordinates."""
    window_h, _ = window_for(width, height)
    scale_x, scale_y = OUT_WIDTH / width, OUT_HEIGHT / window_h
    if not label['presence']:
        return dict(presence=False, cx=None, cy=None, box=None, conf=None,
                    n_boxes=label.get('n_boxes', 0))
    x1, y1, x2, y2 = label['box']
    box = [round(x1 * scale_x, 2), round((y1 - offset) * scale_y, 2),
           round(x2 * scale_x, 2), round((y2 - offset) * scale_y, 2)]
    return dict(presence=True,
                cx=round((box[0] + box[2]) / 2 / OUT_WIDTH, 6),
                cy=round((box[1] + box[3]) / 2 / OUT_HEIGHT, 6),
                box=box, conf=label.get('conf'), n_boxes=label.get('n_boxes', 1))


def touches_border(box):
    if box is None:
        return False
    return (box[0] <= 0.5 or box[1] <= 0.5
            or box[2] >= OUT_WIDTH - 0.5 or box[3] >= OUT_HEIGHT - 0.5)


def selftest():
    """The offset rule, checked on synthetic cases before 170k crops are written."""
    checks = []

    def check(name, condition, detail=''):
        checks.append((name, bool(condition), detail))

    # already inside the centred window -> do not move
    check('hand already inside is left alone',
          choose_offset([200, 180, 300, 320], True, 512, 512) == (112, 'centred'))
    # low hand inside the source -> moved up just enough (y2 - 288)
    # with the margin the offset is 192 + 12: contained and not flush
    offset, reason = choose_offset([200, 300, 300, 480], True, 512, 512)
    check('low hand moved up to fit', reason == 'moved' and offset == 204, f'{offset} {reason}')
    # a hand reaching the very bottom edge still fits, at the largest offset
    offset, reason = choose_offset([200, 400, 300, 512], True, 512, 512)
    check('hand at the bottom edge fits at max offset',
          reason == 'moved' and offset == 224, f'{offset} {reason}')
    # high hand -> moved down to y1
    offset, reason = choose_offset([200, 20, 300, 150], True, 512, 512)
    check('high hand moved down to fit', reason == 'moved' and offset == 20, f'{offset} {reason}')
    # too tall for the window -> box centred, best effort
    offset, reason = choose_offset([200, 100, 300, 420], True, 512, 512)
    check('hand taller than the window is centred',
          reason == 'taller_than_window' and offset == min(224, max(0, 260 - 144)),
          f'{offset} {reason}')
    # no hand -> centred window, unchanged from the old behaviour
    check('no hand keeps the centred window',
          choose_offset(None, False, 512, 512) == (112, 'centred'))
    # a short source never gets a window taller than itself
    check('short source capped by its height', window_for(512, 200) == (200, 0))
    # labels move with the window and keep describing the same pixels
    hand = dict(presence=True, cx=0.5, cy=0.75, box=[200.0, 400.0, 300.0, 500.0],
                conf=0.9, n_boxes=1)
    offset, _ = choose_offset(hand['box'], True, 512, 512)
    scale = OUT_HEIGHT / window_for(512, 512)[0]          # 144 / 288
    shifted = shift_label(hand, offset, 512, 512)
    expected_y1 = (400 - offset) * scale
    expected_cy = ((expected_y1 + (500 - offset) * scale) / 2) / OUT_HEIGHT
    check('label lands at the same place in the new window',
          abs(shifted['box'][1] - expected_y1) < 0.01
          and abs(shifted['cy'] - expected_cy) < 1e-6,
          f"got {shifted['box'][1]} vs {expected_y1}, cy {shifted['cy']} vs {expected_cy}")
    span = offset_range(hand['box'], 512, 512)
    check('the hand is contained by the chosen offset',
          offset <= hand['box'][1] and offset + window_for(512, 512)[0] >= hand['box'][3],
          f'offset {offset} for box {hand["box"]}')
    # the centred band leaves the hand outside the window: that is the fix's point
    check('the old centred window did cut it',
          hand['box'][1] < 112 or hand['box'][3] > 112 + window_for(512, 512)[0])
    # a hand that can only just fit is contained, not clipped, even though its box
    # edge meets the canvas edge -- measured, not conflated with clipping
    tight, tight_reason = choose_offset([200, 400, 300, 512], True, 512, 512)
    tight_crop = shift_label(dict(presence=True, box=[200, 400, 300, 512], conf=0.9), tight, 512, 512)
    check('a hand that just fits counts as contained, not clipped',
          tight_reason == 'moved' and not (400 < tight - 0.5 or 512 > tight + 288 + 0.5)
          and touches_border(tight_crop['box']), f'{tight} {tight_crop["box"]}')
    # a hand with room around it gets the margin; the centred offset is kept
    wide = [200.0, 200.0, 300.0, 400.0]
    wide_span = offset_range(wide, 512, 512)
    wide_offset, wide_reason = choose_offset(wide, True, 512, 512)
    bare_low = max(0, int(-(window_for(512, 512)[0] - int(wide[3]))))
    check('margin is used when the range allows it',
          wide_span is not None and wide_span[2] is True and wide_span[0] > bare_low,
          str(wide_span))
    check('a flush bottom edge is cleared, a comfortable hand is left alone',
          wide_reason == 'moved' and wide_offset == wide_span[0]
          and choose_offset([200.0, 250.0, 300.0, 300.0], True, 512, 512)[0] == 112,
          f'{wide_offset} {wide_reason}')

    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        print(f'  [{"ok  " if ok else "FAIL"}] {name}' + (f'  {detail}' if not ok else ''))
    print(f'{passed}/{len(checks)} checks passed')
    return 0 if passed == len(checks) else 1


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _worker_init(source_root, dest_root, labels, overwrite, centre_splits):
    _RUN.update(source_root=source_root, dest_root=dest_root, labels=labels,
                overwrite=overwrite, centre_splits=centre_splits)


def _worker(row):
    from PIL import Image
    relative = row['path']
    label = _RUN['labels'].get(relative)
    source = _RUN['source_root'] / relative
    destination = _RUN['dest_root'] / relative
    result = dict(path=relative, status='ok', offset=None, reason=None,
                  presence=False, clipped=False, edge_flush=False)
    try:
        if not source.is_file():
            result['status'] = 'missing_source'
            return result
        if label is None:
            result['status'] = 'missing_label'
            return result
        if not _RUN['overwrite'] and destination.is_file():
            with Image.open(destination) as handle:
                if handle.size == (OUT_WIDTH, OUT_HEIGHT):
                    result['status'] = 'skipped'
                    return result
        destination.parent.mkdir(parents=True, exist_ok=True)
        with Image.open(source) as handle:
            image = handle.convert('RGB')
            width, height = image.size
            if row['split'] in _RUN['centre_splits']:
                window_h, max_offset = window_for(width, height)
                offset = min(max_offset, max(0, (height - window_h) // 2))
                reason = 'centred_split'
            else:
                offset, reason = choose_offset(label['box'], label['presence'],
                                               width, height)
            window_h, _ = window_for(width, height)
            crop = image.crop((0, offset, width, offset + window_h))
            if crop.size != (OUT_WIDTH, OUT_HEIGHT):
                crop = crop.resize((OUT_WIDTH, OUT_HEIGHT), Image.Resampling.BILINEAR)
            crop.save(destination, format='JPEG', quality=JPEG_QUALITY, subsampling=0)
        moved = shift_label(label, offset, width, height)
        # "cut" means the hand really extends past the window, not that its box
        # edge coincides with the canvas edge -- a hand that exactly fits does
        # the latter and is a perfectly good sample.
        clipped = False
        if label['presence']:
            _, y1, _, y2 = label['box']
            clipped = y1 < offset - 0.5 or y2 > offset + window_h + 0.5
        result.update(offset=offset, reason=reason, presence=moved['presence'],
                      clipped=clipped,
                      edge_flush=(not clipped and moved['box'] is not None
                                  and touches_border(moved['box'])),
                      label=moved)
    except Exception as error:                        # noqa: BLE001 - reported
        result['status'] = 'error'
        result['error'] = f'{type(error).__name__}: {error}'
    return result


def run(args):
    for path, label in ((args.source, 'source'), (args.dest, 'dest')):
        if not str(path.resolve()).startswith(str(PROJECT)):
            raise SystemExit(f'{label} is outside the project directory: {path}')
    if args.dest.resolve() == args.source.resolve():
        raise SystemExit('dest and source are the same directory')

    labels = {}
    for line in open(args.labels, encoding='utf-8'):
        entry = json.loads(line)
        labels[entry['path']] = entry
    rows = [json.loads(line) for line in open(args.index, encoding='utf-8')]
    rows = [row for row in rows if row['split'] in set(args.splits.split(','))]
    if args.limit:
        rows = rows[:args.limit]
    print(f'{len(rows):,d} rows; {len(labels):,d} mirror labels', flush=True)

    started = time.time()
    reasons, statuses, offsets, entries = Counter(), Counter(), Counter(), []
    clipped = flush = 0
    labels_out = args.dest / 'labels_shifted.jsonl'
    args.dest.mkdir(parents=True, exist_ok=True)
    with open(labels_out, 'w', encoding='utf-8') as handle:
        centre_splits = {s for s in args.centre_splits.split(',') if s}
        with Pool(args.workers, initializer=_worker_init,
                  initargs=(args.source, args.dest, labels, args.overwrite,
                            centre_splits)) as pool:
            for number, result in enumerate(pool.imap_unordered(_worker, rows, chunksize=32), 1):
                statuses[result['status']] += 1
                if result['status'] in ('ok', 'skipped'):
                    reasons[result['reason']] += 1
                    offsets[result['offset']] += 1
                    if result.get('clipped'):
                        clipped += 1
                    if result.get('edge_flush'):
                        flush += 1
                    if result.get('label'):
                        entry = dict(path=result['path'], split=None,
                                     class_id=None, semantic_pool=None, **result['label'])
                        entries.append(entry)
                if number % 10000 == 0:
                    print(f'  {number:,d}/{len(rows):,d}  {number / (time.time() - started):,.0f} img/s '
                          f'{dict(statuses)}', flush=True)
    # keep the index's own columns alongside the new labels
    by_path = {row['path']: row for row in rows}
    for entry in entries:
        row = by_path[entry['path']]
        entry.update(split=row['split'], class_id=row['class_id'],
                     semantic_pool=row['semantic_pool'])
    with open(labels_out, 'w', encoding='utf-8') as handle:
        for entry in entries:
            handle.write(json.dumps(entry, ensure_ascii=False) + '\n')

    before = sum(1 for _ in [e for e in entries if e['presence']])
    manifest = dict(
        tool='tools/crop_16x9_shifted.py', rule=dict(
            window='full width, 16:9, moved vertically to the least extent that '
                   'contains the hand; centred when nothing needs moving',
            canvas=[OUT_HEIGHT, OUT_WIDTH], jpeg_quality=JPEG_QUALITY),
        source=str(args.source), labels=str(args.labels),
        mirror_labels_sha256=sha256(args.labels), dest=str(args.dest),
        rows=len(rows), statuses=dict(statuses), move_reasons=dict(reasons),
        offset_histogram={str(k): v for k, v in sorted(offsets.items())},
        presence_rows=before, clipped_after=clipped, edge_flush_after=flush,
        seconds=round(time.time() - started, 1), interpreter=sys.executable)
    (args.dest / 'crop_manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: manifest[k] for k in
                      ('statuses', 'move_reasons', 'presence_rows', 'clipped_after',
                       'edge_flush_after')}, ensure_ascii=False))
    print(f'labels -> {labels_out}')
    return 0


def verify(args):
    from PIL import Image
    rows = [json.loads(line) for line in open(args.index, encoding='utf-8')]
    rows = [row for row in rows if row['split'] in set(args.splits.split(','))]
    labels = {}
    for line in open(args.dest / 'labels_shifted.jsonl', encoding='utf-8'):
        entry = json.loads(line)
        labels[entry['path']] = entry
    missing = [row['path'] for row in rows if row['path'] not in labels]
    sizes = Counter()
    for row in rows:
        path = args.dest / row['path']
        if path.is_file():
            with Image.open(path) as handle:
                sizes[handle.size] += 1
        else:
            missing.append(row['path'])
    print(f'rows {len(rows):,d}  missing {len(missing):,d}  sizes {dict(sizes)}')
    problems = []
    if missing:
        problems.append(f'{len(missing)} rows have no crop, first {missing[:3]}')
    if set(sizes) != {(OUT_WIDTH, OUT_HEIGHT)}:
        problems.append(f'unexpected sizes {dict(sizes)}')
    moves = Counter(entry.get('reason') for entry in labels.values())
    print(f'move reasons over the labels: {dict(moves)}')
    print('VERDICT:', 'ok' if not problems else problems)
    return 0 if not problems else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mode', choices=['selftest', 'run', 'verify'], required=True)
    parser.add_argument('--index', type=Path, default=DEFAULT_INDEX)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--labels', type=Path, default=DEFAULT_LABELS)
    parser.add_argument('--dest', type=Path, default=DEFAULT_DEST)
    parser.add_argument('--splits', default='train,val')
    parser.add_argument('--centre-splits', default='val,test',
                        help='splits that keep the centred window, so their crops '
                             'stay byte-identical to the previous dataset and the '
                             'two models can be compared on the same evaluation set')
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--overwrite', action='store_true')
    args = parser.parse_args()
    if args.mode == 'selftest':
        return selftest()
    if args.mode == 'run':
        return run(args)
    return verify(args)


if __name__ == '__main__':
    sys.exit(main())
