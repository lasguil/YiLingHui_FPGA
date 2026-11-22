"""Measure the brushstroke metric of checkpoints against the v1 teacher.

The metric is the one that separates the reference from every half-size
candidate: absolute fine-scale contrast in the sky of the fixed landscape frame,
at three scales, plus the phase-tolerant texture distance to the teacher.  It is
what the distillation is supposed to move, so it is the number to read while a
run is in progress -- a falling training loss means nothing on its own.

Examples
--------
python measure_stroke_metric.py --checkpoint runs/v2e_tex/checkpoints/step_025000.pt
python measure_stroke_metric.py --run-dir runs/v2e_tex --every 1000
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image, ImageOps

from settings import HERE, METHOD, STYLE
sys.path.insert(0, str(HERE))
from distill_texture import (TextureDescriptor, chroma_loss, low_frequency_loss,  # noqa: E402
                             _hann2d, colour_distribution,
                             colour_reference_from_file, luma,
                             orientation_flow, patch_self_similarity,
                             sliced_wasserstein_style_loss, spectral_entropy,
                             stroke_band, style_directions, style_tensor_from_file,
                             local_gram_distance, local_gram_descriptors,
                             texture_stat_loss, to_luma_image)
from model import NativeGroupMixNet  # noqa: E402
from model_v2de import EXPERIMENTS, build_v2de  # noqa: E402
from perceptual import Perceptual  # noqa: E402

VGG_FEATURES = (METHOD / "quarter_vgg_local_20260904/vgg19_imagenet_features.pt")
JUDGE_STATE = METHOD.parent / "runs/v1_discriminator_step020000.pt"
FROZEN_JUDGE = None

# Same layout rule as common.py: the project root holds tmp/, the students root
# holds runs/.
PROJECT = METHOD.parent.parents[1]
EVAL = PROJECT / "tmp/IMG_20250712_073503.jpg"
SIZES = ((640, 480), (256, 256))
SKY_SPAN = (0.08, 0.42, 0.10, 0.90)
SCALES = (1.0, 2.0, 4.0)


def load_frame(path, width, height):
    with Image.open(path) as image:
        image = ImageOps.exif_transpose(image).convert("RGB")
    fitted = ImageOps.fit(image, (width, height), method=Image.Resampling.BILINEAR)
    return torch.from_numpy(np.array(fitted, dtype=np.float32) / 255.0
                            ).permute(2, 0, 1)[None]


@torch.inference_mode()
def band_energies(model, frame):
    """Absolute band-pass contrast in the sky, the number the strokes live in."""
    output = model(frame)
    gray = (output * output.new_tensor([0.299, 0.587, 0.114])[None, :, None, None]).sum(1)
    height, width = gray.shape[-2:]
    region = gray[..., int(height * SKY_SPAN[0]):int(height * SKY_SPAN[1]),
                  int(width * SKY_SPAN[2]):int(width * SKY_SPAN[3])]
    result = {}
    for sigma in SCALES:
        radius = int(3 * sigma)
        axis = torch.arange(-radius, radius + 1, dtype=gray.dtype, device=gray.device)
        kernel = torch.exp(-axis ** 2 / (2 * sigma ** 2))
        vertical = (kernel / kernel.sum()).view(1, 1, -1, 1)
        blurred = F.conv2d(F.pad(region.unsqueeze(1), (0, 0, radius, radius),
                                 mode="reflect"), vertical)
        horizontal = vertical.view(1, 1, 1, -1)
        blurred = F.conv2d(F.pad(blurred, (radius, radius, 0, 0), mode="reflect"),
                           horizontal)
        margin = min(radius, min(region.shape[-2:]) // 4)
        core = slice(margin, -margin)
        result[f"sigma{int(sigma)}"] = round(
            float((region.unsqueeze(1) - blurred)[..., core, core].std()), 6)
    return result


def _gaussian(sigma, dtype, device):
    radius = int(3 * sigma)
    axis = torch.arange(-radius, radius + 1, dtype=dtype, device=device)
    kernel = torch.exp(-axis ** 2 / (2 * sigma ** 2))
    return kernel / kernel.sum()


def _blur(x, kernel):
    radius = (kernel.numel() - 1) // 2
    channels = x.shape[1]
    vertical = kernel.view(1, 1, -1, 1).expand(channels, 1, -1, 1)
    x = F.conv2d(F.pad(x, (0, 0, radius, radius), mode="reflect"), vertical,
                 groups=channels)
    horizontal = kernel.view(1, 1, 1, -1).expand(channels, 1, 1, -1)
    return F.conv2d(F.pad(x, (radius, radius, 0, 0), mode="reflect"), horizontal,
                    groups=channels)


@torch.inference_mode()
def spectral_shape(model, frame):
    """How concentrated the stroke band's spectrum is.

    This is the number for the failure the eye named as repeated texture: a
    periodic pattern puts the same energy and orientation into the band as an
    irregular one, so only the spectral concentration separates them.  The
    reference measures 5.73 entropy and 404 peak-to-mean on the demo frames, v2e
    measures 5.44 and 474, and AESPA and the painting both measure higher entropy
    than the reference.
    """
    band = stroke_band(luma(model(frame)))
    height, width = band.shape[-2:]
    window = _hann2d(height, width, band.dtype, band.device)
    spectrum = torch.fft.fftshift(
        torch.fft.fft2(band * window[None, None]), dim=(-2, -1)
    ).abs() ** 2
    cy, cx = height // 2, width // 2
    ky = (torch.arange(height, dtype=band.dtype, device=band.device) - cy)[:, None] / height
    kx = (torch.arange(width, dtype=band.dtype, device=band.device) - cx)[None, :] / width
    radius = torch.sqrt(ky ** 2 + kx ** 2)
    mask = (radius >= 0.09) & (radius <= 0.45)
    values = spectrum[..., mask]
    probability = values / (values.sum(dim=-1, keepdim=True) + 1e-12)
    entropy = -(probability * (probability + 1e-12).log()).sum(dim=-1).mean()
    peak = (values.max(dim=-1).values / (values.mean(dim=-1) + 1e-12)).mean()
    return {"spectral_entropy": round(float(entropy), 4),
            "spectral_peak": round(float(peak), 2)}


@torch.inference_mode()
def colour_accent(model, frame):
    """The warm accent and the overall chroma of the sky, which strokes sit in.

    "Colours look flatter and there is less yellow" is a statement about the
    accent, and a mean-absolute colour error can improve while the accent fades,
    because the accent covers about one percent of the sky.  So this reports the
    accent's own amplitude at its own scale, next to the mean chroma and the
    spatial spread of yellowness.
    """
    output = model(frame)
    height, width = output.shape[-2:]
    sky = output[..., int(height * SKY_SPAN[0]):int(height * SKY_SPAN[1]),
                 int(width * SKY_SPAN[2]):int(width * SKY_SPAN[3])]
    red, green, blue = sky[:, 0], sky[:, 1], sky[:, 2]
    yellowness = (red + green) / 2 - blue
    chroma = sky.max(dim=1).values - sky.min(dim=1).values
    kernel = _gaussian(8.0, sky.dtype, sky.device)
    accent = _blur(yellowness.unsqueeze(1), kernel).squeeze(1)
    margin = int(3 * 8)
    core = accent[..., margin:-margin, margin:-margin]
    return {"accent_peak": round(float(core.max()), 5),
            "accent_span": round(0.5 * float(core.max() - core.min()), 5),
            "chroma_mean": round(float(chroma.mean()), 5),
            "yellowness_std": round(float(yellowness.std()), 5)}


@torch.inference_mode()
def _gram(feature):
    batch, channels, height, width = feature.shape
    flat = feature.flatten(2)
    return torch.bmm(flat, flat.transpose(1, 2)) / (channels * height * width)


def describe(model, teacher, descriptor, frames, colour_reference=None,
             judge=None, painting_features=None, painting_directions=None,
             painting_luma_features=None, luma_directions=None,
             painting_localgram=None, judge_for_localgram=None):
    entry = {}
    for (width, height), frame in frames.items():
        student = model(frame)
        reference = teacher(frame)
        for sigma, value in band_energies(model, frame).items():
            entry[f"student_{width}_{sigma}"] = value
        for sigma, value in band_energies(teacher, frame).items():
            entry[f"teacher_{width}_{sigma}"] = value
        entry[f"texture_loss_{width}"] = round(float(
            texture_stat_loss(descriptor, student, reference)), 5)
        entry[f"low_loss_{width}"] = round(float(
            low_frequency_loss(student, reference)), 5)
        # The accent term is scored on the smooth part of the content, so the
        # frame itself is the content here.
        entry[f"chroma_loss_{width}"] = round(float(
            chroma_loss(student, reference, frame)), 5)
        entry.update({f"student_{k}": v for k, v in spectral_shape(model, frame).items()})
        entry.update({f"teacher_{k}": v for k, v in spectral_shape(teacher, frame).items()})
        if width == 640:
            # The statistic that tracks the reported "repeated texture": the mean
            # cosine similarity of each stroke-band patch to its best match
            # elsewhere in the frame.  Teacher 0.726, v2e 0.785 on the demo frames.
            with torch.no_grad():
                entry["student_repetition"] = round(
                    float(patch_self_similarity(student)), 4)
                entry["teacher_repetition"] = round(
                    float(patch_self_similarity(reference)), 4)
        # The VGG judgement that matches the eye's ordering: sliced Wasserstein
        # between the output's feature cloud and the painting's.  AESPA measures
        # 0.756 against the painting, the reference generator 0.793, and the
        # un-distilled students above 0.92.
        if width == 256 and painting_features is not None:
            # The classic Gram style distance to the painting: the metric on which
            # the reference generator leads every small model by the largest margin
            # (0.000013 against 0.000017-0.000020, i.e. about 32%).
            entry["gram_to_painting"] = round(float(torch.stack([
                F.mse_loss(_gram(a), _gram(b))
                for a, b in zip(judge.extract(student), painting_features)]).mean()), 8)
            # Scored at 256x256: the size the painting's own features are taken at,
            # so the comparison is at one stroke scale.  AESPA measures 0.7555 here,
            # the reference generator 0.7932, r7 0.8932, v2e@13k 0.9251.
            # The metric whose ordering matches the eye: local Grams compared as a
            # distribution.  AESPA 0.221 < reference 0.263 << small models 0.304-0.327.
            if FROZEN_JUDGE is not None:
                entry["judge_score"] = round(float(FROZEN_JUDGE(student).mean()), 4)
            entry["local_gram"] = round(float(local_gram_distance(
                judge_for_localgram.extract(student)[2], painting_localgram)), 4)
            entry["vgg_swd"] = round(float(sliced_wasserstein_style_loss(
                judge.extract(student), painting_features, painting_directions)), 5)
            entry["vgg_swd_luma"] = round(float(sliced_wasserstein_style_loss(
                judge.extract(to_luma_image(student)), painting_luma_features,
                luma_directions)), 5)
        # Orientation continuity: how much of the local stroke direction survives
        # to 32px.  The reference measures 0.651 and both earlier students 0.520,
        # which is the user's "the reference's strokes are continuous like brushwork
        # while this texture has no regularity".
        entry[f"student_flow32_{width}"] = round(float(orientation_flow(student)[-1]), 4)
        entry[f"teacher_flow32_{width}"] = round(float(orientation_flow(reference)[-1]), 4)
        if colour_reference is not None:
            # The colour *proportion*: where the mass of the opponent plane sits,
            # against the painting's own distribution.  This is the user's second
            # complaint, which is about the whole image and not about any one
            # region; on the demo frames the reference measures 0.230, v2e 0.313
            # and the round-1 student 0.392.
            entry[f"colour_l1_to_painting_{width}"] = round(float(
                (colour_distribution(student)[0] - colour_reference).abs().sum()), 4)
        if width == 640:
            for sigma in ("sigma1", "sigma2", "sigma4"):
                entry[f"ratio_{sigma}"] = round(
                    entry[f"student_640_{sigma}"] / entry[f"teacher_640_{sigma}"], 4)
            entry.update(colour_accent(model, frame))
            entry.update({f"teacher_{name}": value
                          for name, value in colour_accent(teacher, frame).items()})
    return entry


def build_student(checkpoint, key):
    model = build_v2de(key).cuda()
    payload = torch.load(checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(payload["model"], strict=True)
    return model.eval(), int(payload.get("step", -1))


def main(args):
    descriptor = TextureDescriptor().cuda()
    teacher = NativeGroupMixNet().cuda().eval()
    teacher.load_state_dict(torch.load(args.teacher, map_location="cpu",
                                      weights_only=True)["model"], strict=True)
    teacher.requires_grad_(False)
    frames = {size: load_frame(EVAL, *size).cuda() for size in SIZES}
    colour_reference = colour_reference_from_file(STYLE).cuda()
    judge = Perceptual(VGG_FEATURES).eval().cuda()
    # The frozen discriminator from the reference generator's run: the metric that
    # matches the eye.  Real painting crops +0.403, the reference +0.003, AESPA
    # -0.045, the raw input -0.087, and every small model between -0.13 and -0.18.
    global FROZEN_JUDGE
    from adversarial import _PatchDiscriminator
    if JUDGE_STATE.is_file():
        payload = torch.load(JUDGE_STATE, map_location="cpu", weights_only=False)
        FROZEN_JUDGE = _PatchDiscriminator(antialias=True)
        FROZEN_JUDGE.load_state_dict(payload["trainer"]["networks"]["D"], strict=True)
        FROZEN_JUDGE = FROZEN_JUDGE.cuda().eval()
    else:
        print(f"judge state not found: {JUDGE_STATE}", file=sys.stderr)
    painting_features = judge.extract(style_tensor_from_file(STYLE).cuda())
    painting_localgram = local_gram_descriptors(painting_features[2])
    # The texture-only view: a colour gain cannot pay for this one.
    painting_luma_features = judge.extract(
        to_luma_image(style_tensor_from_file(STYLE).cuda()))
    luma_directions = style_directions(
        [painting_luma_features[index].shape[1] for index in (2, 3)])
    painting_directions = style_directions(
        [painting_features[index].shape[1] for index in (2, 3)])

    key = EXPERIMENTS[args.experiment]
    checkpoints = ([args.checkpoint] if args.checkpoint else
                   sorted(Path(args.run_dir).glob("checkpoints/step_*.pt"),
                          key=lambda p: int(p.stem.split("_")[1])))
    report = {}
    for checkpoint in checkpoints:
        model, step = build_student(checkpoint, key)
        report[f"step_{step:06d}"] = describe(
            model, teacher, descriptor, frames, colour_reference, judge,
            painting_features, painting_directions, painting_luma_features,
            luma_directions, painting_localgram, judge)
        del model
        torch.cuda.empty_cache()
    # The teacher's own row makes the target explicit.
    report["teacher"] = describe(teacher, teacher, descriptor, frames,
                                 colour_reference, judge, painting_features,
                                 painting_directions, painting_luma_features,
                                 luma_directions, painting_localgram, judge)
    header = None
    for name, entry in report.items():
        if header is None:
            header = list(entry)
            print(f"{'checkpoint':>16s} " + " ".join(f"{h:>18s}" for h in header))
        print(f"{name:>16s} " + " ".join(f"{entry[h]:18.6f}" for h in header))
    if args.output:
        Path(args.output).write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"wrote {args.output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment",
                        default="native_groupmix_v2e_factorizedshuffle_c32_fp32")
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--teacher", type=Path,
                        default=METHOD.parent / "runs/v1_teacher_step020000.pt")  # students/runs
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.checkpoint and not args.run_dir:
        raise SystemExit("give --checkpoint or --run-dir")
    main(args)
