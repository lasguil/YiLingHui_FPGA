"""Continue v2b from a 5k generator checkpoint with isolated loss variants.

This entry point deliberately loads only the student generator from the source
checkpoint.  The discriminator, PatchNCE heads, and Adam states are fresh so a
changed objective cannot silently reuse moments from the old objective.
"""
import argparse
import json
import os
import random
import shutil
import sys
import time
import uuid
from collections import Counter
from pathlib import Path

import numpy as np
import torch

from settings import HERE, METHOD, PREP, batch_size, digest, readiness
sys.path.insert(0, str(PREP))
import common as base
from eval_images import save_both
from model import NativeGroupMixNet


EXPERIMENT = "v2b_groupcut"
DEFAULT_START = 5000
DEFAULT_END = 20000


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
    if checkpoint is None:
        return None, None
    teacher = NativeGroupMixNet().cuda().eval()
    step = load_model_weights(teacher, checkpoint, "teacher checkpoint")
    for parameter in teacher.parameters():
        parameter.requires_grad_(False)
    return teacher, step


def lr_at(step, start, end, initial):
    if end <= start:
        return float(initial)
    fraction = min(1.0, max(0.0, (step - start) / float(end - start)))
    return float(initial) * (1.0 - 0.5 * fraction)


def main(args):
    readiness()
    if args.start_step < 0 or args.end_step <= args.start_step:
        raise ValueError("Expected end_step > start_step >= 0")
    if args.start_step != DEFAULT_START:
        raise ValueError("This campaign is intentionally anchored at the v2b 5k checkpoint")
    if args.save_every <= 0 or args.diagnose_every <= 0:
        raise ValueError("save_every and diagnose_every must be positive")
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
    teacher, teacher_step = make_teacher(args.teacher_checkpoint)
    coeff = base.weights()
    trainer, initial = base.create(
        EXPERIMENT, coeff, nce_a_scale=args.nce_a_scale,
        nce_y_scale=args.nce_y_scale, teacher=teacher,
        distill_weight=args.distill_weight, distill_mode=args.distill_mode,
        distill_gradient_target=args.distill_gradient_target,
        balance_target=args.vgg_gradient_target)
    loaded_step = load_model_weights(trainer.generator, args.student_checkpoint,
                                     "student checkpoint")
    if loaded_step != args.start_step:
        raise ValueError(f"Student checkpoint step changed during load: {loaded_step}")
    trainer.steps = args.start_step
    trainer.set_lr(args.lr)
    trainer.validate_state(args.start_step)
    samples = base.Samples(EXPERIMENT)
    batch = batch_size(EXPERIMENT)

    deps = {str(path): digest(path)
            for path in list(HERE.glob("*.py")) + list(PREP.glob("*.py"))}
    config = {
        "experiment": EXPERIMENT,
        "continuation": True,
        "start_step": args.start_step,
        "end_step": args.end_step,
        "student_checkpoint": str(args.student_checkpoint),
        "student_checkpoint_step": int(loaded_step),
        "teacher_checkpoint": str(args.teacher_checkpoint) if args.teacher_checkpoint else None,
        "teacher_checkpoint_step": teacher_step,
        "generator": type(trainer.generator).__name__,
        "parameters": sum(p.numel() for p in trainer.generator.parameters()),
        "batch_size": batch,
        "new_optimizer_state": True,
        "initial_lr": args.lr,
        "lr_schedule": "linear decay from initial_lr to 0.5*initial_lr over continuation",
        "save_every": args.save_every,
        "diagnose_every": args.diagnose_every,
        "precision": "FP32 CUDA; no AMP/TF32",
        "nce_a_scale": args.nce_a_scale,
        "nce_y_scale": args.nce_y_scale,
        "distill_weight": args.distill_weight,
        "distill_mode": args.distill_mode,
        "distill_gradient_target": args.distill_gradient_target,
        "vgg_gradient_target": args.vgg_gradient_target,
        "cut_loss_config": trainer.config,
        "dependencies": deps,
        "preflight_dir": str(PREP),
        "note": "RNG/data sampler is restarted at the branch; global step and student BN state come from step 5000.",
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
        checkpoint_dir = out / "checkpoints"
        checkpoint_dir.mkdir(exist_ok=True)
        checkpoint = checkpoint_dir / f"step_{step:06d}.pt"
        if not checkpoint.exists():
            partial = checkpoint.with_suffix(".pt.partial")
            torch.save({"model": trainer.generator.state_dict(), "step": step,
                        "config": config}, partial)
            partial.replace(checkpoint)
        images = out / "test_images"
        images.mkdir(exist_ok=True)
        final = images / f"step_{step:06d}"
        if not final.exists():
            staging = images / f".step_{step:06d}_{uuid.uuid4().hex}.partial"
            save_both(trainer.generator, METHOD / "assets/eval_content.png",
                      base.PROJECT / "tmp/IMG_20250712_073503.jpg", staging)
            staging.rename(final)
        log.write(json.dumps({"checkpoint_step": step,
                              "samples_seen": step * batch,
                              "checkpoint": str(checkpoint),
                              "test_images": str(final)}) + "\n")
        print(json.dumps({"checkpoint_step": step, "samples_seen": step * batch}),
              flush=True)

    try:
        save(args.start_step)
        for step in range(args.start_step + 1, args.end_step + 1):
            lr = lr_at(step, args.start_step, args.end_step, args.lr)
            trainer.set_lr(lr)
            a, b, paired, style_reference, records = samples.batch(step, batch)
            diagnose = step % args.diagnose_every == 0
            parts = trainer.step(a, b, paired, diagnose=diagnose,
                                 global_reference=style_reference)
            assert all(np.isfinite(value) for value in parts.values())
            assert all(parameter.grad is None and not parameter.requires_grad
                       for parameter in trainer.perceptual.parameters())
            seen.update(record["dataset"] for record in records)
            for key, value in parts.items():
                if not key.startswith("grad_"):
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
    parser.add_argument("--student-checkpoint", type=Path, required=True)
    parser.add_argument("--teacher-checkpoint", type=Path)
    parser.add_argument("--start-step", type=int, default=DEFAULT_START)
    parser.add_argument("--end-step", type=int, default=DEFAULT_END)
    parser.add_argument("--save-every", type=int, default=1000)
    parser.add_argument("--diagnose-every", type=int, default=100)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--nce-a-scale", type=float, required=True)
    parser.add_argument("--nce-y-scale", type=float, required=True)
    parser.add_argument("--distill-weight", type=float, default=0.0)
    parser.add_argument("--distill-mode", choices=("rgb", "haar_hf", "hf_rel"), default="rgb")
    parser.add_argument("--distill-gradient-target", type=float, default=0.0)
    parser.add_argument("--vgg-gradient-target", type=float, default=0.25)
    main(parser.parse_args())
