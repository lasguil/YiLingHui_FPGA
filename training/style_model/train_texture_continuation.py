"""Continue a V2-D/V2-E generator towards the v1 teacher with texture distillation.

Source of truth: docs/NativeGroupMixNet_v2_no_depth_cut_two_models_D_E_guide.md for
the topologies, and distill_texture.py for why the objective looks the way it does.

This is the same shape of experiment as ``train_v2b_continuation.py``: a fresh
optimizer and fresh auxiliary networks so a changed objective cannot silently
reuse moments from the old one, and only the generator state is inherited.  What
differs is the distillation: ``distill_mode=tex`` matches the teacher's spatially
resolved oriented energy instead of its pixel-exact high frequencies, and the
original CUT objective is kept unchanged and balanced exactly as before.

The student may be continued from any of its own checkpoints; the checkpoint's
own step is authoritative and must match ``--start-step``.
"""
import argparse
import copy
import importlib.util
import json
import random
import sys
import time
import uuid
from collections import Counter
from pathlib import Path

import numpy as np
import torch
import torch.hub

from settings import (HERE, METHOD, PREP, STYLE, EXPERIMENTS, batch_size, digest,
                      readiness)
sys.path.insert(0, str(PREP))
import common as base
from eval_images import save_both
from model import NativeGroupMixNet
from distill_texture import colour_reference_from_file, style_tensor_from_file


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
    temporary.replace(path)


def load_model_weights(model, checkpoint, label):
    payload = torch.load(checkpoint, map_location="cpu", weights_only=True)
    state = payload.get("model") if isinstance(payload, dict) else None
    if state is None:
        raise ValueError(f"{label} is not a generator checkpoint: {checkpoint}")
    expected_step = payload.get("step")
    model.load_state_dict(state, strict=True)
    return int(expected_step) if expected_step is not None else None


def make_teacher(checkpoint):
    teacher = NativeGroupMixNet().cuda().eval()
    step = load_model_weights(teacher, checkpoint, "teacher checkpoint")
    for parameter in teacher.parameters():
        parameter.requires_grad_(False)
    return teacher, step


def lr_at(step, start, end, initial, schedule="continuation"):
    if end <= start:
        return float(initial)
    fraction = min(1.0, max(0.0, (step - start) / float(end - start)))
    if schedule == "scratch":
        # Same shape as train.py's from-scratch CUT recipe: constant for the
        # first half, then linear decay to zero.
        return float(initial) * max(0.0, 1.0 - max(0.0, fraction - 0.5) / 0.5)
    if schedule == "scratch_global":
        # Branching a from-scratch run at a later step: keep the original
        # 10k/20k shape, measured on the global step, not on the branch span.
        # The original from-scratch budget is 20k; a branch starting at 7k
        # must keep that global shape, not treat its own end as the budget.
        global_fraction = min(1.0, max(0.0, step / 20000.0))
        return float(initial) * max(
            0.0, 1.0 - max(0.0, global_fraction - 0.5) / 0.5)
    return float(initial) * (1.0 - 0.5 * fraction)


