"""Why is presence AUC below chance? Look at the peaks and at the maps.

Loads a checkpoint from a position run, runs it on a balanced slice of the
validation split, and reports:

  * the peak distribution for frames with a hand and frames without one;
  * the predicted centre against the ground truth centre for the frames with a
    hand (the GT is taken back out of the target map, as the metric does);
  * a PNG: crop, predicted map and target map side by side, with both centres
    marked, so an alignment or normalisation problem is visible rather than
    inferred.

Writes only inside the project directory.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch

PROJECT = Path('/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015')
sys.path.insert(0, str(PROJECT / 'ml'))

from src.data import GestureDataset                      # noqa: E402
from src.index import load_train_config, read_index      # noqa: E402
from src.position import peak_and_centre                 # noqa: E402
from src.train import load_model_from_checkpoint         # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--index', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144' / 'index_gpos.jsonl')
    parser.add_argument('--data-root', type=Path,
                        default=PROJECT / 'datasets_16x9_256x144')
    parser.add_argument('--config', type=Path,
                        default=PROJECT / 'ml' / 'configs' / 'gpos_v1_train.json')
    parser.add_argument('--per-group', type=int, default=120)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--sheet', type=Path,
                        default=PROJECT / 'tmp' / 'gpos_diagnostic.png')
    parser.add_argument('--jitter', type=int, default=0,
                        help='measure prediction spread over N hand frames under '
                             'near-identical inputs (shifts and brightness)')
    args = parser.parse_args()

    device = torch.device(args.device)
    if not torch.cuda.is_available():
        raise SystemExit('CUDA required')
    spec = load_train_config(args.config)
    rows = [row for row in read_index(args.index) if row['split'] == 'val']
    with_hand = [row for row in rows if row['hand_presence']][:args.per_group]
    without = [row for row in rows if not row['hand_presence']][:args.per_group]
    print(f'val rows {len(rows):,d}; using {len(with_hand)} with a hand and '
          f'{len(without)} without')

    model, step, _, _ = load_model_from_checkpoint(args.checkpoint, device)
    model.eval()
    model_config = PROJECT / 'ml' / 'configs' / 'gpos_v1.json'
    dataset = GestureDataset(with_hand + without, args.data_root, spec, train=False,
                             model_config=model_config)

    peaks, centres, truths, crops, maps, targets = [], [], [], [], [], []
    for index in range(len(dataset)):
        image, _, _, target = dataset[index]
        with torch.inference_mode():
            output = model(image.unsqueeze(0).to(device))
        peak, centre = peak_and_centre(output)
        peaks.append(peak[0])
        centres.append(centre[0])
        truths.append(target[0].numpy())
        crops.append(image)
        maps.append(np.asarray(output[0, 0].float().cpu()))
        targets.append(np.asarray(target[0]))
    peaks = np.array(peaks)
    centres = np.array(centres)
    n_hand = len(with_hand)
    print(f'step {step}')
    print(f'peak  with hand: mean {peaks[:n_hand].mean():.4f} median '
          f'{np.median(peaks[:n_hand]):.4f} p90 {np.percentile(peaks[:n_hand], 90):.4f}')
    print(f'peak without   : mean {peaks[n_hand:].mean():.4f} median '
          f'{np.median(peaks[n_hand:]):.4f} p90 {np.percentile(peaks[n_hand:], 90):.4f}')
    print(f'sigmoid of the logits: logit range {min(m.min() for m in maps):.2f} .. '
          f'{max(m.max() for m in maps):.2f}')

    def target_centre(target):
        rows_n, cols_n = target.shape[-2:]
        weights = np.asarray(target)
        total = weights.sum()
        if total <= 0:
            return None
        xs = (np.arange(cols_n) + 0.5) / cols_n
        ys = (np.arange(rows_n) + 0.5) / rows_n
        return ((weights.sum(axis=0) * xs).sum() / total,
                (weights.sum(axis=1) * ys).sum() / total)

    errors = []
    for index in range(n_hand):
        truth = target_centre(truths[index])
        if truth is None:
            continue
        errors.append(np.array([(centres[index, 0] - truth[0]) * 256,
                                (centres[index, 1] - truth[1]) * 144]))
    errors = np.array(errors)
    print(f'centre error over {len(errors)} hand frames: '
          f'x {errors[:, 0].mean():+.1f} +- {errors[:, 0].std():.1f} px  '
          f'y {errors[:, 1].mean():+.1f} +- {errors[:, 1].std():.1f} px '
          f'(canvas 256x144)')

    # Yes/no separation on this balanced slice: how far apart are the peaks?
    print(f'balanced slice AUC: '
          f'{_auc(peaks, np.array([True] * n_hand + [False] * len(without))):.4f}')

    # ---- sheet: crop | predicted probability map | target, first 6 hand frames
    if args.jitter:
        # A swipe state machine thresholds velocity, so what decides whether this
        # model is usable is not the absolute error but how much the predicted
        # centre moves when the input barely changes. Static images can stand in
        # for that: shift the crop by a pixel and nudge the brightness, which is
        # what consecutive video frames of a still hand look like.
        from PIL import Image as PILImage
        import torch.nn.functional as F
        spreads = []
        for index in range(min(args.jitter, n_hand)):
            image = crops[index].unsqueeze(0)
            variants = [image]
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                variants.append(torch.roll(image, shifts=(dy, dx), dims=(2, 3)))
            for scale in (0.97, 1.03):
                variants.append((image * scale).clamp(-1, 1))
            variant_centres = []
            for variant in variants:
                with torch.inference_mode():
                    peak, centre = peak_and_centre(model(variant.to(device)))
                if peak[0] < 0.2:
                    continue
                variant_centres.append(centre[0])
            if len(variant_centres) >= 4:
                variant_centres = np.array(variant_centres)
                spreads.append((variant_centres[:, 0].std() * 256,
                                variant_centres[:, 1].std() * 144))
        if spreads:
            spreads = np.array(spreads)
            print(f'jitter proxy over {len(spreads)} still-hand frames (7 near-copies each): '
                  f'x std {spreads[:, 0].mean():.2f} px (p90 {np.percentile(spreads[:, 0], 90):.2f})  '
                  f'y std {spreads[:, 1].mean():.2f} px (p90 {np.percentile(spreads[:, 1], 90):.2f}) '
                  f'in canvas px -> x {spreads[:, 0].mean() * 5:.1f} / '
                  f'y {spreads[:, 1].mean() * 5:.1f} px in a 720p frame')

    from PIL import Image, ImageDraw
    panels = []
    for index in list(range(6)) + [n_hand, n_hand + 1]:
        crop = (crops[index].permute(1, 2, 0).numpy() * 128 + 128).clip(0, 255)
        crop = Image.fromarray(crop.astype(np.uint8)).resize((256 * 2, 144 * 2),
                                                            Image.Resampling.NEAREST)
        probability = 1 / (1 + np.exp(-maps[index]))
        grown = Image.fromarray((probability * 255).astype(np.uint8)).resize(
            (256 * 2, 144 * 2), Image.Resampling.NEAREST)
        target = Image.fromarray((targets[index] * 255).astype(np.uint8)).resize(
            (256 * 2, 144 * 2), Image.Resampling.NEAREST)
        strip = Image.new('RGB', (256 * 2 * 3 + 8, 144 * 2 + 16), (18, 18, 18))
        strip.paste(crop, (0, 16))
        strip.paste(grown, (256 * 2 + 4, 16))
        strip.paste(target, (256 * 4 + 8, 16))
        draw = ImageDraw.Draw(strip)
        truth = target_centre(truths[index])
        label = (f"{'hand' if index < n_hand else 'no hand'}  peak {peaks[index]:.3f}"
                 f"  pred ({centres[index, 0]:.3f},{centres[index, 1]:.3f})"
                 + (f"  gt ({truth[0]:.3f},{truth[1]:.3f})" if truth else ''))
        draw.text((4, 2), label, fill=(255, 220, 120))
        for offset, point in ((0, (centres[index, 0], centres[index, 1])),
                              (256 * 2 + 4, (centres[index, 0], centres[index, 1]))):
            if point[0] is None:
                continue
            x = offset + point[0] * 256 * 2
            y = 16 + point[1] * 144 * 2
            draw.line([x - 8, y, x + 8, y], fill=(255, 80, 80), width=2)
            draw.line([x, y - 8, x, y + 8], fill=(255, 80, 80), width=2)
        if truth:
            for offset in (0, 256 * 2 + 4, 256 * 4 + 8):
                x = offset + truth[0] * 256 * 2
                y = 16 + truth[1] * 144 * 2
                draw.line([x - 8, y, x + 8, y], fill=(80, 255, 120), width=2)
                draw.line([x, y - 8, x, y + 8], fill=(80, 255, 120), width=2)
        panels.append(strip)
    sheet = np.full((sum(p.height for p in panels), max(p.width for p in panels), 3),
                    18, dtype=np.uint8)
    y = 0
    for panel in panels:
        sheet[y:y + panel.height, :panel.width] = np.asarray(panel)
        y += panel.height
    args.sheet.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(sheet).save(args.sheet)
    print(f'sheet -> {args.sheet}')
    return 0


def _auc(scores, labels):
    scores = np.asarray(scores, dtype=np.float64)
    labels = np.asarray(labels, dtype=bool)
    positives, negatives = int(labels.sum()), int((~labels).sum())
    order = np.argsort(scores, kind='mergesort')
    ranks = np.empty(len(scores))
    ranks[order] = np.arange(1, len(scores) + 1)
    sorted_scores = scores[order]
    start = 0
    for index in range(1, len(sorted_scores) + 1):
        if index == len(sorted_scores) or sorted_scores[index] != sorted_scores[start]:
            if index - start > 1:
                ranks[order[start:index]] = ranks[order[start:index]].mean()
            start = index
    return float((ranks[labels].sum() - positives * (positives + 1) / 2)
                 / (positives * negatives))


if __name__ == '__main__':
    sys.exit(main())
