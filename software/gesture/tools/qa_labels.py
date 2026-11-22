"""Quality report for the teacher labels: statistics plus a sheet to look at.

Two things this checks that a summary table cannot:

  * `crop presence implies square presence`. The square contains the crop region,
    so a hand in the crop must also be found in the square. A single violation
    means the two passes are not looking at the same pixels, which is exactly the
    class of bug the crop step was designed to avoid.
  * pictures. The chosen box and the centre are drawn on the crop, including the
    smallest and largest hands, a multi-box frame, and frames where the crop cut
    the hand out of the frame entirely.

Writes only inside the project directory: a JSON report and a PNG sheet.
"""
import argparse
import json
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')


def percentile(values, q):
    values = np.asarray(values, dtype=float)
    return float(np.percentile(values, q)) if values.size else None


def load_jsonl(path):
    with open(path, encoding='utf-8') as handle:
        return [json.loads(line) for line in handle if line.strip()]


def panel(image, title, box=None, centre=None, scale=2):
    """Crop (or square) at `scale`, with the chosen box and centre drawn."""
    from PIL import Image, ImageDraw
    canvas = Image.new('RGB', (256 * scale, 144 * scale + 16), (18, 18, 18))
    shown = image.resize((256 * scale, 144 * scale), Image.Resampling.NEAREST) \
        if image.size == (256, 144) else image.resize((256 * scale, 144 * scale),
                                                      Image.Resampling.BILINEAR)
    canvas.paste(shown, (0, 16))
    draw = ImageDraw.Draw(canvas)
    if box is not None:
        draw.rectangle([box[0] * scale, box[1] * scale + 16,
                        box[2] * scale, box[3] * scale + 16], outline=(0, 255, 0), width=2)
    if centre is not None:
        cx, cy = centre[0] * 256 * scale, centre[1] * 144 * scale + 16
        draw.line([cx - 8, cy, cx + 8, cy], fill=(255, 80, 80), width=2)
        draw.line([cx, cy - 8, cx, cy + 8], fill=(255, 80, 80), width=2)
    draw.text((4, 3), title, fill=(255, 220, 120))
    return canvas


