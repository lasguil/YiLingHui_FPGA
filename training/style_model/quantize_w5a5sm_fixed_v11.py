"""Fixed-scale W5/A5-SM PTQ experiment for NativeGroupMixNet v1.1.

This deliberately keeps the deployed five-bit sign-magnitude code:
one explicit sign bit plus a four-bit magnitude (q in [-15, 15]).  It is
not two's-complement INT4.  Compared with quantize_w5a5sm_b4_v11.py, the
only quantization-policy change is that every layer uses one power-of-two
scale and all local B4 exponent deltas are zero.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from torch import nn


HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[3]
SM_SCRIPT = HERE / "quantize_w5a5sm_b4_v11.py"
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
B4_VIDEO = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_w5a5sm_b4_v11.mp4"
OUT_DIR = RUN / "ptq_w5a5sm_fixed_v11_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_w5a5sm_fixed_v11.mp4"
COMPARE_OUT = PROJECT / "ml/our_data/480p/native_groupmix_w5a5sm_b4_vs_fixed_v11.mp4"
QMAX = 15


def load_sm_script():
    spec = importlib.util.spec_from_file_location("w5a5sm_b4_v11", SM_SCRIPT)
    if spec is None or spec.loader is None:
        raise ImportError(SM_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def round_away(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(x.abs() + 0.5)


def fixed_quantize_activation(values: torch.Tensor, base: int, signed: bool = True):
    del signed  # All deployed activations are A5 sign-magnitude.
    scale = float(2.0 ** base)
    q = round_away(values / scale).clamp(-QMAX, QMAX).to(torch.int64)
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"A5-SM packing requires channels divisible by 4, got {c}")
    delta = torch.zeros((b, c // 4, h, w), dtype=torch.int64, device=values.device)
    return q, delta


def fixed_reconstruct_activation(q: torch.Tensor, delta: torch.Tensor, base: int):
    if torch.count_nonzero(delta).item() != 0:
        raise ValueError("fixed-scale path received a non-zero local exponent delta")
    return q.float() * float(2.0 ** base)


def exponent_candidates(values_list):
    max_abs = max(float(values.detach().abs().max().item()) for values in values_list)
    if max_abs == 0.0:
        return [0]
    center = int(math.ceil(math.log2(max_abs / QMAX)))
    return range(center - 8, center + 5)


def choose_fixed_activation_base(values_list, qmax: int):
    if qmax != QMAX:
        raise ValueError(f"fixed A5-SM expects qmax={QMAX}, got {qmax}")
    best, best_mse = 0, float("inf")
    for base in exponent_candidates(values_list):
        total, count = 0.0, 0
        scale = float(2.0 ** base)
        for values in values_list:
            q = round_away(values / scale).clamp(-QMAX, QMAX)
            total += float((q * scale - values).square().sum().item())
            count += values.numel()
        mse = total / max(count, 1)
        if mse < best_mse:
            best, best_mse = int(base), mse
    return best, best_mse


def choose_fixed_weight(canonical: torch.Tensor):
    best_base, best_mse, best_q = 0, float("inf"), None
    for base in exponent_candidates([canonical]):
        scale = float(2.0 ** base)
        q = round_away(canonical / scale).clamp(-QMAX, QMAX)
        mse = float((q * scale - canonical).square().mean().item())
        if mse < best_mse:
            best_base, best_mse, best_q = int(base), mse, q
    assert best_q is not None
    return best_base, best_mse, best_q.to(torch.int64)


def make_fixed_w5conv(base):
    class FixedW5Conv(base.W5Conv):
        def __init__(self, weight, bias, groups, kind):
            nn.Module.__init__(self)
            self.groups = groups
            self.kind = kind
            self.out_channels = weight.shape[0]
            self.group_channels = weight.shape[1]
            if self.group_channels % 4:
                raise ValueError(weight.shape)
            if kind == "pw":
                canonical = weight.reshape(weight.shape[0], weight.shape[1] // 4, 4)
            elif kind == "gconv":
                canonical = weight.permute(0, 2, 3, 1).reshape(
                    weight.shape[0], 9, weight.shape[1] // 4, 4)
            else:
                raise ValueError(kind)
            weight_base, weight_mse, q = choose_fixed_weight(canonical)
            self.register_buffer("qweight", q.to(torch.int8))
            self.register_buffer("weight_delta", torch.zeros(
                canonical.shape[:-1], dtype=torch.int8, device=canonical.device))
            self.register_buffer("weight_sign", (q < 0).to(torch.uint8))
            self.register_buffer("weight_magnitude", q.abs().to(torch.uint8))
            self.register_buffer("bias", bias.detach().cuda())
            self.weight_base = weight_base
            self.weight_mse = weight_mse
            self.padding = 1 if kind == "gconv" else 0

    return FixedW5Conv


def save_artifact(sm, base, model, act_base):
    metadata = {
        "format": "native_groupmix_w5a5sm_fixed_pow2_ptq_v11",
        "source_checkpoint": str(CHECKPOINT),
        "source_step": 20000,
        "generator": "NativeGroupMixNet-v1.1 fixed-scale SM-only PTQ",
        "parameters": 19255,
        "weight_format": "W5 sign-magnitude: explicit sign + 4-bit magnitude, q in [-15,15]",
        "activation_format": "A5 sign-magnitude: explicit sign + 4-bit magnitude, q in [-15,15]",
        "two_complement_int4": False,
        "block_size": None,
        "local_exponent_bits": 0,
        "local_exponent_range": [0, 0],
        "scale": "one power-of-two scale 2^E per layer; no local/block delta",
        "rounding": "round-to-nearest, ties-away-from-zero",
        "removed_requant_boundaries": [
            "enc_gconv_branch", "body0_pw", "body1_pw", "body2_pw",
            "body3_pw", "dec_gconv_branch"],
        "required_requant_boundaries": [
            "input", "stem", "enc_residual", "down", "body_gconv_to_pw",
            "body_residual", "reduce", "dec_residual", "head"],
        "activation_base_exponents": act_base,
        "weight_base_exponents": {
            name: int(module.weight_base)
            for name, module in model.named_modules()
            if isinstance(module, base.W5Conv)
        },
    }
    packed = {
        name: base.pack_w5_sign_magnitude(module.qweight)
        for name, module in model.named_modules()
        if isinstance(module, base.W5Conv)
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    artifact = OUT_DIR / "model_w5a5sm_fixed_v11_ptq.pt"
    torch.save({
        "format": metadata["format"],
        "model_state": model.state_dict(),
        "packed_weights_sign_magnitude": packed,
        "metadata": metadata,
    }, artifact)
    (OUT_DIR / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {artifact}", flush=True)


def run_video(model, max_frames: int = 0):
    cap = cv2.VideoCapture(str(VIDEO))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if max_frames:
        total = min(total, max_frames)
    writer = cv2.VideoWriter(
        str(VIDEO_OUT), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    index = 0
    with torch.inference_mode():
        try:
            while not max_frames or index < max_frames:
                ok, frame = cap.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1)
                x = x.unsqueeze(0).cuda().float().div_(255.0)
                y = model(x).clamp(0, 1)[0].permute(1, 2, 0)
                y = (y * 255.0 + 0.5).to(torch.uint8).cpu().numpy()
                writer.write(cv2.cvtColor(y, cv2.COLOR_RGB2BGR))
                index += 1
                if index == 1 or index % 100 == 0:
                    print(f"Processed {index}/{total or '?'} frames", flush=True)
        finally:
            cap.release()
            writer.release()
    return index, width, height, fps


def compose_comparison(frame_count: int, width: int, height: int, fps: float):
    paths = [VIDEO, B4_VIDEO, VIDEO_OUT]
    captures = [cv2.VideoCapture(str(path)) for path in paths]
    writer = cv2.VideoWriter(
        str(COMPARE_OUT), cv2.VideoWriter_fourcc(*"mp4v"), fps,
        (width * 3, height))
    labels = ["INPUT", "W5A5-SM B4", "W5A5-SM FIXED SCALE"]
    written = 0
    try:
        while written < frame_count:
            frames = []
            for capture in captures:
                ok, frame = capture.read()
                if not ok:
                    return written
                if frame.shape[1] != width or frame.shape[0] != height:
                    frame = cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)
                frames.append(frame)
            for frame, label in zip(frames, labels):
                cv2.rectangle(frame, (8, 8), (390, 48), (0, 0, 0), -1)
                cv2.putText(frame, label, (18, 37), cv2.FONT_HERSHEY_SIMPLEX,
                            0.85, (255, 255, 255), 2, cv2.LINE_AA)
            writer.write(np.concatenate(frames, axis=1))
            written += 1
    finally:
        for capture in captures:
            capture.release()
        writer.release()
    return written


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-video", action="store_true")
    parser.add_argument("--max-frames", type=int, default=0)
    args = parser.parse_args()
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required; CPU fallback is intentionally disabled")

    sm = load_sm_script()
    base = sm.load_base_script()
    FixedW5Conv = make_fixed_w5conv(base)
    base.W5Conv = FixedW5Conv
    sm.quantize_activation = fixed_quantize_activation
    sm.reconstruct_activation = fixed_reconstruct_activation
    sm.choose_activation_base = choose_fixed_activation_base

    _, fp32, _ = base.mxbase.load_base().load_source_model(CHECKPOINT)
    inputs = base.mxbase.calibration_inputs(base.mxbase.load_base(), VIDEO)
    print(f"Calibration inputs: {len(inputs)}", flush=True)
    act_base = sm.calibrate_bases(base, fp32, inputs)
    model = sm.NativeGroupMixNetV11(base, fp32, act_base).cuda().eval()
    save_artifact(sm, base, model, act_base)

    with torch.inference_mode():
        smoke = model(inputs[-1])
    print(f"Smoke test OK: {tuple(smoke.shape)}", flush=True)

    if args.run_video:
        started = time.time()
        frames, width, height, fps = run_video(model, args.max_frames)
        compared = compose_comparison(frames, width, height, fps)
        print(json.dumps({
            "fixed_output": str(VIDEO_OUT),
            "comparison_output": str(COMPARE_OUT),
            "frames": frames,
            "comparison_frames": compared,
            "size": [width, height],
            "fps": fps,
            "elapsed_seconds": time.time() - started,
        }, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
