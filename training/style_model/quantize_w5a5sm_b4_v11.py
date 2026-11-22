"""NativeGroupMixNet v1.1: W5/A5-SM only, B4, exponent-only PTQ.

Independent from quantize_w5a5_b4.py.  Weight format stays W5
sign-magnitude.  ReLU outputs use unsigned A5 [0, 31], while the signed
Head output remains A5 sign-magnitude [-15, 15].  The six unnecessary
branch-to-residual requantization boundaries are removed.
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
from PIL import Image
from torch import nn
from torch.nn import functional as F


HERE = Path(__file__).resolve().parent
STUDENTS = HERE.parents[1]
PROJECT = HERE.parents[3]
BASE_SCRIPT = HERE / "quantize_w5a5_b4.py"
RUN = STUDENTS / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
OUT_DIR = RUN / "ptq_w5a5sm_b4_v11_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_w5a5sm_b4_v11.mp4"
QMAX_SIGNED = 15
QMAX_UNSIGNED = 31
DELTA_MAX = 7


def load_base_script():
    sys.path.insert(0, str(HERE))
    spec = importlib.util.spec_from_file_location("w5a5_base_quantizer", BASE_SCRIPT)
    if spec is None or spec.loader is None:
        raise ImportError(BASE_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def round_away(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(x.abs() + 0.5)


def block_exponent(amax: torch.Tensor, qmax: int) -> torch.Tensor:
    safe = torch.clamp(amax, min=2.0 ** -30)
    exponent = torch.ceil(torch.log2(safe / qmax)).to(torch.int64)
    return torch.where(amax > 0, exponent, torch.zeros_like(exponent))


def quantize_activation(values: torch.Tensor, base: int, signed: bool):
    # SM-only build: every activation is A5 sign-magnitude [-15, 15].  The
    # unsigned A5-U path is not used, so `signed` is kept for call-site
    # compatibility but the encoding is always signed.
    qmax = QMAX_SIGNED
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"B4 requires channels divisible by 4, got {c}")
    blocks = values.reshape(b, c // 4, 4, h, w)
    amax = blocks.abs().amax(dim=2)
    e_star = block_exponent(amax, qmax)
    delta = (e_star - base).clamp(0, DELTA_MAX)
    scale = torch.pow(torch.tensor(2.0, device=values.device), (base + delta).float())
    q = round_away(blocks / scale.unsqueeze(2))
    low = -qmax
    q = q.clamp(low, qmax).to(torch.int64)
    return q.reshape_as(values), delta


def reconstruct_activation(q: torch.Tensor, delta: torch.Tensor, base: int):
    blocks = q.reshape(q.shape[0], q.shape[1] // 4, 4, q.shape[2], q.shape[3])
    scale = torch.pow(torch.tensor(2.0, device=q.device), (base + delta).float())
    return (blocks.float() * scale.unsqueeze(2)).reshape_as(q)


def choose_activation_base(values_list, qmax: int):
    e_min, e_max = 999, -999
    for values in values_list:
        blocks = values.reshape(values.shape[0], values.shape[1] // 4, 4, values.shape[2], values.shape[3])
        e = block_exponent(blocks.abs().amax(dim=2), qmax)
        e_min = min(e_min, int(e.min().item()))
        e_max = max(e_max, int(e.max().item()))
    best, best_mse = 0, float("inf")
    for base in range(e_min - 1, e_max + 1):
        total, count = 0.0, 0
        for values in values_list:
            signed = qmax == QMAX_SIGNED
            q, d = quantize_activation(values, base, signed)
            total += float((reconstruct_activation(q, d, base) - values).square().sum().item())
            count += values.numel()
        mse = total / max(count, 1)
        if mse < best_mse:
            best, best_mse = base, mse
    return best, best_mse


def calibrate_bases(base, fp32, inputs):
    names = ["input", "stem", "enc", "down"]
    for i in range(4):
        names += [f"body{i}_gconv", f"body{i}"]
    names += ["reduce", "dec", "head"]
    traces = [base.trace_fp32(fp32, x) for x in inputs[: min(16, len(inputs))]]
    bases = {}
    for name in names:
        qmax = QMAX_SIGNED
        base_exp, mse = choose_activation_base([trace[name] for trace in traces], qmax)
        bases[name] = int(base_exp)
        mode = "A5-SM" if qmax == QMAX_SIGNED else "A5-U"
        print(f"base {name}: {mode} E={base_exp} mse={mse:.8g}", flush=True)
    return bases


class NativeGroupMixNetV11(nn.Module):
    def __init__(self, base, fp32, act_base):
        super().__init__()
        self.base = base
        self.act_base = act_base
        self.stem = base.W5Conv(*base.mxbase.fold_bn(fp32.stem, fp32.stem_norm), 1, "pw")
        self.enc = base.W5Conv(*base.mxbase.fold_bn(fp32.enc.gconv, fp32.enc.norm), 2, "gconv")
        down_w, down_b = base.mxbase.fold_bn(fp32.down, fp32.down_norm)
        self.down = base.W5Conv(base.mxbase.permute_down_weight(down_w), down_b, 1, "pw")
        self.body_gconv, self.body_pw = nn.ModuleList(), nn.ModuleList()
        for block in fp32.body:
            self.body_gconv.append(base.W5Conv(*base.mxbase.fold_bn(block.gconv, block.gconv_norm), 4, "gconv"))
            self.body_pw.append(base.W5Conv(*base.mxbase.fold_bn(block.pw, block.pw_norm), 1, "pw"))
        self.reduce = base.W5Conv(*base.mxbase.fold_bn(fp32.reduce, fp32.reduce_norm), 1, "pw")
        self.dec = base.W5Conv(*base.mxbase.fold_bn(fp32.dec.gconv, fp32.dec.norm), 2, "gconv")
        self.head = base.W5Conv(*base.mxbase.fold_bn(fp32.head, fp32.head_norm), 1, "pw")
        self.rgb = base.W5Conv(fp32.rgb.weight.detach(), fp32.rgb.bias.detach(), 1, "gconv")

    def quantize(self, values, name, signed=False):
        return quantize_activation(values, self.act_base[name], signed)

    def conv_quantized(self, layer, q, d, in_base, out_name, relu6=True, signed=False):
        real = layer.accumulate(q, d, in_base)
        if relu6:
            real = real.clamp(0.0, 6.0)
        return self.quantize(real, out_name, signed)

    def residual_from_wide(self, q0, d0, b0, branch, out_name):
        value = reconstruct_activation(q0, d0, b0) + branch
        return self.quantize(value.clamp(0.0, 6.0), out_name, signed=False)

    @staticmethod
    def _pad_to_4(x):
        h, w = x.shape[-2:]
        ph, pw = (-h) % 4, (-w) % 4
        if ph or pw:
            x = F.pad(x, (0, pw, 0, ph), mode="reflect")
        return x, (ph, pw)

    def forward(self, x):
        h, w = x.shape[-2:]
        padded, (ph, pw) = self._pad_to_4(x)
        q, d = self.quantize(F.pixel_unshuffle(padded, 2), "input")

        q, d = self.conv_quantized(self.stem, q, d, self.act_base["input"], "stem")

        # Enc branch stays wide until the residual add: no branch requant.
        branch = self.enc.accumulate(q, d, self.act_base["stem"]).clamp(0.0, 6.0)
        q, d = self.residual_from_wide(q, d, self.act_base["stem"], branch, "enc")

        q, d = self.base.phase_major_unshuffle(q, d)
        q, d = self.conv_quantized(self.down, q, d, self.act_base["enc"], "down")

        for i, (gconv, pw) in enumerate(zip(self.body_gconv, self.body_pw)):
            in_name = "down" if i == 0 else f"body{i - 1}"
            # GConv output must be A5 because PW consumes it.
            bq, bd = self.conv_quantized(gconv, q, d, self.act_base[in_name], f"body{i}_gconv")
            # PW output stays wide until residual; no body{i}_pw requant.
            branch = pw.accumulate(bq, bd, self.act_base[f"body{i}_gconv"])
            q, d = self.residual_from_wide(q, d, self.act_base[in_name], branch, f"body{i}")

        q, d = self.conv_quantized(self.reduce, q, d, self.act_base["body3"], "reduce")
        q, d = self.base.nearest2(q, d)

        # Dec branch stays wide until the residual add: no branch requant.
        branch = self.dec.accumulate(q, d, self.act_base["reduce"]).clamp(0.0, 6.0)
        q, d = self.residual_from_wide(q, d, self.act_base["reduce"], branch, "dec")

        q, d = self.conv_quantized(self.head, q, d, self.act_base["dec"], "head", relu6=False, signed=True)
        q, d = self.base.nearest2(q, d)
        logits = self.rgb.accumulate(q, d, self.act_base["head"])
        output = torch.sigmoid(logits)
        return output[..., :h, :w] if ph or pw else output


def save_artifact(base, model, act_base):
    metadata = {
        "format": "native_groupmix_w5a5sm_b4_pow2_ptq_v11",
        "source_checkpoint": str(CHECKPOINT),
        "source_step": 20000,
        "generator": "NativeGroupMixNet-v1.1 SM-only quantization data path",
        "parameters": 19255,
        "weight_format": "sign-magnitude W5: 1 sign + 4 magnitude, q in [-15,15]",
        "activation_format": "A5-SM q in [-15,15] everywhere (sign-magnitude only; no A5-U path)",
        "signed_value_ranges": {"weight": [-15, 15], "activation_signed": [-15, 15]},
        "block_size": 4,
        "local_exponent_bits": 3,
        "local_exponent_range": [0, 7],
        "scale": "2^(E_base+d), exponent only; no fractional scale",
        "rounding": "round-to-nearest, ties-away-from-zero",
        "weight_policy": "B4 per output/tap block; GConv block never crosses spatial taps",
        "activation_policy": "A5-SM B4 for every activation; dynamic d, frozen per-stage E_base",
        "removed_requant_boundaries": ["enc_gconv_branch", "body0_pw", "body1_pw", "body2_pw", "body3_pw", "dec_gconv_branch"],
        "required_requant_boundaries": ["input", "stem", "enc_residual", "down", "body_gconv_to_pw", "body_residual", "reduce", "dec_residual", "head"],
        "pixel_unshuffle": "phase-major complete-block reorder; Down PW input weights permuted",
        "nearest": "copy mantissa and exponent without requantization",
        "accumulator": "wide reference; W5 qmax=15 and A5-SM qmax=15",
        "residual": "wide exponent-aligned add, ReLU6, then one A5-SM B4 requant",
        "rgb_head": "W5 B4 weights; wide accumulator output to sigmoid/LUT, no final A5 logits clamp",
        "activation_base_exponents": act_base,
    }
    packed = {}
    for name, module in model.named_modules():
        if isinstance(module, base.W5Conv):
            packed[name] = base.pack_w5_sign_magnitude(module.qweight)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    torch.save({"format": metadata["format"], "model_state": model.state_dict(), "packed_weights_sign_magnitude": packed, "metadata": metadata}, OUT_DIR / "model_w5a5sm_b4_v11_ptq.pt")
    (OUT_DIR / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {OUT_DIR / 'model_w5a5sm_b4_v11_ptq.pt'}", flush=True)


def run_video(model):
    cap = cv2.VideoCapture(str(VIDEO))
    width, height = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    VIDEO_OUT.parent.mkdir(parents=True, exist_ok=True)
    writer = cv2.VideoWriter(str(VIDEO_OUT), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    index = 0
    with torch.inference_mode():
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
                y = (model(x).clamp(0, 1)[0].permute(1, 2, 0) * 255.0 + 0.5).to(torch.uint8).cpu().numpy()
                writer.write(cv2.cvtColor(y, cv2.COLOR_RGB2BGR))
                index += 1
                if index == 1 or index % 100 == 0:
                    print(f"Processed {index}/{total or '?'} frames", flush=True)
        finally:
            cap.release()
            writer.release()
    return index, [width, height], fps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-video", action="store_true")
    args = parser.parse_args()
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required")
    base = load_base_script()
    _, fp32, payload = base.mxbase.load_base().load_source_model(CHECKPOINT)
    inputs = base.mxbase.calibration_inputs(base.mxbase.load_base(), VIDEO)
    print(f"Calibration inputs: {len(inputs)}", flush=True)
    act_base = calibrate_bases(base, fp32, inputs)
    model = NativeGroupMixNetV11(base, fp32, act_base).cuda().eval()
    save_artifact(base, model, act_base)
    with torch.inference_mode():
        smoke = model(inputs[-1])
    print(f"Smoke test OK: {tuple(smoke.shape)}", flush=True)
    if args.run_video:
        started = time.time()
        frames, size, fps = run_video(model)
        print(json.dumps({"output": str(VIDEO_OUT), "frames": frames, "size": size, "fps": fps, "elapsed_seconds": time.time() - started}, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
