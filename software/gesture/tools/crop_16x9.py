"""Materialise the 16:9 training canvas from the square dataset.

The v5 model takes a 256x144 canvas, so the training pixels have to be 16:9.
The source mirrors are square (512x512 for HaGRID, various squares for the
external negatives), so this tool cuts the largest centred 16:9 window out of
each one and resizes it to 256x144. The resize is PIL bilinear, the same call
`src/preprocess.py` makes, so the stored file is exactly the tensor the network
sees: a 16:9 image resized into a 16:9 canvas needs no padding and no further
resampling, which is what keeps this step from becoming the letterbox disease
that v2 died of.

The window rule (16:9, integer, centred, maximal) is stated once in
`window_box()` and checked by `selftest()` on synthetic images: a marker at a
known source pixel must land at the computed output pixel, which is what
catches a swapped axis or an off-by-one before 170k images are written.

Nothing here labels anything. A crop that loses the hand is deliberate: it is
the framing the camera will actually deliver, and the teacher pass afterwards
records it as a frame with no hand.

Modes
  selftest   synthetic geometry checks only; writes nothing
  run        write the crops (parallel, resumable)
  verify     dimensions, counts, path parity against the index, JPEG fidelity

Run on the training server with the project interpreter:
  P=/data1/fpga_style_transfer_2026_tmp/envs/starry/bin/python
  $P tmp/crop_16x9.py --mode selftest
  nohup nice -n 19 $P tmp/crop_16x9.py --mode run --workers 8 > logs/crop_16x9.log 2>&1 &
  $P tmp/crop_16x9.py --mode verify
"""
import argparse
import hashlib
import io
import json
import os
import sys
import time
from collections import Counter
from multiprocessing import Pool
from pathlib import Path

OUT_WIDTH, OUT_HEIGHT = 256, 144
ASPECT_NUM, ASPECT_DEN = 16, 9
JPEG_QUALITY = 95
SOURCE_EXTENSIONS = {'.jpeg', '.jpg', '.png'}

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')
DEFAULT_SOURCE = PROJECT / 'datasets'
DEFAULT_INDEX = PROJECT / 'datasets' / 'index.jsonl'
DEFAULT_DEST = PROJECT / 'datasets_16x9_256x144'

_RUN = {}