def grid(panels, columns):
    width = max(p.width for p in panels)
    height = max(p.height for p in panels)
    rows = (len(panels) + columns - 1) // columns
    sheet = np.full((rows * height, columns * width, 3), 18, dtype=np.uint8)
    from PIL import Image
    for index, item in enumerate(panels):
        y, x = divmod(index, columns)
        sheet[y * height:y * height + item.height, x * width:x * width + item.width] = \
            np.asarray(item)
    return Image.fromarray(sheet)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--labels', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'labels_teacher.jsonl')
    parser.add_argument('--squares', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'labels_teacher_squares.jsonl')
    parser.add_argument('--crops', type=Path, default=PROJECT / 'datasets_16x9_256x144')
    parser.add_argument('--sources', type=Path, default=PROJECT / 'datasets')
    parser.add_argument('--out-json', type=Path, default=PROJECT / 'tmp' / 'qa_labels.json')
    parser.add_argument('--out-sheet', type=Path, default=PROJECT / 'tmp' / 'qa_labels_sheet.png')
    args = parser.parse_args()

    from PIL import Image

    rows = load_jsonl(args.labels)
    report = dict(labelled=len(rows))
    presence = [r for r in rows if r['presence']]
    no_hand = [r for r in rows if not r['presence']]
    report['presence'] = len(presence)
    report['no_hand'] = len(no_hand)
    report['presence_rate'] = round(len(presence) / len(rows), 6)
    report['n_boxes_histogram'] = dict(Counter(r['n_boxes'] for r in rows).most_common())

    heights = np.array([r['box'][3] - r['box'][1] for r in presence])
    widths = np.array([r['box'][2] - r['box'][0] for r in presence])
    confs = np.array([r['conf'] for r in presence])
    report['hand_height_px'] = {q: percentile(heights, q) for q in (0, 1, 5, 10, 50, 90, 99)}
    report['hand_width_px'] = {q: percentile(widths, q) for q in (0, 1, 5, 10, 50, 90, 99)}
    report['confidence'] = {q: percentile(confs, q) for q in (0, 1, 10, 50, 90, 99)}
    report['hand_height_over_crop_height'] = {
        'median': round(float(np.median(heights)) / 144, 4),
        'p10': round(percentile(heights, 10) / 144, 4)}
    report['hands_below_30px'] = int((heights < 30).sum())
    report['hands_below_30px_share'] = round(float((heights < 30).mean()), 6)

    # A box touching the crop border is a hand the window cut: its centre is the
    # centre of the visible part, not of the whole hand. Worth counting, because
    # the heatmap target inherits that definition.
    clipped = sum(1 for r in presence
                  if r['box'][0] <= 0.5 or r['box'][1] <= 0.5
                  or r['box'][2] >= 255.5 or r['box'][3] >= 143.5)
    report['boxes_touching_crop_border'] = clipped
    report['boxes_touching_crop_border_share'] = round(clipped / max(len(presence), 1), 6)

    by_pool = defaultdict(Counter)
    by_class = defaultdict(Counter)
    for row in rows:
        by_pool[row['semantic_pool']]['presence' if row['presence'] else 'no_hand'] += 1
        by_class[str(row['class_id'])]['presence' if row['presence'] else 'no_hand'] += 1
    report['by_pool'] = {k: dict(v) for k, v in sorted(by_pool.items())}
    report['by_class'] = {k: dict(v) for k, v in sorted(by_class.items())}

    # Centre distribution: a centre that piles up on the frame border would mean
    # boxes running off the crop, which is what a cut-off hand looks like.
    if presence:
        cx = np.array([r['cx'] for r in presence])
        cy = np.array([r['cy'] for r in presence])
        report['centre_histogram_8x8'] = [
            [int((((cx >= c / 8) & (cx < (c + 1) / 8))
                  & ((cy >= r / 8) & (cy < (r + 1) / 8))).sum())
             for c in range(8)] for r in range(8)]
    else:
        report['centre_histogram_8x8'] = None

    small_hand_examples = []
    if args.squares.is_file():
        squares = {r['path']: r for r in load_jsonl(args.squares)}
        joined = [(r, squares[r['path']]) for r in rows if r['path'] in squares]
        square_presence = sum(1 for _, s in joined if s['presence'])
        # The square contains the crop window, so the stronger check is not
        # presence agreement (the two passes pad differently and differ on
        # borderline frames) but geometry: map the square's box through the crop
        # window and compare it with the crop's own box. A wrong window offset or
        # a swapped axis would show up here as a systematic shift.
        both = [(r, s) for r, s in joined if r['presence'] and s['presence']]
        dx, dy, mapped = [], [], []
        for r, s in both:
            left, top, box_w, box_h = window_box_for(tuple(s['source_wh']))
            # Square pixel centre -> window pixel centre -> crop-normalised.
            expected_cx = (s['cx'] * s['source_wh'][0] - left) / box_w
            expected_cy = (s['cy'] * s['source_wh'][1] - top) / box_h
            dx.append(abs(expected_cx - r['cx']) * 256)
            dy.append(abs(expected_cy - r['cy']) * 144)
            mapped.append([r['path'], round(expected_cx - r['cx'], 5),
                           round(expected_cy - r['cy'], 5)])
        violations = [(r['path'], r['presence'], s['presence']) for r, s in joined
                      if r['presence'] and not s['presence']]
        cut = [(r, s) for r, s in joined if s['presence'] and not r['presence']]
        kept = both
        cut_examples = cut
        report['square_sample'] = dict(
            n=len(joined), square_presence=square_presence,
            both_presence=len(both),
            crop_but_not_square=len(violations), violations_examples=violations[:5],
            square_presence_but_crop_lost=len(cut),
            cut_rate=round(len(cut) / max(square_presence, 1), 6),
            geometry_dx_px=dict(max=percentile(dx, 100), p50=percentile(dx, 50),
                                p90=percentile(dx, 90)),
            geometry_dy_px=dict(max=percentile(dy, 100), p50=percentile(dy, 50),
                                p90=percentile(dy, 90)),
            geometry_worst=mapped[:5])
        if kept:
            report['square_sample']['hand_height_px_median_in_crop'] = percentile(
                [r['box'][3] - r['box'][1] for r, _ in kept], 50)
            report['square_sample']['hand_height_px_median_in_square'] = percentile(
                [s['box'][3] - s['box'][1] for _, s in kept], 50)
        small_hand_examples = sorted(kept, key=lambda pair: pair[0]['box'][3] - pair[0]['box'][1])[:6]
        cut_examples = cut

    args.out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n',
                             encoding='utf-8')
    summary = {k: report[k] for k in
               ('labelled', 'presence', 'no_hand', 'presence_rate', 'n_boxes_histogram',
                'hand_height_px', 'hand_width_px', 'confidence',
                'hand_height_over_crop_height', 'hands_below_30px',
                'hands_below_30px_share', 'by_pool')}
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    if 'square_sample' in report:
        print(json.dumps(report['square_sample'], ensure_ascii=False, indent=1))

    # ---- sheet ----
    rng = random.Random(20261016)
    picked = []
    if presence:
        by_height = sorted(presence, key=lambda r: r['box'][3] - r['box'][1])
        picked += [('smallest hand', by_height[0]), ('small hand', by_height[len(by_height) // 100])]
        picked += [('largest hand', by_height[-1])]
        two_box = [r for r in presence if r['n_boxes'] > 1]
        if two_box:
            picked += [('two boxes, largest taken', two_box[0])]
        picked += [('random 1', rng.choice(presence)), ('random 2', rng.choice(presence)),
                   ('random 3', rng.choice(presence)), ('random 4', rng.choice(presence))]
    panels = []
    for title, row in picked:
        with Image.open(args.crops / row['path']) as handle:
            image = handle.convert('RGB')
        panels.append(panel(image, f"{title}  conf {row['conf']:.2f} h={row['box'][3]-row['box'][1]:.0f}px",
                            box=row['box'], centre=(row['cx'], row['cy'])))
    if no_hand:
        row = rng.choice(no_hand)
        with Image.open(args.crops / row['path']) as handle:
            panels.append(panel(handle.convert('RGB'), f"no hand  ({row['semantic_pool']})"))
    sheets = [grid(panels, 3)]
    cut_examples = locals().get('cut_examples', [])
    if small_hand_examples:
        panels = []
        for row, square in small_hand_examples:
            with Image.open(args.crops / row['path']) as handle:
                image = handle.convert('RGB')
            panels.append(panel(image, f"small hand {row['box'][3]-row['box'][1]:.0f}px"
                                      f" (square {square['box'][3]-square['box'][1]:.0f}px)",
                                box=row['box'], centre=(row['cx'], row['cy'])))
        sheets.append(grid(panels, 3))
    if small_hand_examples or (args.squares.is_file() and cut_examples):
        # The crop lost the hand: show the square with its box, then the crop.
        pairs = []
        for row, square in cut_examples[:6]:
            with Image.open(args.sources / row['path']) as handle:
                source = handle.convert('RGB')
            left, top, box_w, box_h = window_box_for(source.size)
            shown = source.resize((256, 144), Image.Resampling.BILINEAR)
            squared = source.resize((256, 256), Image.Resampling.BILINEAR)
            import PIL.ImageDraw as ImageDraw
            draw = ImageDraw.Draw(squared)
            scale_x = 256 / source.size[0]
            scale_y = 256 / source.size[1]
            draw.rectangle([square['box'][0] * scale_x, square['box'][1] * scale_y,
                            square['box'][2] * scale_x, square['box'][3] * scale_y],
                           outline=(0, 255, 0), width=2)
            draw.rectangle([left * scale_x, top * scale_y,
                            (left + box_w) * scale_x, (top + box_h) * scale_y],
                           outline=(90, 160, 255), width=2)
            from PIL import Image as PILImage
            strip = PILImage.new('RGB', (512, 256 + 16), (18, 18, 18))
            strip.paste(squared, (0, 16))
            strip.paste(shown.resize((256, 144)), (256, 16 + 56))
            ImageDraw.Draw(strip).text((4, 3), f"crop lost the hand  {row['path'][:40]}"
                                               f"  (square box {square['conf']:.2f})",
                                       fill=(255, 220, 120))
            pairs.append(strip)
        if pairs:
            width = max(p.width for p in pairs)
            sheet = np.full((sum(p.height for p in pairs), width, 3), 18, dtype=np.uint8)
            y = 0
            for item in pairs:
                sheet[y:y + item.height, :item.width] = np.asarray(item)
                y += item.height
            from PIL import Image as PILImage
            sheets.append(PILImage.fromarray(sheet))

    total_height = sum(s.height for s in sheets)
    width = max(s.width for s in sheets)
    combined = np.full((total_height, width, 3), 18, dtype=np.uint8)
    y = 0
    for s in sheets:
        combined[y:y + s.height, :s.width] = np.asarray(s)
        y += s.height
    Image.fromarray(combined).save(args.out_sheet)
    print(f'sheet -> {args.out_sheet}')


def window_box_for(size):
    """Same rule as tools/crop_16x9.py, re-stated here to keep this tool standalone."""
    width, height = size
    scale = min(width // 16, height // 9)
    box_w, box_h = 16 * scale, 9 * scale
    return (width - box_w) // 2, (height - box_h) // 2, box_w, box_h


if __name__ == '__main__':
    sys.exit(main())
