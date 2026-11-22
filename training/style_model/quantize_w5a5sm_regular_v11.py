"""Conventional-scale W5/A5 sign-magnitude PTQ for NativeGroupMixNet v1.1.

Activations use one arbitrary symmetric scale per layer.  Weights use one
arbitrary symmetric scale per output channel.  Integer codes remain the
deployed explicit-sign plus four-bit-magnitude representation in [-15, 15];
this is deliberately not two's-complement INT4.  No block exponent or local
delta is present.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F


HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[3]
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
OUT_DIR = RUN / "ptq_w5a5sm_regular_v11_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_w5a5sm_regular_v11.mp4"
SM_SCRIPT = HERE / "quantize_w5a5sm_b4_v11.py"
QMAX = 15


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def round_away(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(x.abs() + 0.5)


def quantize_activation(values: torch.Tensor, scale: float, signed: bool = True):
    del signed
    q = round_away(values / scale).clamp(-QMAX, QMAX).to(torch.int64)
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"A5-SM packing requires channels divisible by 4, got {c}")
    delta = torch.zeros((b, c // 4, h, w), dtype=torch.int64,
                        device=values.device)
    return q, delta


def reconstruct_activation(q: torch.Tensor, delta: torch.Tensor, scale: float):
    return q.float() * scale


def choose_activation_scale(values_list):
    maximum = max(float(values.detach().abs().max().item()) for values in values_list)
    if maximum == 0.0:
        return 1.0, 0.0
    best_scale, best_mse = maximum / QMAX, float("inf")
    # MSE-optimal clipping search.  Unlike the fixed-PoT experiment, every
    # candidate is an ordinary real scale.
    for ratio in np.linspace(0.20, 1.00, 41):
        scale = maximum * float(ratio) / QMAX
        total, count = 0.0, 0
        for values in values_list:
            q = round_away(values / scale).clamp(-QMAX, QMAX)
            total += float((q * scale - values).square().sum().item())
            count += values.numel()
        mse = total / max(count, 1)
        if mse < best_mse:
            best_scale, best_mse = scale, mse
    return float(best_scale), float(best_mse)


def calibrate_scales(base, fp32, inputs):
    names = ["input", "stem", "enc", "down"]
    for i in range(4):
        names += [f"body{i}_gconv", f"body{i}"]
    names += ["reduce", "dec", "head"]
    traces = [base.trace_fp32(fp32, x) for x in inputs[:min(16, len(inputs))]]
    scales = {}
    for name in names:
        scale, mse = choose_activation_scale([trace[name] for trace in traces])
        scales[name] = scale
        print(f"scale {name}: {scale:.10g} mse={mse:.8g}", flush=True)
    return scales


def make_regular_w5conv(base):
    class RegularW5Conv(base.W5Conv):
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

            flat = canonical.reshape(canonical.shape[0], -1)
            maximum = flat.abs().amax(dim=1)
            weight_scale = torch.where(
                maximum > 0, maximum / QMAX, torch.ones_like(maximum))
            view_shape = [canonical.shape[0]] + [1] * (canonical.ndim - 1)
            q = round_away(canonical / weight_scale.reshape(view_shape))
            q = q.clamp(-QMAX, QMAX).to(torch.int64)
            self.register_buffer("qweight", q.to(torch.int8))
            self.register_buffer("weight_scale", weight_scale.detach().float())
            self.register_buffer("weight_delta", torch.zeros(
                canonical.shape[:-1], dtype=torch.int8, device=canonical.device))
            self.register_buffer("weight_sign", (q < 0).to(torch.uint8))
            self.register_buffer("weight_magnitude", q.abs().to(torch.uint8))
            self.register_buffer("bias", bias.detach().cuda())
            self.padding = 1 if kind == "gconv" else 0

        def accumulate(self, xq, xd, xscale):
            del xd
            xqf = xq.float()
            if self.kind == "pw":
                acc = torch.zeros(
                    xq.shape[0], self.out_channels, xq.shape[2], xq.shape[3],
                    device=xq.device)
                for n in range(self.qweight.shape[1]):
                    acc += torch.einsum(
                        "bkhw,ok->bohw", xqf[:, n * 4:(n + 1) * 4],
                        self.qweight[:, n].float())
                scale = self.weight_scale.reshape(1, -1, 1, 1) * xscale
                return acc * scale + self.bias.reshape(1, -1, 1, 1)

            _, _, h, w = xq.shape
            ocpg = self.out_channels // self.groups
            nb = self.qweight.shape[2]
            qwin = F.unfold(
                F.pad(xqf, (1, 1, 1, 1), mode="reflect"), 3)
            qwin = qwin.reshape(
                xq.shape[0], self.groups, nb, 4, 9, h * w)
            qwin = qwin.permute(0, 1, 4, 2, 3, 5).reshape(
                xq.shape[0], self.groups, 9, nb, 4, h, w)
            acc = torch.zeros(
                xq.shape[0], self.out_channels, h, w, device=xq.device)
            for group in range(self.groups):
                start, end = group * ocpg, (group + 1) * ocpg
                partial = torch.einsum(
                    "btnkhw,otnk->botnhw", qwin[:, group],
                    self.qweight[start:end].float())
                acc[:, start:end] = partial.sum(dim=(2, 3))
            scale = self.weight_scale.reshape(1, -1, 1, 1) * xscale
            return acc * scale + self.bias.reshape(1, -1, 1, 1)

    return RegularW5Conv


def save_artifact(base, model, act_scales):
    metadata = {
        "format": "native_groupmix_w5a5sm_regular_symmetric_ptq_v11",
        "source_checkpoint": str(CHECKPOINT),
        "source_step": 20000,
        "weight_format": "W5 sign-magnitude: explicit sign + 4-bit magnitude, q in [-15,15]",
        "activation_format": "A5 sign-magnitude: explicit sign + 4-bit magnitude, q in [-15,15]",
        "two_complement_int4": False,
        "zero_point": 0,
        "block_size": None,
        "local_exponent_bits": 0,
        "activation_scale_policy": "one arbitrary symmetric real scale per layer",
        "weight_scale_policy": "one arbitrary symmetric real scale per output channel",
        "activation_scales": act_scales,
        "weight_scales": {
            name: module.weight_scale.detach().cpu().tolist()
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
    artifact = OUT_DIR / "model_w5a5sm_regular_v11_ptq.pt"
    torch.save({
        "format": metadata["format"],
        "model_state": model.state_dict(),
        "packed_weights_sign_magnitude": packed,
        "metadata": metadata,
    }, artifact)
    (OUT_DIR / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")


def run_video(model):
    cap = cv2.VideoCapture(str(VIDEO))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
    writer = cv2.VideoWriter(
        str(VIDEO_OUT), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    frames = 0
    with torch.inference_mode():
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1)
                x = x.unsqueeze(0).cuda().float().div_(255.0)
                y = model(x).clamp(0, 1)[0].permute(1, 2, 0)
                y = (y * 255.0 + 0.5).to(torch.uint8).cpu().numpy()
                writer.write(cv2.cvtColor(y, cv2.COLOR_RGB2BGR))
                frames += 1
        finally:
            cap.release()
            writer.release()
    return frames, width, height, fps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-video", action="store_true")
    args = parser.parse_args()
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required; CPU fallback is disabled")

    sm = load_module("w5a5sm_b4_v11_for_regular", SM_SCRIPT)
    base = sm.load_base_script()
    base.W5Conv = make_regular_w5conv(base)
    sm.quantize_activation = quantize_activation
    sm.reconstruct_activation = reconstruct_activation

    _, fp32, _ = base.mxbase.load_base().load_source_model(CHECKPOINT)
    inputs = base.mxbase.calibration_inputs(base.mxbase.load_base(), VIDEO)
    act_scales = calibrate_scales(base, fp32, inputs)
    model = sm.NativeGroupMixNetV11(base, fp32, act_scales).cuda().eval()
    save_artifact(base, model, act_scales)
    with torch.inference_mode():
        model(inputs[-1])
    if args.run_video:
        started = time.time()
        frames, width, height, fps = run_video(model)
        print(json.dumps({
            "output": str(VIDEO_OUT), "frames": frames,
            "size": [width, height], "fps": fps,
            "elapsed_seconds": time.time() - started,
        }, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
