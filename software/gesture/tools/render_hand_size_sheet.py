"""Render model-input tiles grouped by hand size, for a by-eye threshold choice.

Each tile is exactly what the model receives: the source image resized into the
model input at native resolution, with no augmentation and no upscaling. A hand
that looks unreadable here is unreadable to the model as well.

Rows are hand-area bins, labelled with the area fraction and the hand's linear
size inside the model input. Gesture labels are deliberately not shown, so the
judgement is what a viewer can actually tell apart.

Run from the repository root:
  python gesture/tools/render_hand_size_sheet.py
"""
import argparse
import json
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.preprocess import preprocess_image  # noqa: E402
from src.spec import DEFAULT_CONFIG, load_config  # noqa: E402

BINS = [(0.000, 0.010), (0.010, 0.020), (0.020, 0.030), (0.030, 0.050),
        (0.050, 0.080), (0.080, 0.150), (0.150, 1.000)]
PER_ROW = 8
LABEL_W = 190
# Tile size comes from the model spec at run time: a tile is one model input
# pasted at native pixels, so hardcoding it would mis-tile another geometry.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--table', type=Path,
                        default=GESTURE.parent / 'tmp' / 'hand_sizes.jsonl')
    parser.add_argument('--data-root', type=Path, default=GESTURE / 'dataset')
    parser.add_argument('--out', type=Path,
                        default=GESTURE.parent / 'tmp' / 'hand_size_sheet.png')
    parser.add_argument('--seed', type=int, default=20261015)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG,
                        help='model spec; its input size is what the tiles are')
    args = parser.parse_args()

    # The tile size and the "hand ~N px" labels are both in model-input pixels, so
    # they follow the geometry of the model being inspected, not a constant.
    model_spec = load_config(args.config)
    input_height = model_spec['input']['height']
    input_width = model_spec['input']['width']
    print(f'model input {input_width}x{input_height} ({args.config.name})')
    TILE_W, TILE_H = input_width, input_height

    rows = [json.loads(line) for line
            in args.table.read_text(encoding='utf-8').splitlines() if line.strip()]
    usable = [row for row in rows if row['area_max'] is not None]
    print(f'{len(rows):,d} rows, {len(usable):,d} with a detected hand')

    rng = random.Random(args.seed)
    try:
        font = ImageFont.load_default(size=13)
        small = ImageFont.load_default(size=11)
    except TypeError:  # Pillow < 10.1
        font = small = ImageFont.load_default()

    sheet = Image.new('RGB', (LABEL_W + PER_ROW * TILE_W,
                              len(BINS) * TILE_H), (18, 18, 18))
    draw = ImageDraw.Draw(sheet)

    for row_index, (low, high) in enumerate(BINS):
        members = [row for row in usable if low <= row['area_max'] < high]
        members.sort(key=lambda row: row['area_max'])
        if len(members) > PER_ROW:
            step = len(members) / PER_ROW
            members = [members[int(i * step)] for i in range(PER_ROW)]
        top = row_index * TILE_H
        mid = (low + high) / 2 if high < 1 else max(row['area_max'] for row in usable)
        label = f'{low:.3f}-{high:.3f}' if high < 1 else f'{low:.3f}+'
        draw.text((10, top + 22), label, fill=(235, 235, 235), font=font)
        draw.text((10, top + 42), f'hand ~{mid ** 0.5 * input_height:4.0f} px',
                  fill=(150, 220, 150), font=small)
        draw.text((10, top + 58), f'in {input_width}x{input_height}',
                  fill=(150, 220, 150), font=small)
        draw.text((10, top + 82), f'n={len([r for r in usable if low <= r["area_max"] < high]):,d}',
                  fill=(150, 150, 150), font=small)
        for column, row in enumerate(members):
            with Image.open(args.data_root / row['path']) as handle:
                source = handle.convert('RGB')
                array, _ = preprocess_image(source, args.config)
            # Undo the (pixel - 128) / 128 contract to recover the uint8 canvas.
            pixels = ((array.transpose(1, 2, 0) * 128.0) + 128.0).round()
            pixels = pixels.clip(0, 255).astype('uint8')
            sheet.paste(Image.fromarray(pixels, 'RGB'),
                        (LABEL_W + column * TILE_W, top))
            if column:
                draw.line([(LABEL_W + column * TILE_W, top),
                           (LABEL_W + column * TILE_W, top + TILE_H)],
                          fill=(60, 60, 60))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print(f'wrote {args.out}  {sheet.size}')
    print('rows top to bottom: ' + ', '.join(
        f'{low:.3f}-{high:.3f}' if high < 1 else f'{low:.3f}+' for low, high in BINS))
    print(f'each tile is the raw {input_width}x{input_height} model input, '
          f'native pixels, no upscaling')


if __name__ == '__main__':
    main()
