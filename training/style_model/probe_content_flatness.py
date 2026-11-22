"""Is the corridor wall inside the flatness range the training content covers?

The wall's activity -- the blurred Sobel magnitude the smooth-region mask uses --
measures 1e-5 to 1e-4, an order of magnitude below the sky band (0.019) that every
earlier detail metric watched.  The stroke-contrast target is measured on the
flattest 30 percent of each training crop, so if no training crop contains content
that flat, the target never constrains the regime the wall lives in.

This reports the training content's own distribution of that statistic, and what
the candidate augmentation (blurring the content) would do to it, so the two can be
put on the same number line.  The statistic is computed with torch and the trainer's
own ``blur``, so it is the same number the loss sees.

Usage (server):
  python probe_content_flatness.py --sample 512 --archive 64 --out DIR
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image

DATASET = Path("/data1/fpga_style_transfer_2026_tmp/datasets/main_256/images")
METHOD = Path(__file__).resolve().parent
sys.path.insert(0, str(METHOD))
from distill_texture import blur, luma  # noqa: E402

MARGIN = 16
BLUR_SIGMAS = (4.0, 8.0, 12.0, 16.0)
SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".bmp")


def activity(image: torch.Tensor) -> torch.Tensor:
    """The trainer's smoothness statistic: blurred Sobel magnitude, borders cut."""
    gray = luma(image)
    kernel = torch.tensor([-0.5, 0.0, 0.5], dtype=gray.dtype).view(1, 1, 3, 1)
    dy = torch.nn.functional.conv2d(
        torch.nn.functional.pad(gray, (0, 0, 1, 1), mode="reflect"), kernel)
    dx = torch.nn.functional.conv2d(
        torch.nn.functional.pad(gray, (1, 1, 0, 0), mode="reflect"),
        kernel.view(1, 1, 1, 3))
    blurred = blur((dy * dy + dx * dx).sqrt(), 3.0)
    return blurred[..., MARGIN:-MARGIN, MARGIN:-MARGIN]


def statistics(field: torch.Tensor, keep: float = 0.30) -> dict:
    flat = field.flatten().sort().values
    count = max(1, int(keep * flat.numel()))
    return {"mean": float(flat.mean()),
            "flat30": float(flat[:count].mean()),
            "min": float(flat[0])}


def load(path: Path) -> torch.Tensor:
    with Image.open(path) as handle:
        array = np.asarray(handle.convert("RGB"), dtype=np.float32) / 255.0
    return torch.from_numpy(array).permute(2, 0, 1)[None]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", type=int, default=512)
    parser.add_argument("--archive", type=int, default=64)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    files = sorted(p for p in DATASET.iterdir() if p.suffix.lower() in SUFFIXES)
    print(f"{len(files)} files in {DATASET}")
    rng = np.random.default_rng(20260923)
    picks = np.sort(rng.choice(len(files), size=min(args.sample, len(files)),
                               replace=False))

    rows = []
    for index in picks:
        image = load(files[index])
        entry = {"file": files[index].name,
                 "size": [int(image.shape[-1]), int(image.shape[-2])]}
        entry["raw"] = statistics(activity(image))
        for sigma in BLUR_SIGMAS:
            smooth = blur(image, sigma)
            entry[f"blur{int(sigma)}"] = statistics(activity(smooth))
        rows.append(entry)

    print(f"\n{'variant':>10s} {'flat30 p5':>11s} {'p25':>10s} {'median':>10s} "
          f"{'p75':>10s} {'p95':>10s} {'mean of means':>14s}")
    for key in ("raw",) + tuple(f"blur{int(s)}" for s in BLUR_SIGMAS):
        flats = np.array([row[key]["flat30"] for row in rows])
        means = np.array([row[key]["mean"] for row in rows])
        print(f"{key:>10s} {np.percentile(flats, 5):11.6f} {np.percentile(flats, 25):10.6f} "
              f"{np.percentile(flats, 50):10.6f} {np.percentile(flats, 75):10.6f} "
              f"{np.percentile(flats, 95):10.6f} {means.mean():14.6f}")
    minima = np.array([row["raw"]["min"] for row in rows])
    print(f"\nraw per-crop minimum pixel activity: median {np.median(minima):.7f}, "
          f"p5 {np.percentile(minima, 5):.7f}, min {minima.min():.7f}")
    print("reference: corridor wall 1e-5..1e-4, sky band 0.019")

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "content_flatness.json").write_text(json.dumps(rows, indent=1),
                                                   encoding="utf-8")
    keep = np.sort(rng.choice(len(rows), size=min(args.archive, len(rows)), replace=False))
    stack = []
    for index in keep:
        with Image.open(DATASET / rows[index]["file"]) as handle:
            stack.append(np.asarray(handle.convert("RGB"), dtype=np.uint8))
    np.save(args.out / "content_sample.npy", np.stack(stack))
    (args.out / "content_sample_files.json").write_text(
        json.dumps([rows[i]["file"] for i in keep], indent=1), encoding="utf-8")
    print(f"\nwrote {args.out}/content_flatness.json and content_sample.npy "
          f"({len(keep)} crops)")


if __name__ == "__main__":
    main()
