"""Measure the distillation terms and their gradient scales on one real batch.

The overall strength of the distillation is set automatically: the trainer scales
the combined term so its gradient RMS is ``distill_gradient_target`` times the
gradient RMS of the original objective.  What that cannot choose is the *split*
between the texture, Body-relation and low-frequency terms, because their raw
values live on completely different scales.  This script measures each term's
gradient RMS against the same generator and prints the weights that would give a
requested split, so the weights are calibrated by measurement rather than by
guessing.

Run it before a run starts; it writes no files and trains nothing.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import torch

from settings import HERE, PREP, METHOD, readiness
sys.path.insert(0, str(PREP))
sys.path.insert(0, str(HERE))
import common as base
from adversarial import CUTTrainer
from distill_texture import colour_reference_from_file  # noqa: E402
from distill_texture import (TextureDescriptor, band_contrast_loss,
                             spectral_shape_loss,
                             broadbandness_loss, chroma_loss,
                             coherence_loss, colour_distribution_loss,
                             energy_scale_loss, flat_content_loss, flat_probe,
                             low_frequency_loss,
                             orientation_flow_loss, repetition_loss,
                             sliced_wasserstein_style_loss,
                             stroke_contrast_loss, style_directions,
                             style_tensor_from_file, texture_stat_loss,
                             to_luma_image)
from perceptual import gradient_rms


def term_gradient(value, parameters):
    """gradient_rms, tolerating a term that is legitimately satisfied.

    The one-sided terms measure a floor.  A checkpoint that already meets it --
    the round-16 student meets the real-content contrast floor -- contributes no
    gradient at all, and that is a result of the measurement rather than a
    failure of it, so it is reported as zero instead of tripping the helper's
    near-zero assertion.
    """
    if not value.requires_grad:
        return 0.0
    gradients = torch.autograd.grad(value, parameters, retain_graph=True,
                                    allow_unused=True)
    total = sum(g.square().sum() for g in gradients if g is not None)
    count = sum(p.numel() for p in parameters)
    if float(total) == 0.0:
        return 0.0
    return float((total / count).sqrt().detach())


def load_weights(model, checkpoint, label):
    payload = torch.load(checkpoint, map_location="cpu", weights_only=True)
    state = payload.get("model") if isinstance(payload, dict) else None
    if state is None:
        raise ValueError(f"{label} is not a generator checkpoint: {checkpoint}")
    model.load_state_dict(state, strict=True)
    return int(payload.get("step"))


def main(args):
    readiness()
    coefficients = base.weights()
    trainer, _initial = base.create(args.experiment, coefficients,
                                    nce_a_scale=args.nce_a_scale,
                                    nce_y_scale=args.nce_y_scale)
    student_step = load_weights(trainer.generator, args.student_checkpoint, "student")
    from model import NativeGroupMixNet
    teacher = NativeGroupMixNet().cuda().eval()
    teacher_step = load_weights(teacher, args.teacher_checkpoint, "teacher")
    for parameter in teacher.parameters():
        parameter.requires_grad_(False)

    from settings import STYLE
    descriptor = TextureDescriptor().cuda()
    reference_histogram = colour_reference_from_file(STYLE).cuda()
    from perceptual import Perceptual
    judge = Perceptual(METHOD / "quarter_vgg_local_20260904/vgg19_imagenet_features.pt").eval().cuda()
    painting_features = judge.extract(
        to_luma_image(style_tensor_from_file(STYLE).cuda()))
    painting_directions = style_directions(
        [painting_features[index].shape[1] for index in (2, 3)])
    samples = base.Samples(args.experiment)
    a, _b, _paired, _style, _records = samples.batch(args.start_step, args.batch_size)

    parameters = tuple(trainer.generator.parameters())
    trainer.generator.train()
    with torch.enable_grad():
        fake, student_stages = trainer.generator.forward_with_body_stages(a)
        with torch.no_grad():
            teacher_fake, teacher_stages = teacher.forward_with_body_stages(a)

        from adversarial import body_relation_loss
        terms = {
            "texture": texture_stat_loss(descriptor, fake, teacher_fake),
            "coherence": coherence_loss(descriptor, fake, teacher_fake),
            "relation": body_relation_loss(student_stages, teacher_stages),
            "low": low_frequency_loss(fake, teacher_fake),
            "energy": energy_scale_loss(descriptor, fake, teacher_fake),
            "chroma": chroma_loss(fake, teacher_fake, a),
            "broadband": broadbandness_loss(fake, teacher_fake),
            "contrast": stroke_contrast_loss(fake, teacher_fake, a, args.contrast_gain),
            "coarse_band": band_contrast_loss(fake, teacher_fake, a,
                                              gain=args.contrast_gain),
            "shape": spectral_shape_loss(fake, teacher_fake, a),
            "repetition": repetition_loss(fake, teacher_fake),
            "flow": orientation_flow_loss(fake, teacher_fake),
            "swd": sliced_wasserstein_style_loss(
                judge.extract(to_luma_image(fake)), painting_features,
                painting_directions),
            "colour": colour_distribution_loss(fake, reference_histogram),
        }
        # A single scalar standing in for "the original objective" so the
        # distillation can be sized against it: the real base_A needs D, F and
        # VGG, and its gradient scale is dominated by GAN + NCE + VGG terms that
        # this probe does not need to reproduce exactly for a weight split.
        report = {"experiment": args.experiment,
                  "student_step": student_step, "teacher_step": teacher_step,
                  "batch": args.batch_size,
                  "terms": {}}
        for name, value in terms.items():
            report["terms"][name] = {
                "value": float(value.detach()),
                "gradient_rms": term_gradient(value, parameters),
            }
        # Same-batch reference: the gradient scale of a plain output L1, which is
        # the objective each earlier run was sized against.
        reference = (fake - teacher_fake).square().mean()
        report["output_mse"] = {"value": float(reference.detach()),
                                "gradient_rms": float(gradient_rms(reference, parameters))}

        # The flat-content probe, measured as one block: its internal split is
        # fixed by the same reasoning as the main terms (contrast is the target,
        # the others keep the answer structured and keep the colour), so only the
        # block's total share has to be chosen.
        flat_content = flat_probe(a, args.flat_sigma, args.flat_shrink)
        with torch.no_grad():
            flat_teacher = teacher(flat_content)
        from adversarial import running_stats
        with running_stats(trainer.generator):
            flat_fake = trainer.generator(flat_content)
        flat_terms = flat_content_loss(
            descriptor, flat_fake, flat_teacher, flat_content,
            {"contrast": 1.0, "texture": 1.0, "flow": 1.0, "low": 1.0,
             "coarse": args.coarse_band_weight},
            args.contrast_gain)
        report["flat_block"] = {
            name: {"value": float(value.detach()),
                   "gradient_rms": term_gradient(value, parameters)}
            for name, value in flat_terms.items() if value is not None}
        report["flat_probe"] = {
            "sigma": args.flat_sigma, "shrink": args.flat_shrink,
            "source_std": round(float(a.std()), 6),
            "probe_std": round(float(flat_content.std()), 6),
            "distinct_levels": int(torch.unique((flat_content * 256).round()).numel())}

    requested = {"texture": args.texture_share, "relation": args.relation_share,
                 "low": args.low_share, "chroma": args.chroma_share,
                 "broadband": args.broadband_share, "contrast": args.contrast_share,
                 "repetition": args.repetition_share,
                 "colour": args.colour_share, "flow": args.flow_share,
                 "swd": args.swd_share, "flat": args.flat_share,
                 "coarse_band": args.coarse_band_share,
                 "shape": args.shape_share}
    texture_units = (report["terms"]["texture"]["gradient_rms"]
                     + report["terms"]["coherence"]["gradient_rms"]
                     + report["terms"]["energy"]["gradient_rms"])
    units = {"texture": texture_units,
             "relation": report["terms"]["relation"]["gradient_rms"],
             "low": report["terms"]["low"]["gradient_rms"],
             "chroma": report["terms"]["chroma"]["gradient_rms"],
             "broadband": report["terms"]["broadband"]["gradient_rms"],
             "contrast": report["terms"]["contrast"]["gradient_rms"],
             "repetition": report["terms"]["repetition"]["gradient_rms"],
             "colour": report["terms"]["colour"]["gradient_rms"],
             "flow": report["terms"]["flow"]["gradient_rms"],
             "swd": report["terms"]["swd"]["gradient_rms"],
             "flat": report["flat_block"]["combined"]["gradient_rms"],
             "coarse_band": report["terms"]["coarse_band"]["gradient_rms"],
             "shape": report["terms"]["shape"]["gradient_rms"]}
    total = sum(requested.values())
    report["requested_share"] = requested
    report["calibrated_weights"] = {
        name: round(requested[name] / total * report["output_mse"]["gradient_rms"]
                    / max(units[name], 1e-16), 6)
        for name in units}
    report["student_parameters"] = sum(p.numel() for p in parameters)
    print(json.dumps(report, indent=2))
    if args.output:
        Path(args.output).write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment", required=True)
    parser.add_argument("--student-checkpoint", type=Path, required=True)
    parser.add_argument("--teacher-checkpoint", type=Path, required=True)
    parser.add_argument("--start-step", type=int, default=5000)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--nce-a-scale", type=float, default=0.2)
    parser.add_argument("--nce-y-scale", type=float, default=0.35)
    parser.add_argument("--texture-share", type=float, default=0.80)
    parser.add_argument("--relation-share", type=float, default=0.15)
    parser.add_argument("--low-share", type=float, default=0.05)
    parser.add_argument("--chroma-share", type=float, default=0.0)
    parser.add_argument("--broadband-share", type=float, default=0.0)
    parser.add_argument("--contrast-share", type=float, default=0.0)
    parser.add_argument("--contrast-gain", type=float, default=1.0)
    parser.add_argument("--repetition-share", type=float, default=0.0)
    parser.add_argument("--colour-share", type=float, default=0.0)
    parser.add_argument("--flow-share", type=float, default=0.0)
    parser.add_argument("--swd-share", type=float, default=0.0)
    parser.add_argument("--coarse-band-share", type=float, default=0.0)
    parser.add_argument("--shape-share", type=float, default=0.0)
    parser.add_argument("--coarse-band-weight", type=float, default=0.0,
                        help="weight used when measuring the flat block's coarse-band part")
    parser.add_argument("--flat-share", type=float, default=0.0,
                        help="gradient share of the whole flat-probe block")
    parser.add_argument("--flat-sigma", type=float, default=16.0)
    parser.add_argument("--flat-shrink", type=float, default=0.10)
    parser.add_argument("--output")
    main(parser.parse_args())
