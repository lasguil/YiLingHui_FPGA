"""NativeGroupMixNet W4A4-MX-B4 post-training quantization.

This is a separate hardware-oriented reference path.  It follows
docs/ml/量化tmp.md: B4 mantissas, a per-layer base exponent plus a 3-bit
per-block delta, spatially meaningful GConv blocks, and exponent-preserving
PixelUnshuffle/nearest operations.  It does not modify the FP32 model or the
standard PTQ implementations.
"""
from __future__ import annotations

import argparse
import hashlib
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
from torch.nn import functional as F
from PIL import Image


HERE = Path(__file__).resolve().parent
STUDENTS = HERE.parents[1]
PROJECT = HERE.parents[3]
RUN = STUDENTS / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
BASE = HERE / "quantize_ptq.py"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
OUT_DIR = RUN / "ptq_mx_int4_b4_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_mx_int4_b4.mp4"

QMAX = 7
DELTA_MAX = 7


def load_base():
    spec = importlib.util.spec_from_file_location("native_groupmix_mx_b4_base", BASE)
    if spec is None or spec.loader is None:
        raise ImportError(BASE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fold_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d):
    bias = torch.zeros_like(bn.running_mean) if conv.bias is None else conv.bias
    gain = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    return (conv.weight * gain.reshape(-1, 1, 1, 1)).detach(), ((bias - bn.running_mean) * gain + bn.bias).detach()