def main(args):
    readiness()
    if args.start_step < 0 or args.end_step <= args.start_step:
        raise ValueError("Expected end_step > start_step >= 0")
    if args.experiment not in EXPERIMENTS:
        raise ValueError(f"Unknown experiment {args.experiment}")
    if args.save_every <= 0 or args.diagnose_every <= 0:
        raise ValueError("save_every and diagnose_every must be positive")
    if args.distill_mode == "tex" and args.distill_gradient_target <= 0:
        raise ValueError("tex distillation needs a positive gradient target")
    out = args.run_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    lock = (out / ".run.lock").open("a")
    import fcntl
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if any(path.name != ".run.lock" for path in out.iterdir()):
        raise FileExistsError(f"Continuation output is not empty: {out}")

    student_step = torch.load(args.student_checkpoint, map_location="cpu",
                              weights_only=True).get("step")
    if int(student_step) != args.start_step:
        raise ValueError(f"Expected student step {args.start_step}, got {student_step}")
    if args.base_only:
        nonzero = {name: getattr(args, name, 0) for name in (
            "distill_weight", "texture_weight", "relation_weight", "low_weight",
            "chroma_weight", "broadband_weight", "contrast_weight",
            "repetition_weight", "colour_weight", "flow_weight", "swd_weight",
            "localgram_weight", "judge_weight", "coarse_band_weight",
            "shape_weight", "flat_weight", "geometry_weight", "coarse_weight")
            if getattr(args, name, 0)}
        if nonzero:
            raise ValueError(f"--base-only requires zero loss-2 weights, got {nonzero}")
        if args.distill_mode != "rgb" or args.distill_gradient_target:
            raise ValueError("--base-only requires --distill-mode rgb and "
                             "--distill-gradient-target 0")
        teacher, teacher_step = None, None
    else:
        teacher, teacher_step = (
            (None, None) if args.teacher_checkpoint is None
            else make_teacher(args.teacher_checkpoint))
    colour_reference = (colour_reference_from_file(STYLE)
                        if (args.colour_weight
                            or args.painting_colour_gradient_target) else None)
    judge = None
    if args.judge_weight:
        if args.judge_checkpoint is None or not args.judge_checkpoint.is_file():
            raise FileNotFoundError(f"judge checkpoint missing: {args.judge_checkpoint}")
        from adversarial import _PatchDiscriminator
        payload = torch.load(args.judge_checkpoint, map_location="cpu", weights_only=False)
        judge = _PatchDiscriminator(antialias=True)
        judge.load_state_dict(payload["trainer"]["networks"]["D"], strict=True)
        judge = judge.cuda()
        print(json.dumps({"judge_from": str(args.judge_checkpoint),
                          "judge_step": int(payload["trainer"]["step"])}), flush=True)
    score = None
    if args.score_gradient_target:
        if args.score_checkpoint is None or not args.score_checkpoint.is_file():
            raise FileNotFoundError(f"scorer checkpoint missing: {args.score_checkpoint}")
        from adversarial import _PatchDiscriminator
        payload = torch.load(args.score_checkpoint, map_location="cpu",
                             weights_only=False)
        score = _PatchDiscriminator(antialias=True)
        score.load_state_dict(payload["model"], strict=True)
        score = score.cuda()
        for parameter in score.parameters():
            parameter.requires_grad_(False)
        print(json.dumps({"score_from": str(args.score_checkpoint),
                          "score_step": int(payload.get("step", -1)),
                          "score_target": args.score_target,
                          "score_gradient_target": args.score_gradient_target}),
              flush=True)
    aespa_teacher = None
    if (args.aespa_feature_gradient_target or args.aespa_style_targets
            or args.dreamsim_global_gradient_target
            or args.dreamsim_patch_gradient_target):
        scorer_path = Path("/data1/fpga_style_transfer_2026_tmp/"
                           "scorer_vangogh_v2_20261018/style_scorer_v2.py")
        spec = importlib.util.spec_from_file_location("scorer_module", scorer_path)
        scorer_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scorer_module)
        aespa_teacher = scorer_module.AespaRunner(torch.device("cuda:0"))
        print(json.dumps({"aespa_feature_from": str(scorer_path),
                          "alpha": args.aespa_feature_alpha,
                          "gradient_target": args.aespa_feature_gradient_target,
                          "gram_weight": args.aespa_feature_gram_weight,
                          "localgram_weight": args.aespa_feature_localgram_weight}),
              flush=True)
    dreamsim_model = None
    if (args.dreamsim_global_gradient_target
            or args.dreamsim_patch_gradient_target):
        torch.hub._validate_not_a_forked_repo = lambda *a, **k: None
        from dreamsim import dreamsim as load_dreamsim
        dreamsim_model, _ = load_dreamsim(
            pretrained=True, device="cuda",
            cache_dir=args.dreamsim_cache_dir,
            dreamsim_type="dino_vitb16", use_patch_model=True)
        dreamsim_model.eval()
        for parameter in dreamsim_model.parameters():
            parameter.requires_grad_(False)
        print(json.dumps({"dreamsim": "dino_vitb16_patch",
                          "cache": args.dreamsim_cache_dir}), flush=True)
    coeff = base.weights()
    trainer, initial = base.create(
        args.experiment, coeff, nce_a_scale=args.nce_a_scale,
        nce_y_scale=args.nce_y_scale, teacher=teacher,
        distill_weight=args.distill_weight, distill_mode=args.distill_mode,
        distill_gradient_target=args.distill_gradient_target,
        balance_target=args.vgg_gradient_target,
        balance_target_patch=args.vgg_patch_gradient_target,
        texture_weight=args.texture_weight,
        relation_weight=args.relation_weight,
        low_weight=args.low_weight,
        chroma_weight=args.chroma_weight,
        broadband_weight=args.broadband_weight,
        contrast_weight=args.contrast_weight,
        contrast_gain=args.contrast_gain,
        repetition_weight=args.repetition_weight,
        colour_weight=args.colour_weight,
        colour_reference=colour_reference,
        flow_weight=args.flow_weight,
        swd_weight=args.swd_weight, swd_luma=not args.swd_rgb,
        localgram_weight=args.localgram_weight,
        judge=judge, judge_weight=args.judge_weight,
        score=score, score_gradient_target=args.score_gradient_target,
        score_target=args.score_target,
        aespa_feature_gradient_target=args.aespa_feature_gradient_target,
        aespa_feature_gram_weight=args.aespa_feature_gram_weight,
        aespa_feature_localgram_weight=args.aespa_feature_localgram_weight,
        aespa_l2_gradient_target=args.aespa_feature_l2_gradient_target,
        dreamsim=dreamsim_model,
        dreamsim_global_gradient_target=args.dreamsim_global_gradient_target,
        dreamsim_patch_gradient_target=args.dreamsim_patch_gradient_target,
        dreamsim_patch_count=args.dreamsim_patch_count,
        dreamsim_patch_size=args.dreamsim_patch_size,
        dreamsim_patch_worst_weight=args.dreamsim_patch_worst_weight,
        dreamsim_calibration_steps=args.dreamsim_calibration_steps,
        dreamsim_rescale_step=args.dreamsim_rescale_step,
        dreamsim_rescale_window=args.dreamsim_rescale_window,
        dreamsim_rescale_cap=args.dreamsim_rescale_cap,
        aespa_low_gradient_target=args.aespa_low_gradient_target,
        painting_colour_gradient_target=args.painting_colour_gradient_target,
        aespa_chroma_gradient_target=args.aespa_chroma_gradient_target,
        halo_gradient_target=args.halo_gradient_target,
        halo_target=args.halo_target,
        halo_sigma_ring=args.halo_sigma_ring,
        halo_sigma_back=args.halo_sigma_back,
        halo_bright_fraction=args.halo_bright_fraction,
        aespa_low_sigma=args.aespa_low_sigma,
        aespa_colour_calibration_steps=args.aespa_colour_calibration_steps,
        coarse_band_weight=args.coarse_band_weight,
        shape_weight=args.shape_weight,
        flat_weight=args.flat_weight, flat_sigma=args.flat_sigma,
        flat_shrink=args.flat_shrink,
        flat_contrast_weight=args.flat_contrast_weight,
        flat_texture_weight=args.flat_texture_weight,
        flat_flow_weight=args.flat_flow_weight,
        flat_low_weight=args.flat_low_weight)
    loaded_step = load_model_weights(trainer.generator, args.student_checkpoint,
                                     "student checkpoint")
    if loaded_step != args.start_step:
        raise ValueError(f"Student checkpoint step changed during load: {loaded_step}")
    trainer.steps = args.start_step
    from refine_policy import configure_refinement
    configure_refinement(trainer, args)
    trainer.set_lr(args.lr)
    trainer.validate_state(args.start_step)
    ema = None
    if args.ema_decay > 0:
        # Training-time only: the EMA weights are what gets saved/evaluated,
        # the deployment topology and the live generator are unchanged.
        ema = copy.deepcopy(trainer.generator).eval()
        for parameter in ema.parameters():
            parameter.requires_grad_(False)
        print(json.dumps({"ema_decay": args.ema_decay}), flush=True)
    if args.swd_weight or args.localgram_weight:
        # The painting is the style target: the user asked for the texture and the
        # colour proportions to match the Van Gogh original.
        channels = trainer.prepare_style_reference(style_tensor_from_file(STYLE).cuda())
        print(json.dumps({"style_reference_channels": channels}), flush=True)
    samples = base.Samples(args.experiment)
    batch = batch_size(args.experiment)

    deps = {str(path): digest(path)
            for path in list(HERE.glob("*.py")) + list(PREP.glob("*.py"))}
    config = {
        "experiment": args.experiment,
        "continuation": True,
        "start_step": args.start_step,
        "end_step": args.end_step,
        "base_only": args.base_only,
        "student_checkpoint": str(args.student_checkpoint),
        "student_checkpoint_step": int(loaded_step),
        "teacher_checkpoint": str(args.teacher_checkpoint) if args.teacher_checkpoint else None,
        "teacher_checkpoint_step": teacher_step,
        "generator": type(trainer.generator).__name__,
        "parameters": sum(p.numel() for p in trainer.generator.parameters()),
        "batch_size": batch,
        "new_optimizer_state": True,
        "initial_lr": args.lr,
        "ema_decay": args.ema_decay,
        "lr_schedule": "linear decay from initial_lr to 0.5*initial_lr over continuation",
        "save_every": args.save_every,
        "diagnose_every": args.diagnose_every,
        "precision": "FP32 CUDA; no AMP/TF32",
        "nce_a_scale": args.nce_a_scale,
        "nce_y_scale": args.nce_y_scale,
        "distill_weight": args.distill_weight,
        "distill_mode": args.distill_mode,
        "distill_gradient_target": args.distill_gradient_target,
        "texture_weights": {"texture": args.texture_weight,
                           "relation": args.relation_weight,
                           "low": args.low_weight,
                           "chroma": args.chroma_weight,
                           "broadband": args.broadband_weight,
                           "contrast": args.contrast_weight,
                           "contrast_gain": args.contrast_gain,
                           "repetition": args.repetition_weight,
                           "colour": args.colour_weight,
                           "colour_reference": str(STYLE),
                           "flow": args.flow_weight,
                           "swd": args.swd_weight,
                           "localgram": args.localgram_weight,
                           "judge": args.judge_weight,
                           "coarse_band": args.coarse_band_weight,
                           "shape": args.shape_weight,
                           "judge_checkpoint": (str(args.judge_checkpoint)
                                                if args.judge_checkpoint else None),
                           "flat": args.flat_weight,
                           "flat_sigma": args.flat_sigma,
                           "flat_shrink": args.flat_shrink,
                           "flat_contrast": args.flat_contrast_weight,
                           "flat_texture": args.flat_texture_weight,
                           "flat_flow": args.flat_flow_weight,
                           "flat_low": args.flat_low_weight},
        "score": {"checkpoint": (str(args.score_checkpoint)
                                 if args.score_checkpoint else None),
                  "gradient_target": args.score_gradient_target,
                  "target": args.score_target},
        "aespa_feature": {"gradient_target": args.aespa_feature_gradient_target,
                          "gram_weight": args.aespa_feature_gram_weight,
                          "localgram_weight": args.aespa_feature_localgram_weight,
                          "alpha": args.aespa_feature_alpha,
                          "l2_gradient_target": args.aespa_feature_l2_gradient_target,
                          "style_targets": args.aespa_style_targets},
        "dreamsim": {"global_gradient_target":
                     args.dreamsim_global_gradient_target,
                     "patch_gradient_target":
                     args.dreamsim_patch_gradient_target,
                     "patch_count": args.dreamsim_patch_count,
                     "patch_size": args.dreamsim_patch_size,
                     "patch_worst_weight":
                     args.dreamsim_patch_worst_weight,
                     "calibration_steps":
                     args.dreamsim_calibration_steps,
                     "rescale_step": args.dreamsim_rescale_step,
                     "rescale_window": args.dreamsim_rescale_window,
                     "rescale_cap": args.dreamsim_rescale_cap,
                     "cache_dir": args.dreamsim_cache_dir},
        "texture_descriptor": (None if trainer.texture is None else trainer.texture.config),
        "vgg_gradient_target": args.vgg_gradient_target,
        "vgg_patch_gradient_target": args.vgg_patch_gradient_target,
        "distillation_probe": json.loads(Path(args.calibration).read_text(encoding="utf-8"))
        if args.calibration else None,
        "cut_loss_config": trainer.config,
        "dependencies": deps,
        "preflight_dir": str(PREP),
        "note": ("RNG/data sampler is restarted at the branch; global step and student BN "
                 "state come from the source checkpoint.  distill_mode=tex compares "
                 "phase-tolerant oriented energy, not pixel-exact high frequencies."),
    }
    config = json.loads(json.dumps(config))
    atomic_json(out / "config.json", config)
    print(json.dumps(config), flush=True)

    began = time.monotonic()
    totals = Counter()
    count = 0
    seen = Counter()
    log = (out / "train.jsonl").open("a", buffering=1)

    def save(step):
        trainer.validate_state(step)
        target = ema if ema is not None else trainer.generator
        checkpoint_dir = out / "checkpoints"
        checkpoint_dir.mkdir(exist_ok=True)
        checkpoint = checkpoint_dir / f"step_{step:06d}.pt"
        if not checkpoint.exists():
            partial = checkpoint.with_suffix(".pt.partial")
            torch.save({"model": target.state_dict(), "step": step,
                        "config": config}, partial)
            partial.replace(checkpoint)
        images = out / "test_images"
        images.mkdir(exist_ok=True)
        final = images / f"step_{step:06d}"
        if not final.exists():
            staging = images / f".step_{step:06d}_{uuid.uuid4().hex}.partial"
            save_both(target, METHOD / "assets/eval_content.png",
                      base.PROJECT / "tmp/IMG_20250712_073503.jpg", staging)
            staging.rename(final)
        # EMA lags heavily over the first few hundred steps (decay 0.999), so
        # also persist and render the raw generator.  It is the only meaningful
        # early-training signal; EMA becomes the primary weight later.
        raw_checkpoint = None
        raw_final = None
        if ema is not None:
            raw_dir = out / "checkpoints_raw"
            raw_dir.mkdir(exist_ok=True)
            raw_checkpoint = raw_dir / f"step_{step:06d}.pt"
            if not raw_checkpoint.exists():
                partial = raw_checkpoint.with_suffix(".pt.partial")
                torch.save({"model": trainer.generator.state_dict(),
                            "step": step, "config": config}, partial)
                partial.replace(raw_checkpoint)
            raw_images = out / "test_images_raw"
            raw_images.mkdir(exist_ok=True)
            raw_final = raw_images / f"step_{step:06d}"
            if not raw_final.exists():
                staging = (raw_images
                           / f".step_{step:06d}_{uuid.uuid4().hex}.partial")
                save_both(trainer.generator,
                          METHOD / "assets/eval_content.png",
                          base.PROJECT / "tmp/IMG_20250712_073503.jpg",
                          staging)
                staging.rename(raw_final)
        row = {"checkpoint_step": step, "samples_seen": step * batch,
               "checkpoint": str(checkpoint), "test_images": str(final)}
        if raw_checkpoint is not None:
            row["checkpoint_raw"] = str(raw_checkpoint)
            row["test_images_raw"] = str(raw_final)
        state_path = out / "training_state_latest.pt"
        state_partial = out / "training_state_latest.pt.partial"
        torch.save({"trainer": trainer.state_dict(), "step": step,
                    "ema": None if ema is None else ema.state_dict(),
                    "refinement": trainer.config["refinement"],
                    "dreamsim_weights": [trainer.dreamsim_global_scale, trainer.dreamsim_patch_scale],
                    "painting_colour_scale": trainer.painting_colour_scale,
                    "halo_scale": trainer.halo_scale}, state_partial)
        state_partial.replace(state_path)
        log.write(json.dumps(row) + "\n")
        print(json.dumps({"checkpoint_step": step, "samples_seen": step * batch}),
              flush=True)

    try:
        save(args.start_step)
        for step in range(args.start_step + 1, args.end_step + 1):
            lr = lr_at(step, args.start_step, args.end_step, args.lr,
                       args.lr_schedule)
            trainer.set_lr(lr)
            a, b, paired, style_reference, records = samples.batch(step, batch)
            diagnose = step % args.diagnose_every == 0
            aespa_target = (aespa_teacher.target_tensor(a, args.aespa_feature_alpha)
                            if aespa_teacher is not None else None)
            if args.aespa_style_targets:
                if aespa_target is None:
                    raise RuntimeError("--aespa-style-targets requires the AesPA runner")
                # Step 1: the base CUT style terms now compare against AesPA,
                # not the painting.  b is the GAN real, paired the VGG-patch
                # reference, style_reference the VGG-global reference.
                b = aespa_target
                paired = aespa_target
                style_reference = aespa_target
            parts = trainer.step(a, b, paired, diagnose=diagnose,
                                 global_reference=style_reference,
                                 aespa_target=aespa_target)
            assert all(np.isfinite(value) for value in parts.values())
            assert all(parameter.grad is None and not parameter.requires_grad
                       for parameter in trainer.perceptual.parameters())
            if ema is not None:
                with torch.no_grad():
                    for ema_parameter, parameter in zip(
                            ema.parameters(), trainer.generator.parameters()):
                        ema_parameter.mul_(args.ema_decay).add_(
                            parameter, alpha=1.0 - args.ema_decay)
                    for ema_buffer, buffer in zip(
                            ema.buffers(), trainer.generator.buffers()):
                        if ema_buffer.is_floating_point():
                            ema_buffer.mul_(args.ema_decay).add_(
                                buffer, alpha=1.0 - args.ema_decay)
                        else:
                            ema_buffer.copy_(buffer)
            seen.update(record["dataset"] for record in records)
            for key, value in parts.items():
                # Effective coefficients already have per-step uppercase metrics.
                # Do not average sparsely emitted diagnostic snapshots as zeros.
                if (not key.startswith("grad_") and key not in {
                    "dreamsim_global_scale", "dreamsim_patch_scale",
                    "dreamsim_global_effective_weight", "dreamsim_patch_effective_weight",
                    "aespa_low_scale", "painting_colour_scale",
                    "aespa_low_effective_weight", "painting_colour_effective_weight",
                    "aespa_chroma_effective_weight", "halo_effective_weight"}):
                    totals[key] += value
            count += 1
            if diagnose:
                row = {"gradient_probe": step,
                       **{key: value for key, value in parts.items()
                          if key.startswith("grad_")}}
                log.write(json.dumps(row) + "\n")
                print(json.dumps(row), flush=True)
            del a, b, paired, style_reference
            if step % 25 == 0 or step == args.end_step:
                row = {"step": step, "samples_seen": step * batch,
                       "lr": lr,
                       "mean": {key: value / count for key, value in totals.items()},
                       "dataset_visits": dict(seen),
                       "seconds": time.monotonic() - began}
                log.write(json.dumps(row) + "\n")
                print(json.dumps(row), flush=True)
                totals.clear()
                count = 0
                atomic_json(out / "progress.json", row)
            if step % args.save_every == 0 or step == args.end_step:
                save(step)
        atomic_json(out / "COMPLETE.json", {
            "start_step": args.start_step, "step": args.end_step,
            "steps_trained": args.end_step - args.start_step,
            "checkpoints": len(list((out / "checkpoints").glob("step_*.pt"))),
        })
    finally:
        log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--experiment", required=True)
    parser.add_argument("--student-checkpoint", type=Path, required=True)
    parser.add_argument("--teacher-checkpoint", type=Path)
    parser.add_argument("--base-only", action="store_true",
                        help="CUT base objective only: no v1 teacher, no distillation "
                             "and no hand-crafted terms (all loss-2 weights must be 0)")
    parser.add_argument("--start-step", type=int, required=True)
    parser.add_argument("--end-step", type=int, required=True)
    parser.add_argument("--save-every", type=int, default=1000)
    parser.add_argument("--diagnose-every", type=int, default=100)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--lr-schedule",
                        choices=("continuation", "scratch", "scratch_global"),
                        default="continuation",
                        help="continuation: linear 1.0x -> 0.5x over the run; "
                             "scratch: constant first half, linear to zero; "
                             "scratch_global: same shape measured on step/end")
    parser.add_argument("--ema-decay", type=float, default=0.0,
                        help="EMA decay for the saved/evaluated generator; "
                             "0 disables")
    parser.add_argument("--nce-a-scale", type=float, required=True)
    parser.add_argument("--nce-y-scale", type=float, required=True)
    parser.add_argument("--distill-weight", type=float, default=0.0)
    parser.add_argument("--distill-mode", choices=("rgb", "haar_hf", "hf_rel", "tex"),
                        default="rgb")
    parser.add_argument("--distill-gradient-target", type=float, default=0.0)
    parser.add_argument("--texture-weight", type=float, default=1.0)
    parser.add_argument("--relation-weight", type=float, default=0.35)
    parser.add_argument("--low-weight", type=float, default=0.15)
    parser.add_argument("--chroma-weight", type=float, default=0.0)
    parser.add_argument("--broadband-weight", type=float, default=0.0)
    parser.add_argument("--contrast-weight", type=float, default=0.0)
    parser.add_argument("--contrast-gain", type=float, default=1.0)
    parser.add_argument("--repetition-weight", type=float, default=0.0)
    parser.add_argument("--colour-weight", type=float, default=0.0)
    parser.add_argument("--flow-weight", type=float, default=0.0)
    parser.add_argument("--swd-weight", type=float, default=0.0)
    parser.add_argument("--localgram-weight", type=float, default=0.0)
    parser.add_argument("--judge-weight", type=float, default=0.0)
    parser.add_argument("--judge-checkpoint", type=Path, default=None,
                        help="the reference run's training_state_latest.pt, holding its D")
    parser.add_argument("--score-checkpoint", type=Path, default=None,
                        help="AesPA-likeness scorer checkpoint (scorer_best_portable.pt)")
    parser.add_argument("--score-gradient-target", type=float, default=0.0,
                        help="gradient ratio of the scorer hinge to the base CUT "
                             "objective; normalised separately from the distill block")
    parser.add_argument("--score-target", type=float, default=0.95,
                        help="one-sided hinge target on the scorer output "
                             "(AesPA mean is about +1.0, v2e about +0.78)")
    parser.add_argument("--aespa-feature-gradient-target", type=float, default=0.0,
                        help="gradient ratio of the AesPA feature block to the "
                             "base CUT objective; independent of the distill block")
    parser.add_argument("--aespa-feature-gram-weight", type=float, default=1.0)
    parser.add_argument("--aespa-feature-localgram-weight", type=float, default=1.0)
    parser.add_argument("--aespa-feature-alpha", type=float, default=0.955)
    parser.add_argument("--aespa-feature-l2-gradient-target", type=float,
                        default=0.0,
                        help="gradient ratio of the relu4_1 perceptual feature "
                             "L2 to the base CUT objective")
    parser.add_argument("--aespa-style-targets", action="store_true",
                        help="use the AesPA output as the GAN real and the VGG "
                             "global/patch reference instead of painting crops")
    parser.add_argument("--dreamsim-global-gradient-target", type=float,
                        default=0.0,
                        help="calibration target for the global DreamSim weight; "
                             "measured over the first calibration steps, then frozen")
    parser.add_argument("--dreamsim-patch-gradient-target", type=float,
                        default=0.0,
                        help="calibration target for the sampled-patch DreamSim "
                             "weight; measured over the first calibration steps, "
                             "then frozen")
    parser.add_argument("--dreamsim-patch-count", type=int, default=2)
    parser.add_argument("--dreamsim-patch-size", type=int, default=96)
    parser.add_argument("--dreamsim-patch-worst-weight", type=float, default=0.0,
                        help="coefficient of the worst-quartile patch term; "
                             "0 uses the mean only")
    parser.add_argument("--dreamsim-calibration-steps", type=int, default=20,
                        help="first N steps measure the gradient ratio with "
                             "DreamSim inactive, then freeze one fixed weight")
    parser.add_argument("--dreamsim-rescale-step", type=int, default=0,
                        help="once at this global step, measure a window and "
                             "apply at most one capped rescale; 0 disables")
    parser.add_argument("--dreamsim-rescale-window", type=int, default=20)
    parser.add_argument("--dreamsim-rescale-cap", type=float, default=2.0)
    parser.add_argument("--dreamsim-cache-dir", type=str,
                        default="/data1/fpga_style_transfer_2026_tmp/cache/dreamsim")
    parser.add_argument("--aespa-low-gradient-target", type=float, default=0.0,
                        help="P0: gradient share of the low-frequency colour "
                             "field L1 against the AesPA target")
    parser.add_argument("--painting-colour-gradient-target", type=float,
                        default=0.0,
                        help="P0: gradient share of the opponent-histogram "
                             "L1 against the painting")
    parser.add_argument("--aespa-chroma-gradient-target", type=float,
                        default=0.0,
                        help="P0: gradient share of the one-sided warm-accent "
                             "floor against the AesPA target")
    parser.add_argument("--halo-gradient-target", type=float, default=0.0,
                        help="gradient share of the warm-ring floor around "
                             "bright highlights")
    parser.add_argument("--halo-target", type=float, default=0.048)
    parser.add_argument("--halo-sigma-ring", type=float, default=4.0)
    parser.add_argument("--halo-sigma-back", type=float, default=12.0)
    parser.add_argument("--halo-bright-fraction", type=float, default=0.01)
    parser.add_argument("--aespa-low-sigma", type=float, default=6.0)
    parser.add_argument("--aespa-colour-calibration-steps", type=int,
                        default=20)
    parser.add_argument("--coarse-band-weight", type=float, default=0.0,
                        help="one-sided floor on the 9-16 px stroke band (12-16 px was "
                             "measured at 0.80 of the reference while 4.5-9 px sat at 1.08-1.20)")
    parser.add_argument("--shape-weight", type=float, default=0.0,
                        help="two-sided match of the texture energy distribution across "
                             "scales (the fine bands are over and the coarse band under)")
    parser.add_argument("--flat-weight", type=float, default=0.0,
                        help="strength of the flat-content probe block (shallow 8-bit "
                             "staircase batch, where the corridor wall lives)")
    parser.add_argument("--flat-sigma", type=float, default=16.0,
                        help="blur that removes the texture before quantisation")
    parser.add_argument("--flat-shrink", type=float, default=0.10,
                        help="how much of the remaining shading contrast survives")
    parser.add_argument("--flat-contrast-weight", type=float, default=1.0)
    parser.add_argument("--flat-texture-weight", type=float, default=1.0)
    parser.add_argument("--flat-flow-weight", type=float, default=1.0)
    parser.add_argument("--flat-low-weight", type=float, default=1.0)
    parser.add_argument("--swd-rgb", action="store_true",
                        help="score the SWD on colour features (default: luma only)")
    parser.add_argument("--vgg-gradient-target", type=float, default=0.25,
                        help="gradient ratio for the global Gram style distance")
    parser.add_argument("--vgg-patch-gradient-target", type=float, default=None,
                        help="gradient ratio for the paired local Gram term")
    parser.add_argument("--calibration", type=Path,
                        help="calibration JSON from calibrate_distill.py, recorded in config.json")
    parser.add_argument("--refine-policy", type=Path, required=True)
    main(parser.parse_args())
