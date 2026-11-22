"""NativeGroupMixNet W5A5 B4 power-of-two microscaling experiment.

Independent experiment based on the W5A5 sign-magnitude proposal:
one sign bit plus four magnitude bits, q in [-15, 15], B4 blocks, and only
power-of-two scales scale=2^(E_base+d).  Existing MX INT4 implementations are
not modified.
"""
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from PIL import Image

import quantize_mx_b4 as mxbase


HERE = Path(__file__).resolve().parent
STUDENTS = HERE.parents[1]
PROJECT = HERE.parents[3]
RUN = STUDENTS / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
OUT_DIR = RUN / "ptq_w5a5_b4_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_w5a5_b4.mp4"
QMAX = 15
DELTA_MAX = 7


def round_away(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(x.abs() + 0.5)


def block_exponent(amax: torch.Tensor) -> torch.Tensor:
    safe = torch.clamp(amax, min=2.0 ** -30)
    exponent = torch.ceil(torch.log2(safe / QMAX)).to(torch.int64)
    return torch.where(amax > 0, exponent, torch.zeros_like(exponent))


def quantize_blocks(blocks: torch.Tensor, base: int):
    """Quantize [..., 4, ...] blocks using signed magnitude-compatible S5."""
    amax = blocks.abs().amax(dim=2 if blocks.ndim == 5 else -1)
    e_star = block_exponent(amax)
    delta = (e_star - base).clamp(0, DELTA_MAX)
    scale = torch.pow(torch.tensor(2.0, device=blocks.device), (base + delta).float())
    q = round_away(blocks / scale.unsqueeze(2 if blocks.ndim == 5 else -1)).clamp(-QMAX, QMAX).to(torch.int64)
    return q, delta


def reconstruct_blocks(q: torch.Tensor, delta: torch.Tensor, base: int):
    scale = torch.pow(torch.tensor(2.0, device=q.device), (base + delta).float())
    return q.float() * scale.unsqueeze(2 if q.ndim == 5 else -1)


def quantize_real(values: torch.Tensor, base: int):
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"B4 requires channels divisible by 4, got {c}")
    blocks = values.reshape(b, c // 4, 4, h, w)
    q, d = quantize_blocks(blocks, base)
    return q.reshape_as(values), d


def reconstruct(q, d, base):
    blocks = q.reshape(q.shape[0], q.shape[1] // 4, 4, q.shape[2], q.shape[3])
    return reconstruct_blocks(blocks, d, base).reshape_as(q)


def choose_base(block_values):
    e_min, e_max = 999, -999
    for values in block_values:
        blocks = values.reshape(values.shape[0], values.shape[1] // 4, 4, values.shape[2], values.shape[3])
        e = block_exponent(blocks.abs().amax(dim=2))
        e_min = min(e_min, int(e.min().item()))
        e_max = max(e_max, int(e.max().item()))
    best, best_mse = 0, float("inf")
    for base in range(e_min - 1, e_max + 1):
        total, count = 0.0, 0
        for values in block_values:
            q, d = quantize_real(values, base)
            total += float((reconstruct(q, d, base) - values).square().sum().item())
            count += values.numel()
        mse = total / max(count, 1)
        if mse < best_mse:
            best, best_mse = base, mse
    return best, best_mse


def trace_fp32(model, x):
    values = {}
    padded, _ = model._pad_to_4(x)
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
    values["head"] = model.head_norm(model.head(y))
    y = F.interpolate(values["head"], scale_factor=2, mode="nearest")
    values["rgb_logits"] = model.rgb(y)
    return values


def calibrate_bases(fp32, inputs):
    names = ["input", "stem", "enc_gconv", "enc", "down"]
    for i in range(4):
        names += [f"body{i}_gconv", f"body{i}_pw", f"body{i}"]
    names += ["reduce", "dec_gconv", "dec", "head"]
    traces = []
    for x in inputs[:min(16, len(inputs))]:
        traces.append(trace_fp32(fp32, x))
    bases = {}
    for name in names:
        base, mse = choose_base([trace[name] for trace in traces])
        bases[name] = int(base)
        print(f"base {name}: E={base} mse={mse:.8g}", flush=True)
    return bases


def phase_major_unshuffle(q, d):
    b, c, h, w = q.shape
    qstd = F.pixel_unshuffle(q, 2).reshape(b, c, 4, h // 2, w // 2)
    qphase = qstd.permute(0, 2, 1, 3, 4).reshape(b, c * 4, h // 2, w // 2)
    def move(v):
        std = F.pixel_unshuffle(v.float(), 2).round().to(torch.int64).reshape(b, v.shape[1], 4, h // 2, w // 2)
        return std.permute(0, 2, 1, 3, 4).reshape(b, v.shape[1] * 4, h // 2, w // 2)
    return qphase, move(d)


def nearest2(q, d):
    op = lambda x: x.repeat_interleave(2, dim=2).repeat_interleave(2, dim=3)
    return op(q), op(d)


class W5Conv(nn.Module):
    def __init__(self, weight, bias, groups, kind):
        super().__init__()
        self.groups = groups
        self.kind = kind
        self.out_channels = weight.shape[0]
        self.group_channels = weight.shape[1]
        if self.group_channels % 4:
            raise ValueError(weight.shape)
        if kind == "pw":
            canonical = weight.reshape(weight.shape[0], weight.shape[1] // 4, 4)
        elif kind == "gconv":
            canonical = weight.permute(0, 2, 3, 1).reshape(weight.shape[0], 9, weight.shape[1] // 4, 4)
        else:
            raise ValueError(kind)
        base, mse = choose_weight_base(canonical)
        q, d = quantize_weight_blocks(canonical, base)
        self.register_buffer("qweight", q.to(torch.int8))
        self.register_buffer("weight_delta", d.to(torch.int8))
        self.register_buffer("weight_sign", (q < 0).to(torch.uint8))
        self.register_buffer("weight_magnitude", q.abs().to(torch.uint8))
        self.register_buffer("bias", bias.detach().cuda())
        self.weight_base = int(base)
        self.weight_mse = float(mse)
        self.padding = 1 if kind == "gconv" else 0

    def accumulate(self, xq, xd, xbase):
        xqf = xq.float()
        if self.kind == "pw":
            acc = torch.zeros(xq.shape[0], self.out_channels, xq.shape[2], xq.shape[3], device=xq.device)
            for n in range(self.qweight.shape[1]):
                partial = torch.einsum("bkhw,ok->bohw", xqf[:, n * 4:(n + 1) * 4], self.qweight[:, n].float())
                xs = torch.pow(torch.tensor(2.0, device=xq.device), (xbase + xd[:, n]).float()).unsqueeze(1)
                ws = torch.pow(torch.tensor(2.0, device=xq.device), (self.weight_base + self.weight_delta[:, n]).float()).reshape(1, -1, 1, 1)
                acc += partial * xs * ws
            return acc + self.bias.reshape(1, -1, 1, 1)
        _, _, h, w = xq.shape
        ocpg, nb = self.out_channels // self.groups, self.qweight.shape[2]
        qwin = F.unfold(F.pad(xqf, (1, 1, 1, 1), mode="reflect"), 3).reshape(xq.shape[0], self.groups, nb, 4, 9, h * w)
        qwin = qwin.permute(0, 1, 4, 2, 3, 5).reshape(xq.shape[0], self.groups, 9, nb, 4, h, w)
        def unfold_delta(v):
            total = v.shape[1]
            z = F.unfold(F.pad(v.float(), (1, 1, 1, 1), mode="reflect"), 3).round().to(torch.int64)
            return z.reshape(xq.shape[0], total, 9, h * w).permute(0, 2, 1, 3).reshape(xq.shape[0], 9, total, h, w)
        dwin = unfold_delta(xd)
        acc = torch.zeros(xq.shape[0], self.out_channels, h, w, device=xq.device)
        for group in range(self.groups):
            start, end = group * ocpg, (group + 1) * ocpg
            partial = torch.einsum("btnkhw,otnk->botnhw", qwin[:, group], self.qweight[start:end].float())
            dgroup = dwin[:, :, group * nb:(group + 1) * nb]
            xs = torch.pow(torch.tensor(2.0, device=xq.device), (xbase + dgroup).float()).unsqueeze(1)
            ws = torch.pow(torch.tensor(2.0, device=xq.device), (self.weight_base + self.weight_delta[start:end]).float()).unsqueeze(0).unsqueeze(-1).unsqueeze(-1)
            acc[:, start:end] = (partial * xs * ws).sum(dim=(2, 3))
        return acc + self.bias.reshape(1, -1, 1, 1)

    def forward_w5(self, xq, xd, xbase, outbase, relu6):
        real = self.accumulate(xq, xd, xbase)
        if relu6:
            real = real.clamp(0.0, 6.0)
        return quantize_real(real, outbase)


def quantize_weight_blocks(canonical, base):
    q, d = quantize_blocks(canonical, base)
    return q, d


def choose_weight_base(canonical):
    e = block_exponent(canonical.abs().amax(dim=-1))
    best, best_mse = 0, float("inf")
    for base in range(int(e.min().item()) - 1, int(e.max().item()) + 1):
        q, d = quantize_weight_blocks(canonical, base)
        recon = reconstruct_blocks(q, d, base)
        mse = float((recon - canonical).square().mean().item())
        if mse < best_mse:
            best, best_mse = base, mse
    return best, best_mse


class W5NativeGroupMixNet(nn.Module):
    def __init__(self, fp32, act_base):
        super().__init__()
        self.act_base = act_base
        self.stem = W5Conv(*mxbase.fold_bn(fp32.stem, fp32.stem_norm), 1, "pw")
        self.enc = W5Conv(*mxbase.fold_bn(fp32.enc.gconv, fp32.enc.norm), 2, "gconv")
        down_w, down_b = mxbase.fold_bn(fp32.down, fp32.down_norm)
        self.down = W5Conv(mxbase.permute_down_weight(down_w), down_b, 1, "pw")
        self.body_gconv, self.body_pw = nn.ModuleList(), nn.ModuleList()
        for block in fp32.body:
            self.body_gconv.append(W5Conv(*mxbase.fold_bn(block.gconv, block.gconv_norm), 4, "gconv"))
            self.body_pw.append(W5Conv(*mxbase.fold_bn(block.pw, block.pw_norm), 1, "pw"))
        self.reduce = W5Conv(*mxbase.fold_bn(fp32.reduce, fp32.reduce_norm), 1, "pw")
        self.dec = W5Conv(*mxbase.fold_bn(fp32.dec.gconv, fp32.dec.norm), 2, "gconv")
        self.head = W5Conv(*mxbase.fold_bn(fp32.head, fp32.head_norm), 1, "pw")
        self.rgb = W5Conv(fp32.rgb.weight.detach(), fp32.rgb.bias.detach(), 1, "gconv")

    @staticmethod
    def residual(q0, d0, q1, d1, b0, b1, bout):
        value = reconstruct(q0, d0, b0) + reconstruct(q1, d1, b1)
        return quantize_real(value.clamp(0.0, 6.0), bout)

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
        q, d = quantize_real(F.pixel_unshuffle(padded, 2), self.act_base["input"])
        q, d = self.stem.forward_w5(q, d, self.act_base["input"], self.act_base["stem"], True)
        bq, bd = self.enc.forward_w5(q, d, self.act_base["stem"], self.act_base["enc_gconv"], True)
        q, d = self.residual(q, d, bq, bd, self.act_base["stem"], self.act_base["enc_gconv"], self.act_base["enc"])
        q, d = phase_major_unshuffle(q, d)
        q, d = self.down.forward_w5(q, d, self.act_base["enc"], self.act_base["down"], True)
        for i, (gconv, pw) in enumerate(zip(self.body_gconv, self.body_pw)):
            name = "down" if i == 0 else f"body{i - 1}"
            bq, bd = gconv.forward_w5(q, d, self.act_base[name], self.act_base[f"body{i}_gconv"], True)
            bq, bd = pw.forward_w5(bq, bd, self.act_base[f"body{i}_gconv"], self.act_base[f"body{i}_pw"], False)
            q, d = self.residual(q, d, bq, bd, self.act_base[name], self.act_base[f"body{i}_pw"], self.act_base[f"body{i}"])
        q, d = self.reduce.forward_w5(q, d, self.act_base["body3"], self.act_base["reduce"], True)
        q, d = nearest2(q, d)
        bq, bd = self.dec.forward_w5(q, d, self.act_base["reduce"], self.act_base["dec_gconv"], True)
        q, d = self.residual(q, d, bq, bd, self.act_base["reduce"], self.act_base["dec_gconv"], self.act_base["dec"])
        q, d = self.head.forward_w5(q, d, self.act_base["dec"], self.act_base["head"], False)
        q, d = nearest2(q, d)
        logits = self.rgb.accumulate(q, d, self.act_base["head"])
        out = torch.sigmoid(logits)
        return out[..., :h, :w] if ph or pw else out


def pack_w5_sign_magnitude(q):
    codes = (q.detach().cpu().flatten().to(torch.int16).abs() & 0xF).numpy().astype(np.uint8)
    signs = (q.detach().cpu().flatten().numpy() < 0).astype(np.uint8)
    codes |= signs << 4
    out = bytearray((len(codes) * 5 + 7) // 8)
    for index, code in enumerate(codes.tolist()):
        bit = index * 5
        byte = bit >> 3
        shift = bit & 7
        value = int(code) << shift
        out[byte] |= value & 0xFF
        if byte + 1 < len(out):
            out[byte + 1] |= (value >> 8) & 0xFF
    return bytes(out)


def save_artifact(model, act_base):
    metadata = {
        "format": "native_groupmix_w5a5_b4_pow2_ptq",
        "source_checkpoint": str(CHECKPOINT),
        "source_step": 20000,
        "generator": "NativeGroupMixNet",
        "parameters": 19255,
        "weight_format": "sign-magnitude 5-bit: 1 sign + 4 magnitude",
        "activation_format": "sign-magnitude 5-bit: 1 sign + 4 magnitude",
        "signed_value_range": [-15, 15],
        "block_size": 4,
        "local_exponent_bits": 3,
        "local_exponent_range": [0, 7],
        "scale": "2^(E_base+d), exponent only; no fractional scale",
        "rounding": "round-to-nearest, ties-away-from-zero",
        "weight_policy": "B4 per output/tap block; GConv block never crosses spatial taps",
        "activation_policy": "B4 per pixel/channel block; dynamic d, frozen per-layer E_base",
        "pixel_unshuffle": "phase-major complete-block reorder; Down PW input weights permuted",
        "nearest": "copy mantissa and exponent without requantization",
        "accumulator": "wide reference; qmax=15 and dA+dW<=14 remain INT32-safe for this topology",
        "residual": "wide exponent-aligned add, ReLU6, then one B4 requant",
        "rgb_head": "W5 B4 weights; wide accumulator output to sigmoid/LUT, no final A5 logits clamp",
        "activation_base_exponents": act_base,
    }
    packed = {}
    for name, module in model.named_modules():
        if isinstance(module, W5Conv):
            packed[name] = pack_w5_sign_magnitude(module.qweight)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    torch.save({"format": metadata["format"], "model_state": model.state_dict(), "packed_weights_sign_magnitude": packed, "metadata": metadata}, OUT_DIR / "model_w5a5_b4_ptq.pt")
    (OUT_DIR / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {OUT_DIR / 'model_w5a5_b4_ptq.pt'}", flush=True)


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
    _, fp32, payload = mxbase.load_base().load_source_model(CHECKPOINT)
    inputs = mxbase.calibration_inputs(mxbase.load_base(), VIDEO)
    print(f"Calibration inputs: {len(inputs)}", flush=True)
    act_base = calibrate_bases(fp32, inputs)
    model = W5NativeGroupMixNet(fp32, act_base).cuda().eval()
    save_artifact(model, act_base)
    with torch.inference_mode():
        smoke = model(inputs[-1])
    print(f"Smoke test OK: {tuple(smoke.shape)}", flush=True)
    if args.run_video:
        started = time.time()
        frames, size, fps = run_video(model)
        print(json.dumps({"output": str(VIDEO_OUT), "frames": frames, "size": size, "fps": fps, "elapsed_seconds": time.time() - started}, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
