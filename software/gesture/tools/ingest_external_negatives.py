"""Derive `other`-class negatives from the style-transfer image corpora.

Read-only against the style-transfer datasets: source images are opened and
never modified, moved or deleted. Each source image yields one centred square
crop, resized so its side is at most --long-side, written as JPEG into our own
data root under external_negatives/<source>/.

The crop is square because every other training image is: the gesture sets are
square hand crops, and the model input is square, so a 16:9 negative would be the
only sample in the batch needing a letterbox. Cropping a square out of the native
frame keeps the whole height instead of discarding 44% of an already-cropped
16:9 derivative, so re-cropping from native costs nothing.

Crops are taken from the native-resolution `source/` trees rather than from the
256x256 `main_256` derivative, so no sample is downsampled twice and the stored
crop keeps headroom for the geometric augmentation.

Run on the training server:

  python tools/ingest_external_negatives.py \
      --style-root /data1/fpga_style_transfer_2026_tmp/datasets \
      --out        /data1/.../gesture_four_class_20261015/datasets
"""
import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

IMAGE_EXTS = ('.jpeg', '.jpg', '.png', '.bmp', '.webp')
SOURCES = (
    ('coco', 'coco20k/source'),
    ('div2k', 'div2k/source/DIV2K_train_HR'),
    ('flickr2k', 'flickr2k/source'),
)


def centred_square(image):
    """Largest centred square that fits inside the image."""
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def cap_long_side(image, long_side):
    width, height = image.size
    scale = min(1.0, long_side / max(width, height))
    if scale >= 1.0:
        return image
    return image.resize((max(1, round(width * scale)), max(1, round(height * scale))),
                        Image.Resampling.BILINEAR)


def convert_one(task):
    source_path, out_path, long_side, quality = task
    try:
        with Image.open(source_path) as handle:
            image = handle.convert('RGB')
            crop = cap_long_side(centred_square(image), long_side)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            crop.save(out_path, format='JPEG', quality=quality, subsampling=0)
        return True, None
    except Exception as error:  # noqa: BLE001 - reported, not swallowed
        return False, f'{source_path}: {error}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--style-root', type=Path, required=True,
                        help='style-transfer datasets directory (read-only)')
    parser.add_argument('--out', type=Path, required=True,
                        help='our data root; crops go to external_negatives/<source>/')
    parser.add_argument('--long-side', type=int, default=512,
                        help='cap on the square side; the model input is square '
                             'and smaller, so this leaves headroom for the '
                             'geometric augmentation')
    parser.add_argument('--quality', type=int, default=95)
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--limit', type=int, default=0,
                        help='max images per source, 0 = all')
    args = parser.parse_args()

    destination_root = args.out / 'external_negatives'
    tasks, summary = [], {}
    for name, relative in SOURCES:
        root = args.style_root / relative
        if not root.is_dir():
            raise SystemExit(f'missing source directory: {root}')
        files = sorted(p for p in root.rglob('*')
                       if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
        if args.limit:
            files = files[:args.limit]
        if not files:
            raise SystemExit(f'no images under {root}')
        out_dir = destination_root / name
        for path in files:
            tasks.append((path, out_dir / f'{path.stem}.jpg', args.long_side,
                          args.quality))
        summary[name] = dict(source_dir=str(root), images=len(files),
                             out_dir=str(out_dir))
        print(f'{name:<9s} {len(files):>7d} images  <- {root}', flush=True)

    print(f'\nconverting {len(tasks)} images with {args.workers} workers', flush=True)
    started = time.time()
    failures, done = [], 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for ok, error in pool.map(convert_one, tasks):
            done += 1
            if not ok:
                failures.append(error)
            if done % 5000 == 0:
                print(f'  {done}/{len(tasks)}  {time.time() - started:.0f}s', flush=True)

    summary['failures'] = failures
    summary['total'] = len(tasks) - len(failures)
    summary['long_side_cap'] = args.long_side
    summary['crop'] = 'centred square from native resolution, no padding, no stretch'
    summary['seconds'] = round(time.time() - started, 1)
    destination_root.mkdir(parents=True, exist_ok=True)
    (destination_root / 'ingest_summary.json').write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    print(f'\nwrote {summary["total"]} crops, {len(failures)} failures, '
          f'{summary["seconds"]}s')
    for name, block in summary.items():
        if isinstance(block, dict):
            print(f'  {name:<9s} {block["images"]:>7d} -> {block["out_dir"]}')
    if failures:
        print('first failures:')
        for line in failures[:5]:
            print(f'  {line}')
    print(f'wrote {destination_root / "ingest_summary.json"}')


if __name__ == '__main__':
    main()