def round_away(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(x.abs() + 0.5)


def block_exponent(amax: torch.Tensor) -> torch.Tensor:
    safe = torch.clamp(amax, min=2.0 ** -30)
    result = torch.ceil(torch.log2(safe / QMAX)).to(torch.int64)
    return torch.where(amax > 0, result, torch.zeros_like(result))


def mx_quantize_real(values: torch.Tensor, base: int):
    """Quantize C-multiple-of-4 tensors into q[B,C,H,W] and d[B,C/4,H,W]."""
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"B4 requires channels divisible by 4, got {c}")
    blocks = values.reshape(b, c // 4, 4, h, w)
    amax = blocks.abs().amax(dim=2)
    e_star = block_exponent(amax)
    delta = (e_star - base).clamp(0, DELTA_MAX)
    exponent = base + delta
    scale = torch.pow(torch.tensor(2.0, device=values.device), exponent.float())
    q = round_away(blocks / scale.unsqueeze(2)).clamp(-QMAX, QMAX).to(torch.int64)
    return q.reshape_as(values), delta.to(torch.int64)


def mx_reconstruct(q: torch.Tensor, delta: torch.Tensor, base: int):
    b, c, h, w = q.shape
    blocks = q.reshape(b, c // 4, 4, h, w)
    scale = torch.pow(torch.tensor(2.0, device=q.device), (base + delta).float())
    return (blocks * scale.unsqueeze(2)).reshape_as(q).float()


def choose_base(block_values: list[torch.Tensor]) -> tuple[int, float]:
    """Search the base exponent that minimizes block reconstruction MSE."""
    e_min, e_max = 999, -999
    for values in block_values:
        amax = values.reshape(values.shape[0], values.shape[1] // 4, 4, values.shape[2], values.shape[3]).abs().amax(dim=2)
        e = block_exponent(amax)
        e_min = min(e_min, int(e.min().item()))
        e_max = max(e_max, int(e.max().item()))
    if e_max < e_min:
        return 0, 0.0
    best_base, best_error = 0, float("inf")
    for base in range(e_min - 1, e_max + 1):
        error = 0.0
        count = 0
        for values in block_values:
            q, d = mx_quantize_real(values, base)
            recon = mx_reconstruct(q, d, base)
            error += float((recon - values).square().sum().item())
            count += values.numel()
        mse = error / max(count, 1)
        if mse < best_error:
            best_base, best_error = base, mse
    return best_base, best_error


def trace_fp32(model, x):
    values = {}
    padded, (ph, pw) = model._pad_to_4(x)
    values["input"] = F.pixel_unshuffle(padded, 2)
    y = F.relu6(model.stem_norm(model.stem(values["input"])))
    values["stem"] = y
    branch = F.relu6(model.enc.norm(model.enc.gconv(y)))
    values["enc_gconv"] = branch
    y = F.relu6(y + branch)
    values["enc"] = y
    y = F.pixel_unshuffle(y, 2)
    y = F.relu6(model.down_norm(model.down(y)))
    values["down"] = y
    for i, block in enumerate(model.body):
        branch = F.relu6(block.gconv_norm(block.gconv(y)))
        values[f"body{i}_gconv"] = branch
        branch = block.pw_norm(block.pw(branch))
        values[f"body{i}_pw"] = branch
        y = F.relu6(y + branch)
        values[f"body{i}"] = y
    y = F.relu6(model.reduce_norm(model.reduce(y)))
    values["reduce"] = y
    y = F.interpolate(y, scale_factor=2, mode="nearest")
    branch = F.relu6(model.dec.norm(model.dec.gconv(y)))
    values["dec_gconv"] = branch
    y = F.relu6(y + branch)
    values["dec"] = y
    y = model.head_norm(model.head(y))
    values["head"] = y
    y = F.interpolate(y, scale_factor=2, mode="nearest")
    values["rgb_logits"] = model.rgb(y)
    return values


def phase_major_unshuffle(q: torch.Tensor, d: torch.Tensor):
    """Rearrange complete C16 B4 blocks by spatial phase into C64."""
    b, c, h, w = q.shape
    qstd = F.pixel_unshuffle(q, 2).reshape(b, c, 4, h // 2, w // 2)
    qphase = qstd.permute(0, 2, 1, 3, 4).reshape(b, c * 4, h // 2, w // 2)
    nb = d.shape[1]
    dstd = F.pixel_unshuffle(d, 2).reshape(b, nb, 4, h // 2, w // 2)
    dphase = dstd.permute(0, 2, 1, 3, 4).reshape(b, nb * 4, h // 2, w // 2)
    return qphase, dphase


def nearest2_integer(x: torch.Tensor) -> torch.Tensor:
    """Nearest 2x copy for integer mantissa/exponent maps (no re-quantization)."""
    return x.repeat_interleave(2, dim=2).repeat_interleave(2, dim=3)


def permute_down_weight(weight: torch.Tensor):
    """Convert standard PixelUnshuffle channel order to phase-major order."""
    out, cin, _, _ = weight.shape
    if cin != 64:
        raise ValueError(cin)
    standard = weight.reshape(out, 16, 4, 1, 1)
    return standard.permute(0, 2, 1, 3, 4).reshape_as(weight)


class MXConv(nn.Module):
    def __init__(self, weight, bias, groups, base_values: list[torch.Tensor], kind: str):
        super().__init__()
        self.groups = groups
        self.kind = kind
        self.out_channels = weight.shape[0]
        self.group_channels = weight.shape[1]
        if kind == "pw":
            if weight.shape[1] % 4:
                raise ValueError(weight.shape)
            canonical = weight.reshape(weight.shape[0], weight.shape[1] // 4, 4)
        elif kind == "gconv":
            if weight.shape[1] % 4:
                raise ValueError(weight.shape)
            canonical = weight.reshape(weight.shape[0], weight.shape[1] // 4, 4, 3, 3).permute(0, 3, 1, 2, 4)
            # [out, tap, block, four] after collapsing the two kernel axes.
            canonical = weight.permute(0, 2, 3, 1).reshape(weight.shape[0], 9, weight.shape[1] // 4, 4)
        else:
            raise ValueError(kind)
        self.kind = kind
        # Weight blocks are independent across output/tap; choose one base for
        # the layer, then quantize the canonical layout exactly.
        base, _ = choose_weight_base(canonical)
        amax = canonical.abs().amax(dim=-1)
        e_star = block_exponent(amax)
        delta = (e_star - base).clamp(0, DELTA_MAX)
        scale = torch.pow(torch.tensor(2.0, device=weight.device), (base + delta).float()).unsqueeze(-1)
        q = round_away(canonical / scale).clamp(-QMAX, QMAX).to(torch.int8)
        self.register_buffer("qweight", q)
        self.register_buffer("weight_delta", delta.to(torch.int8))
        self.register_buffer("bias", bias.detach().cuda())
        self.weight_base = int(base)
        self.padding = 1 if kind == "gconv" else 0

    def accumulate(self, xq, xd, xbase: int):
        # CUDA does not implement einsum/baddbmm for integer tensors.  The raw
        # Dot4 products are tiny integers, so float32 represents every product
        # and sum exactly here; round back to int64 before exponent shifts and
        # accumulation.  This remains GPU execution and does not change the
        # integer arithmetic result.
        xq = xq.to(torch.float32)
        xd = xd.to(torch.int64)
        if self.kind == "pw":
            blocks = self.qweight.shape[1]
            acc = torch.zeros(xq.shape[0], self.out_channels, xq.shape[2], xq.shape[3], device=xq.device, dtype=torch.int64)
            for n in range(blocks):
                partial = torch.einsum("bkhw,ok->bohw", xq[:, n * 4:(n + 1) * 4], self.qweight[:, n, :].to(torch.float32)).round().to(torch.int64)
                shift = xd[:, n].unsqueeze(1) + self.weight_delta[:, n].to(torch.int64).view(1, -1, 1, 1)
                acc = acc + torch.bitwise_left_shift(partial, shift)
        else:
            _, _, h, w = xq.shape
            ocpg = self.out_channels // self.groups
            nb = self.qweight.shape[2]
            padded_q = F.pad(xq, (1, 1, 1, 1), mode="reflect")
            # im2col/unfold also has no CUDA Long implementation.  Deltas are
            # 3-bit integers, so unfold them as float32 and restore exactly.
            padded_d = F.pad(xd.to(torch.float32), (1, 1, 1, 1), mode="reflect")
            qwin = F.unfold(padded_q, 3).reshape(xq.shape[0], self.groups, nb, 4, 9, h * w).permute(0, 1, 4, 2, 3, 5).reshape(xq.shape[0], self.groups, 9, nb, 4, h, w)
            total_nb = xd.shape[1]
            dwin = F.unfold(padded_d, 3).round().to(torch.int64).reshape(xq.shape[0], total_nb, 9, h * w).permute(0, 2, 1, 3).reshape(xq.shape[0], 9, total_nb, h, w)
            acc = torch.zeros(xq.shape[0], self.out_channels, h, w, device=xq.device, dtype=torch.int64)
            for group in range(self.groups):
                partial = torch.einsum(
                    "btnkhw,otnk->botnhw",
                    qwin[:, group],
                    self.qweight[group * ocpg:(group + 1) * ocpg].to(torch.float32),
                ).round().to(torch.int64)
                group_dwin = dwin[:, :, group * nb:(group + 1) * nb]
                shift = group_dwin.unsqueeze(1) + self.weight_delta[group * ocpg:(group + 1) * ocpg].to(torch.int64).unsqueeze(0).unsqueeze(-1).unsqueeze(-1)
                group_acc = torch.bitwise_left_shift(partial, shift).sum(dim=(2, 3))
                acc[:, group * ocpg:(group + 1) * ocpg] = group_acc
        acc_exp = int(xbase + self.weight_base)
        bias_q = round_away(self.bias / (2.0 ** acc_exp)).to(torch.int64)
        return acc + bias_q.reshape(1, -1, 1, 1), acc_exp

    def forward_mx(self, xq, xd, xbase: int, out_base: int, relu6: bool):
        acc, acc_exp = self.accumulate(xq, xd, xbase)
        real = acc.float() * (2.0 ** acc_exp)
        if relu6:
            real = real.clamp(0.0, 6.0)
        return mx_quantize_real(real, out_base)


def choose_weight_base(canonical: torch.Tensor):
    # canonical: [out, blocks, 4] or [out, taps, blocks, 4]
    values = canonical.reshape(-1, 4).unsqueeze(0).unsqueeze(-1)
    e = block_exponent(values.abs().amax(dim=2))
    e_min, e_max = int(e.min().item()), int(e.max().item())
    best, best_mse = 0, float("inf")
    for base in range(e_min - 1, e_max + 1):
        amax = canonical.abs().amax(dim=-1)
        d = (block_exponent(amax) - base).clamp(0, DELTA_MAX)
        scale = torch.pow(torch.tensor(2.0, device=canonical.device), (base + d).float()).unsqueeze(-1)
        q = round_away(canonical / scale).clamp(-QMAX, QMAX)
        mse = float((q * scale - canonical).square().mean().item())
        if mse < best_mse:
            best, best_mse = base, mse
    return best, best_mse


class MXNativeGroupMixNet(nn.Module):
    def __init__(self, fp32, act_base: dict[str, int]):
        super().__init__()
        self.act_base = act_base
        self.stem = MXConv(*fold_bn(fp32.stem, fp32.stem_norm), 1, [], "pw")
        self.enc = MXConv(*fold_bn(fp32.enc.gconv, fp32.enc.norm), 2, [], "gconv")
        down_w, down_b = fold_bn(fp32.down, fp32.down_norm)
        down_w = permute_down_weight(down_w)
        self.down = MXConv(down_w, down_b, 1, [], "pw")
        self.body_gconv = nn.ModuleList()
        self.body_pw = nn.ModuleList()
        for block in fp32.body:
            self.body_gconv.append(MXConv(*fold_bn(block.gconv, block.gconv_norm), 4, [], "gconv"))
            self.body_pw.append(MXConv(*fold_bn(block.pw, block.pw_norm), 1, [], "pw"))
        self.reduce = MXConv(*fold_bn(fp32.reduce, fp32.reduce_norm), 1, [], "pw")
        self.dec = MXConv(*fold_bn(fp32.dec.gconv, fp32.dec.norm), 2, [], "gconv")
        self.head = MXConv(*fold_bn(fp32.head, fp32.head_norm), 1, [], "pw")
        self.rgb = MXConv(fp32.rgb.weight.detach(), fp32.rgb.bias.detach(), 1, [], "gconv")

    def residual(self, skip_q, skip_d, skip_base, branch_q, branch_d, branch_base, out_base):
        skip = mx_reconstruct(skip_q, skip_d, skip_base)
        branch = mx_reconstruct(branch_q, branch_d, branch_base)
        return mx_quantize_real((skip + branch).clamp(0.0, 6.0), out_base)

    def forward(self, x):
        h, w = x.shape[-2:]
        padded, (ph, pw) = self._pad_to_4(x)
        input_values = F.pixel_unshuffle(padded, 2)
        qx, dx = mx_quantize_real(input_values, self.act_base["input"])
        yq, yd = self.stem.forward_mx(qx, dx, self.act_base["input"], self.act_base["stem"], True)
        bq, bd = self.enc.forward_mx(yq, yd, self.act_base["stem"], self.act_base["enc_gconv"], True)
        yq, yd = self.residual(yq, yd, self.act_base["stem"], bq, bd, self.act_base["enc_gconv"], self.act_base["enc"])
        yq, yd = phase_major_unshuffle(yq, yd)
        yq, yd = self.down.forward_mx(yq, yd, self.act_base["enc"], self.act_base["down"], True)
        for i, (gconv, pw) in enumerate(zip(self.body_gconv, self.body_pw)):
            in_name = "down" if i == 0 else f"body{i - 1}"
            bq, bd = gconv.forward_mx(yq, yd, self.act_base[in_name], self.act_base[f"body{i}_gconv"], True)
            bq, bd = pw.forward_mx(bq, bd, self.act_base[f"body{i}_gconv"], self.act_base[f"body{i}_pw"], False)
            yq, yd = self.residual(yq, yd, self.act_base[in_name], bq, bd, self.act_base[f"body{i}_pw"], self.act_base[f"body{i}"])
        yq, yd = self.reduce.forward_mx(yq, yd, self.act_base["body3"], self.act_base["reduce"], True)
        yq = nearest2_integer(yq)
        yd = nearest2_integer(yd)
        bq, bd = self.dec.forward_mx(yq, yd, self.act_base["reduce"], self.act_base["dec_gconv"], True)
        yq, yd = self.residual(yq, yd, self.act_base["reduce"], bq, bd, self.act_base["dec_gconv"], self.act_base["dec"])
        yq, yd = self.head.forward_mx(yq, yd, self.act_base["dec"], self.act_base["head"], False)
        yq = nearest2_integer(yq)
        yd = nearest2_integer(yd)
        logits_acc, logits_exp = self.rgb.accumulate(yq, yd, self.act_base["head"])
        logits = logits_acc.float() * (2.0 ** logits_exp)
        output = torch.sigmoid(logits)
        if ph or pw:
            output = output[..., :h, :w]
        return output

    @staticmethod
    def _pad_to_4(x):
        h, w = x.shape[-2:]
        ph, pw = (-h) % 4, (-w) % 4
        if ph or pw:
            x = F.pad(x, (0, pw, 0, ph), mode="reflect")
        return x, (ph, pw)


def image_paths():
    roots = [STUDENTS / "data/datasets/coco20k/source", STUDENTS / "data/datasets/div2k/source/DIV2K_train_HR", STUDENTS / "data/datasets/flickr2k/source"]
    return sorted(p for root in roots if root.is_dir() for p in root.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})


def calibration_inputs(base, video_path):
    paths = image_paths()
    if not paths:
        raise RuntimeError("No local calibration images")
    inputs = []
    for index in np.linspace(0, len(paths) - 1, min(96, len(paths)), dtype=int):
        with Image.open(paths[int(index)]) as image:
            image = image.convert("RGB").resize((256, 256), Image.Resampling.BILINEAR)
            array = np.asarray(image, dtype=np.uint8)
        inputs.append(torch.from_numpy(array.copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))
    cap = cv2.VideoCapture(str(video_path))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    wanted = set(np.linspace(0, max(0, total - 1), 16, dtype=int).tolist())
    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if i in wanted:
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            inputs.append(torch.from_numpy(np.ascontiguousarray(rgb).copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))
        i += 1
    cap.release()
    return inputs


def calibrate_bases(fp32, inputs):
    names = ["input", "stem", "enc_gconv", "enc", "down"]
    for i in range(4):
        names.extend([f"body{i}_gconv", f"body{i}_pw", f"body{i}"])
    names.extend(["reduce", "dec_gconv", "dec", "head"])
    sample = inputs[:min(16, len(inputs))]
    traces = []
    ranges = {name: [999, -999] for name in names}
    with torch.inference_mode():
        for x in sample:
            trace = trace_fp32(fp32, x)
            traces.append(trace)
            for name in names:
                values = trace[name]
                b, c, h, w = values.shape
                e = block_exponent(values.reshape(b, c // 4, 4, h, w).abs().amax(dim=2))
                ranges[name][0] = min(ranges[name][0], int(e.min().item()))
                ranges[name][1] = max(ranges[name][1], int(e.max().item()))
    bases = {}
    for name in names:
        candidates = range(ranges[name][0] - 1, ranges[name][1] + 1)
        best, best_mse = 0, float("inf")
        for base in candidates:
            mse = 0.0
            count = 0
            for trace in traces:
                q, d = mx_quantize_real(trace[name], base)
                recon = mx_reconstruct(q, d, base)
                mse += float((recon - trace[name]).square().sum().item())
                count += trace[name].numel()
            mse /= max(count, 1)
            if mse < best_mse:
                best, best_mse = base, mse
        bases[name] = int(best)
        print(f"base {name}: E={best} mse={best_mse:.8g}", flush=True)
    return bases


def packed_int4(q):
    # Signed INT4 with zero-point 0: store the low nibble of the two's
    # complement representation, not offset-binary (+8) values.
    v = (q.detach().cpu().flatten().to(torch.int16) & 0xF).numpy().astype(np.uint8)
    if v.size % 2:
        v = np.concatenate([v, np.zeros(1, dtype=np.uint8)])
    return (v[0::2] | (v[1::2] << 4)).tobytes()


def model_sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_artifact(model, fp32, act_base, checkpoint):
    metadata = {
        "format": "native_groupmix_mx_int4_b4_ptq",
        "source_checkpoint": str(checkpoint),
        "source_step": 20000,
        "generator": "NativeGroupMixNet",
        "parameters": 19255,
        "weight_mantissa": "signed INT4 [-7,7]",
        "activation_mantissa": "signed INT4 [-7,7]",
        "packed_int4": "two's-complement low nibble; zero-point 0",
        "block_size": 4,
        "local_exponent_bits": 3,
        "local_exponent_range": [0, 7],
        "scale": "2^(E_base + d)",
        "rounding": "round-to-nearest, ties-away-from-zero",
        "weight_policy": "B4 per output/tap block; GConv block never crosses spatial taps",
        "activation_policy": "B4 per pixel/channel block; dynamic d, frozen per-layer E_base",
        "pixel_unshuffle": "phase-major complete-block reorder; Down PW input weights permuted to preserve FP32 semantics",
        "nearest": "copy mantissa and exponent without requantization",
        "accumulator": "INT64 reference for INT32-safe shifted partial sums; layer base E_A+E_W",
        "residual": "dequantized exponent-aligned wide add, ReLU6, then one B4 requant",
        "rgb_head": "W4 B4 weights; wide accumulator output to sigmoid/LUT, no final A4 logits clamp",
        "mx_block_scale": True,
        "activation_base_exponents": act_base,
        "source_model_sha256": model_sha(HERE / "model.py"),
        "source_checkpoint_sha256": model_sha(checkpoint),
    }
    layers = {}
    packed = {}
    for name, module in model.named_modules():
        if isinstance(module, MXConv):
            layers[name] = {
                "kind": module.kind,
                "groups": module.groups,
                "weight_base_exponent": module.weight_base,
                "qweight_shape": list(module.qweight.shape),
                "weight_delta_shape": list(module.weight_delta.shape),
                "weight_delta_values": module.weight_delta.detach().cpu().tolist(),
            }
            packed[name] = packed_int4(module.qweight)
    metadata["layers"] = layers
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    artifact = OUT_DIR / "model_mx_int4_b4_ptq.pt"
    torch.save({
        "format": metadata["format"],
        "model_state": model.state_dict(),
        "packed_weights": packed,
        "metadata": metadata,
    }, artifact)
    (OUT_DIR / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {artifact}", flush=True)
    return artifact


def run_video(fp32, model, input_path, output_path):
    cap = cv2.VideoCapture(str(input_path))
    if not cap.isOpened():
        raise RuntimeError(input_path)
    width, height = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps, total = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0, int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    writer = cv2.VideoWriter(str(output_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    if not writer.isOpened():
        cap.release()
        raise RuntimeError(output_path)
    preview = None
    count = 0
    with torch.inference_mode():
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                x = torch.from_numpy(np.ascontiguousarray(rgb).copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
                y = model(x).clamp(0, 1)
                bgr = cv2.cvtColor((y[0].permute(1, 2, 0) * 255 + .5).to(torch.uint8).cpu().numpy(), cv2.COLOR_RGB2BGR)
                writer.write(bgr)
                if count == 400:
                    preview = bgr.copy()
                count += 1
                if count == 1 or count % 100 == 0:
                    print(f"Processed {count}/{total or '?'} frames", flush=True)
        finally:
            cap.release()
            writer.release()
    if preview is not None:
        cv2.imwrite(str(OUT_DIR / "preview_frame_000400.jpg"), preview, [cv2.IMWRITE_JPEG_QUALITY, 95])
    return {"input": str(input_path), "output": str(output_path), "size": [width, height], "fps": fps, "frames": count}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, default=CHECKPOINT)
    parser.add_argument("--calibration-video", type=Path, default=VIDEO)
    parser.add_argument("--run-video", action="store_true")
    args = parser.parse_args()
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA required; refusing CPU MX PTQ")
    for path in (args.checkpoint, args.calibration_video, HERE / "model.py"):
        if not path.is_file():
            raise FileNotFoundError(path)
    _, fp32, payload = load_base().load_source_model(args.checkpoint)
    if payload.get("step") != 20000:
        raise ValueError(payload.get("step"))
    inputs = calibration_inputs(load_base(), args.calibration_video)
    print(f"Calibration inputs: {len(inputs)}", flush=True)
    act_base = calibrate_bases(fp32, inputs)
    model = MXNativeGroupMixNet(fp32, act_base).cuda().eval()
    artifact = save_artifact(model, fp32, act_base, args.checkpoint)
    # A native-size smoke test catches padding/layout errors before video work.
    with torch.inference_mode():
        smoke = model(inputs[-1])
    if tuple(smoke.shape[-2:]) != tuple(inputs[-1].shape[-2:]):
        raise AssertionError(f"Shape mismatch: {smoke.shape} vs {inputs[-1].shape}")
    print(f"Smoke test OK: {tuple(smoke.shape)}", flush=True)
    if args.run_video:
        started = time.time()
        result = run_video(fp32, model, args.calibration_video, VIDEO_OUT)
        result["artifact"] = str(artifact)
        result["elapsed_seconds"] = time.time() - started
        (OUT_DIR / "video_metadata.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