def window_box(width, height):
    """Largest centred 16:9 window with integer sides, as (left, top, w, h).

    Integer sides at exactly 16:9 mean the resize to the canvas is a pure scale
    with no aspect distortion; at most 15 columns of a 512-wide source go unused.
    """
    if width < ASPECT_NUM or height < ASPECT_DEN:
        raise ValueError(f'source too small for a 16:9 window: {width}x{height}')
    scale = min(width // ASPECT_NUM, height // ASPECT_DEN)
    box_w, box_h = ASPECT_NUM * scale, ASPECT_DEN * scale
    return (width - box_w) // 2, (height - box_h) // 2, box_w, box_h


def crop_and_resize(image):
    """The one crop+resize path: used by the tool, the self-test and the verify."""
    from PIL import Image
    left, top, box_w, box_h = window_box(*image.size)
    crop = image.crop((left, top, left + box_w, top + box_h))
    if crop.size != (OUT_WIDTH, OUT_HEIGHT):
        crop = crop.resize((OUT_WIDTH, OUT_HEIGHT), Image.Resampling.BILINEAR)
    return crop, (left, top, box_w, box_h)


def save_image(image, destination):
    """Write with the source's own format family, so the index needs no rewrite."""
    suffix = destination.suffix.lower()
    if suffix == '.png':
        image.save(destination, format='PNG', optimize=False)
    else:
        image.save(destination, format='JPEG', quality=JPEG_QUALITY, subsampling=0)


# ---------------------------------------------------------------- self-test

def selftest():
    """Synthetic checks: geometry, axis order, and the no-further-resize property."""
    import numpy as np
    from PIL import Image

    checks = []

    def check(name, condition, detail=''):
        checks.append((name, bool(condition), detail))
        if not condition:
            print(f'  [FAIL] {name} {detail}')

    # 1. The window rule itself, including the non-square and small sources.
    cases = {
        (512, 512): (0, 112, 512, 288),    # the HaGRID mirror: exactly half scale
        (512, 367): (0, 39, 512, 288),
        (480, 480): (0, 105, 480, 270),
        (425, 425): (4, 95, 416, 234),     # 16 x 26: 9 columns of 425 go unused
        (1000, 562): (4, 2, 992, 558),     # 16:9 already, but 16x62 and 9x62 fit
        (1280, 720): (0, 0, 1280, 720),    # exactly 16:9 and divisible: full frame
    }
    for size, expected in cases.items():
        observed = window_box(*size)
        check(f'window_box{size} -> {expected}', observed == expected, f'got {observed}')

    # 2. Marker test: where a source pixel lands in the output. A swapped axis or
    #    a wrong origin moves the marker and fails here, on 512x512 (the main
    #    case) and on an odd-sized source.
    for size in ((512, 512), (425, 425), (1000, 562)):
        source = Image.new('RGB', size, (0, 0, 0))
        left, top, box_w, box_h = window_box(*size)
        # one bright block at each corner of the window, 1/8 of the window in size
        block_w, block_h = box_w // 8, box_h // 8
        corners = {
            'top_left': (left, top),
            'top_right': (left + box_w - block_w, top),
            'bottom_left': (left, top + box_h - block_h),
            'bottom_right': (left + box_w - block_w, top + box_h - block_h),
        }
        for name, (x, y) in corners.items():
            source.paste((255, 255, 255), (x, y, x + block_w, y + block_h))
        out, _ = crop_and_resize(source)
        array = np.asarray(out).mean(axis=2)
        # Expected output block: the same corner, scaled by the resize ratio.
        ratio_x = OUT_WIDTH / box_w
        ratio_y = OUT_HEIGHT / box_h
        expected = {
            'top_left': (0.5 * block_w * ratio_x, 0.5 * block_h * ratio_y),
            'top_right': (OUT_WIDTH - 0.5 * block_w * ratio_x,
                          0.5 * block_h * ratio_y),
            'bottom_left': (0.5 * block_w * ratio_x,
                            OUT_HEIGHT - 0.5 * block_h * ratio_y),
            'bottom_right': (OUT_WIDTH - 0.5 * block_w * ratio_x,
                             OUT_HEIGHT - 0.5 * block_h * ratio_y),
        }
        for name, (want_x, want_y) in expected.items():
            # Look only in the quadrant the marker belongs to, so a second (mirrored)
            # copy of the pattern cannot satisfy the check by accident.
            x0, x1 = (0, OUT_WIDTH // 2) if name.endswith('left') else (OUT_WIDTH // 2, OUT_WIDTH)
            y0, y1 = (0, OUT_HEIGHT // 2) if name.startswith('top') else (OUT_HEIGHT // 2, OUT_HEIGHT)
            quadrant = array[y0:y1, x0:x1]
            rows, cols = np.where(quadrant > 128)
            check(f'{size} {name}: marker present',
                  rows.size > 0 and cols.size > 0, 'no bright pixel in quadrant')
            if rows.size:
                got_x = x0 + cols.mean()
                got_y = y0 + rows.mean()
                check(f'{size} {name}: marker at ({want_x:.1f},{want_y:.1f})',
                      abs(got_x - want_x) <= 2.5 and abs(got_y - want_y) <= 2.5,
                      f'got ({got_x:.1f},{got_y:.1f})')

    # 3. The output is the canvas and a pure scale: a horizontal ramp stays a
    #    horizontal ramp (no rotation) and stays monotone (no mirroring).
    ramp = Image.new('RGB', (512, 512))
    ramp.putdata([(x * 255 // 511, x * 255 // 511, x * 255 // 511)
                  for y in range(512) for x in range(512)])
    out, _ = crop_and_resize(ramp)
    row = np.asarray(out)[OUT_HEIGHT // 2, :, 0].astype(int)
    check('ramp is monotone along x', np.all(np.diff(row) >= 0), f'{row[:4]}..{row[-4:]}')
    column = np.asarray(out)[:, OUT_WIDTH // 2, 0].astype(int)
    check('ramp is constant along y', column.max() - column.min() <= 1,
          f'spread {column.max() - column.min()}')

    # 4. A too-small source is refused rather than silently producing a wrong crop.
    for size in ((15, 9), (9, 15), (0, 0)):
        try:
            window_box(*size)
            check(f'{size} refused', False, 'no exception')
        except (ValueError, ZeroDivisionError):
            check(f'{size} refused', True)

    # 5. The stored canvas needs no further resampling in training: the pipeline's
    #    own preprocess_image must report the canvas with zero padding.
    sys.path.insert(0, str(PROJECT / 'ml'))
    from src.preprocess import preprocess_image
    from src.spec import load_config
    spec = load_config(str(PROJECT / 'ml' / 'configs' / 'gpos_v1.json'))
    from PIL import Image as PILImage
    probe = PILImage.new('RGB', (OUT_WIDTH, OUT_HEIGHT), (10, 200, 30))
    array, geometry = preprocess_image(probe, spec)
    check('pipeline resizes the stored crop to itself',
          geometry['resized_wh'] == [OUT_WIDTH, OUT_HEIGHT]
          and geometry['pad_left_top'] == [0, 0], str(geometry))
    check('pipeline input shape is the canvas',
          array.shape == (3, OUT_HEIGHT, OUT_WIDTH), str(array.shape))

    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        print(f'  [{"ok  " if ok else "FAIL"}] {name}')
    print(f'{passed}/{len(checks)} checks passed')
    return 0 if passed == len(checks) else 1


# ---------------------------------------------------------------------- run

def load_rows(index_path):
    rows = []
    with open(index_path, encoding='utf-8') as handle:
        for line in handle:
            rows.append(json.loads(line))
    return rows


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _worker_init(source_root, dest_root, overwrite):
    _RUN.update(source_root=source_root, dest_root=dest_root, overwrite=overwrite)


def _worker(row):
    """Crop one row. Returns a small dict; never raises for a bad source."""
    from PIL import Image
    relative = row['path']
    source = _RUN['source_root'] / relative
    destination = _RUN['dest_root'] / relative
    result = dict(path=relative, pool=row.get('semantic_pool'), split=row.get('split'),
                  status='ok', source_wh=None)
    try:
        if not source.is_file():
            result['status'] = 'missing_source'
            return result
        if (not _RUN['overwrite'] and destination.is_file()):
            with Image.open(destination) as handle:
                if handle.size == (OUT_WIDTH, OUT_HEIGHT):
                    result['status'] = 'skipped'
                    return result
        destination.parent.mkdir(parents=True, exist_ok=True)
        with Image.open(source) as handle:
            image = handle.convert('RGB')     # as src/data.py does: no EXIF transpose
            result['source_wh'] = list(image.size)
            crop, _ = crop_and_resize(image)
            save_image(crop, destination)
    except Exception as error:                 # noqa: BLE001 - reported, not swallowed
        result['status'] = 'error'
        result['error'] = f'{type(error).__name__}: {error}'
    return result


def run(args):
    source_root, dest_root = args.source, args.dest
    # Guard rails: never write over the source tree, never leave the project dir.
    for path, label in ((source_root, 'source'), (dest_root, 'dest')):
        resolved = path.resolve()
        if not str(resolved).startswith(str(PROJECT)):
            raise SystemExit(f'{label} is outside the project directory: {resolved}')
    if dest_root.resolve() == source_root.resolve():
        raise SystemExit('dest and source are the same directory')
    if str(dest_root.resolve()).startswith(str(source_root.resolve()) + os.sep):
        raise SystemExit('dest is inside the source tree')
    existing = list(dest_root.rglob('*')) if dest_root.exists() else []
    if existing and not args.overwrite and not args.resume:
        raise SystemExit(f'{dest_root} already has {len(existing)} entries; '
                         f'pass --resume to fill gaps or --overwrite to redo')

    rows = load_rows(args.index)
    if args.limit:
        rows = rows[:args.limit]
    print(f'{len(rows):,d} rows from {args.index}', flush=True)
    print(f'source {source_root}\ndest   {dest_root}\nworkers {args.workers} '
          f'resume={args.resume} overwrite={args.overwrite}', flush=True)

    started = time.time()
    statuses, pools, failures, source_sizes = Counter(), Counter(), [], Counter()
    with Pool(args.workers, initializer=_worker_init,
              initargs=(source_root, dest_root, args.overwrite)) as pool:
        for number, result in enumerate(pool.imap_unordered(_worker, rows, chunksize=64), 1):
            statuses[result['status']] += 1
            pools[(result['pool'], result['status'])] += 1
            if result['source_wh']:
                source_sizes[tuple(result['source_wh'])] += 1
            if result['status'] in ('error', 'missing_source'):
                failures.append(result)
            if number % 5000 == 0:
                rate = number / (time.time() - started)
                print(f'  {number:,d}/{len(rows):,d}  {rate:,.0f} img/s  '
                      f'{dict(statuses)}', flush=True)

    manifest = dict(
        tool='tools/crop_16x9.py',
        rule=dict(window='largest centred 16:9 with integer sides',
                  resize='PIL Image.Resampling.BILINEAR',
                  canvas=[OUT_HEIGHT, OUT_WIDTH], jpeg_quality=JPEG_QUALITY,
                  jpeg_subsampling=0),
        index=str(args.index), index_sha256=sha256(args.index),
        source_root=str(source_root), dest_root=str(dest_root),
        rows=len(rows), statuses=dict(statuses), failures=failures[:50],
        source_size_histogram={f'{w}x{h}': count
                               for (w, h), count in source_sizes.most_common()},
        by_pool={f'{pool}:{status}': count
                 for (pool, status), count in sorted(pools.items(), key=lambda x: str(x[0]))},
        seconds=round(time.time() - started, 1),
        interpreter=sys.executable, host=os.uname().nodename,
    )
    dest_root.mkdir(parents=True, exist_ok=True)
    out = dest_root / 'crop_manifest.json'
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n',
                   encoding='utf-8')
    print(f'\n{json.dumps(dict(statuses), ensure_ascii=False)}')
    print(f'manifest -> {out}')
    return 0 if not failures else 1


# ------------------------------------------------------------------- verify

def verify(args):
    import numpy as np
    from PIL import Image

    rows = load_rows(args.index)
    problems, sizes, missing = [], Counter(), []
    for row in rows:
        destination = args.dest / row['path']
        if not destination.is_file():
            missing.append(row['path'])
            continue
        with Image.open(destination) as handle:
            sizes[handle.size] += 1
    print(f'rows {len(rows):,d}  missing {len(missing):,d}  '
          f'sizes {dict(sizes)}')
    if missing:
        problems.append(f'{len(missing)} indexed rows have no crop, first: {missing[:3]}')
    if set(sizes) != {(OUT_WIDTH, OUT_HEIGHT)}:
        problems.append(f'unexpected crop sizes: {dict(sizes)}')

    # Path parity: the destination must mirror the *index*, because the index is
    # what training iterates; the source tree also holds images no version uses
    # (the hand-back directory and the older 16:9 negative tree), and cropping
    # those would only create files nothing reads.
    sources = {p.relative_to(args.source).as_posix()
               for p in args.source.rglob('*')
               if p.suffix.lower() in SOURCE_EXTENSIONS}
    dests = {p.relative_to(args.dest).as_posix()
             for p in args.dest.rglob('*')
             if p.suffix.lower() in SOURCE_EXTENSIONS}
    indexed = {row['path'] for row in rows}
    print(f'source images {len(sources):,d}  indexed rows {len(indexed):,d}  '
          f'dest images {len(dests):,d}')
    if not dests <= sources:
        problems.append(f'{len(dests - sources)} crops have no source counterpart')
    if not indexed <= dests:
        problems.append(f'{len(indexed - dests)} indexed rows were not cropped')
    unindexed = len(sources - indexed)
    if unindexed:
        print(f'{unindexed:,d} source images are in no pool of this index '
              f'(hand-back directory and the older 16:9 negative tree); '
              f'leaving them uncropped is deliberate')

    # Fidelity: how much the JPEG re-encode costs, measured rather than assumed.
    rng = np.random.default_rng(20261016)
    sample = [rows[i] for i in rng.choice(len(rows), size=min(60, len(rows)),
                                          replace=False)]
    psnr = []
    for row in sample:
        with Image.open(args.source / row['path']) as handle:
            crop, _ = crop_and_resize(handle.convert('RGB'))
        buffer = io.BytesIO()
        crop.save(buffer, format='JPEG', quality=JPEG_QUALITY, subsampling=0)
        buffer.seek(0)
        with Image.open(buffer) as reloaded:
            a = np.asarray(crop, dtype=np.float64)
            b = np.asarray(reloaded.convert('RGB'), dtype=np.float64)
        mse = ((a - b) ** 2).mean()
        psnr.append(10 * np.log10(255 ** 2 / mse) if mse > 0 else 99.0)
    psnr = np.array(psnr)
    print(f'JPEG q{JPEG_QUALITY} 4:4:4 round-trip PSNR on {len(psnr)} crops: '
          f'min {psnr.min():.1f} dB  median {np.median(psnr):.1f} dB')
    if psnr.min() < 35:
        problems.append(f'JPEG round-trip PSNR too low: min {psnr.min():.1f} dB')

    report = dict(index=str(args.index), dest=str(args.dest), rows=len(rows),
                  missing=len(missing), sizes={f'{w}x{h}': c for (w, h), c in sizes.items()},
                  source_images=len(sources), indexed_rows=len(indexed),
                  dest_images=len(dests), unindexed_source_images=unindexed,
                  psnr_min=float(psnr.min()), psnr_median=float(np.median(psnr)),
                  problems=problems)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if not problems else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mode', choices=['selftest', 'run', 'verify'], required=True)
    parser.add_argument('--index', type=Path, default=DEFAULT_INDEX)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--dest', type=Path, default=DEFAULT_DEST)
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--limit', type=int, default=0, help='first N rows only')
    parser.add_argument('--resume', action='store_true',
                        help='skip destinations that already have the right size')
    parser.add_argument('--overwrite', action='store_true',
                        help='rewrite everything even if the destination exists')
    args = parser.parse_args()
    if args.mode == 'selftest':
        return selftest()
    if args.mode == 'run':
        return run(args)
    return verify(args)


if __name__ == '__main__':
    sys.exit(main())
