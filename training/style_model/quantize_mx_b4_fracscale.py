"""NativeGroupMixNet W4A4-MX-B4 with one fractional scale bit.

Diagnostic/hardware-oriented version of the documented B4 scheme:
scale = m * 2^(E_base + d), m in {1.0, 1.5}, d in [0, 7].  It is kept in a
separate file so the original power-of-two and exact-float diagnostic paths
remain unchanged.
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

import quantize_mx_b4 as mxbase


HERE = Path(__file__).resolve().parent
STUDENTS = HERE.parents[1]
PROJECT = HERE.parents[3]
RUN = STUDENTS / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
OUT_DIR = RUN / "ptq_mx_int4_b4_fracscale_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_mx_int4_b4_fracscale.mp4"
QMAX = 7
M_VALUES = (1.0, 1.5)


def quantize_blocks(blocks: torch.Tensor, base: int, value_dim: int):
    """Quantize blocks with one shared m bit and one 3-bit delta per block."""
    if value_dim == 2:
        amax = blocks.abs().amax(dim=2)
        expand = lambda s: s.unsqueeze(2)
    elif value_dim == -1:
        amax = blocks.abs().amax(dim=-1)
        expand = lambda s: s.unsqueeze(-1)
    else:
        raise ValueError(value_dim)
    best_mse = torch.full_like(amax, float("inf"), dtype=torch.float32)
    best_q = torch.zeros_like(blocks, dtype=torch.int64)
    best_d = torch.zeros_like(amax, dtype=torch.int64)
    best_m = torch.zeros_like(amax, dtype=torch.int64)
    for m_bit, mantissa in enumerate(M_VALUES):
        for d in range(8):
            scale = float(mantissa) * (2.0 ** (base + d))
            q = mxbase.round_away(blocks / scale).clamp(-QMAX, QMAX).to(torch.int64)
            mse = (q.float() * scale - blocks).square().sum(dim=value_dim)
            take = mse < best_mse
            best_mse = torch.where(take, mse, best_mse)
            best_q = torch.where(expand(take), q, best_q)
            best_d = torch.where(take, torch.full_like(best_d, d), best_d)
            best_m = torch.where(take, torch.full_like(best_m, m_bit), best_m)
    return best_q, best_d, best_m


def reconstruct_blocks(q, d, m, base):
    scale = (1.0 + 0.5 * m.float()) * torch.pow(torch.tensor(2.0, device=q.device), (base + d).float())
    return q.float() * scale.unsqueeze(2 if q.ndim == 5 else -1)


def frac_quantize_real(values: torch.Tensor, base: int):
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"B4 requires channels divisible by 4, got {c}")
    blocks = values.reshape(b, c // 4, 4, h, w)
    q, d, m = quantize_blocks(blocks, base, 2)
    return q.reshape_as(values), d, m


def frac_reconstruct(q, d, m, base):
    blocks = q.reshape(q.shape[0], q.shape[1] // 4, 4, q.shape[2], q.shape[3])
    return reconstruct_blocks(blocks, d, m, base).reshape_as(q)


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
    ranges = {name: [999, -999] for name in names}
    with torch.inference_mode():
        for x in inputs[:min(16, len(inputs))]:
            trace = trace_fp32(fp32, x)
            traces.append(trace)
            for name in names:
                values = trace[name].reshape(trace[name].shape[0], trace[name].shape[1] // 4, 4, trace[name].shape[2], trace[name].shape[3])
                e = mxbase.block_exponent(values.abs().amax(dim=2))
                ranges[name][0] = min(ranges[name][0], int(e.min().item()))
                ranges[name][1] = max(ranges[name][1], int(e.max().item()))
    bases = {}
    for name in names:
        best, best_mse = 0, float("inf")
        for base in range(ranges[name][0] - 1, ranges[name][1] + 1):
            total, count = 0.0, 0
            for trace in traces:
                q, d, m = frac_quantize_real(trace[name], base)
                total += float((frac_reconstruct(q, d, m, base) - trace[name]).square().sum().item())
                count += trace[name].numel()
            mse = total / max(count, 1)
            if mse < best_mse:
                best, best_mse = base, mse
        bases[name] = int(best)
        print(f"base {name}: E={best} mse={best_mse:.8g}", flush=True)
    return bases


def phase_major_unshuffle(q, d, m):
    b, c, h, w = q.shape
    qstd = F.pixel_unshuffle(q, 2).reshape(b, c, 4, h // 2, w // 2)
    qphase = qstd.permute(0, 2, 1, 3, 4).reshape(b, c * 4, h // 2, w // 2)
    def move_scale(s):
        sstd = F.pixel_unshuffle(s.float(), 2).round().to(torch.int64).reshape(b, s.shape[1], 4, h // 2, w // 2)
        return sstd.permute(0, 2, 1, 3, 4).reshape(b, s.shape[1] * 4, h // 2, w // 2)
    return qphase, move_scale(d), move_scale(m)


def permute_down_weight(weight):
    return mxbase.permute_down_weight(weight)


def nearest2(q, d, m):
    op = lambda x: x.repeat_interleave(2, dim=2).repeat_interleave(2, dim=3)
    return op(q), op(d), op(m)


class FracConv(nn.Module):
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
        e = mxbase.block_exponent(canonical.abs().amax(dim=-1))
        best, best_mse = int(e.min().item()) - 1, float("inf")
        for base in range(int(e.min().item()) - 1, int(e.max().item()) + 1):
            q, d, m = quantize_blocks(canonical, base, -1)
            mse = float((reconstruct_blocks(q, d, m, base) - canonical).square().mean().item())
            if mse < best_mse:
                best, best_mse = base, mse
        q, d, m = quantize_blocks(canonical, best, -1)
        self.register_buffer("qweight", q.to(torch.int8))
        self.register_buffer("weight_delta", d.to(torch.int8))
        self.register_buffer("weight_m", m.to(torch.int8))
        self.register_buffer("bias", bias.detach().cuda())
        self.weight_base = int(best)
        self.padding = 1 if kind == "gconv" else 0

    @staticmethod
    def scales(d, m, base):
        return (1.0 + 0.5 * m.float()) * torch.pow(torch.tensor(2.0, device=d.device), (base + d).float())

    def accumulate(self, xq, xd, xm, xbase):
        xqf = xq.float()
        if self.kind == "pw":
            acc = torch.zeros(xq.shape[0], self.out_channels, xq.shape[2], xq.shape[3], device=xq.device)
            for n in range(self.qweight.shape[1]):
                partial = torch.einsum("bkhw,ok->bohw", xqf[:, n * 4:(n + 1) * 4], self.qweight[:, n].float())
                scale = self.scales(xd[:, n], xm[:, n], xbase).unsqueeze(1) * self.scales(self.weight_delta[:, n], self.weight_m[:, n], self.weight_base).reshape(1, -1, 1, 1)
                acc += partial * scale
            return acc + self.bias.reshape(1, -1, 1, 1)
        _, _, h, w = xq.shape
        ocpg, nb = self.out_channels // self.groups, self.qweight.shape[2]
        qwin = F.unfold(F.pad(xqf, (1, 1, 1, 1), mode="reflect"), 3).reshape(xq.shape[0], self.groups, nb, 4, 9, h * w)
        qwin = qwin.permute(0, 1, 4, 2, 3, 5).reshape(xq.shape[0], self.groups, 9, nb, 4, h, w)
        def unfold_blocks(v):
            total = v.shape[1]
            z = F.unfold(F.pad(v.float(), (1, 1, 1, 1), mode="reflect"), 3).round().to(torch.int64)
            return z.reshape(xq.shape[0], total, 9, h * w).permute(0, 2, 1, 3).reshape(xq.shape[0], 9, total, h, w)
        dwin, mwin = unfold_blocks(xd), unfold_blocks(xm)
        acc = torch.zeros(xq.shape[0], self.out_channels, h, w, device=xq.device)
        for group in range(self.groups):
            start, end = group * ocpg, (group + 1) * ocpg
            partial = torch.einsum("btnkhw,otnk->botnhw", qwin[:, group], self.qweight[start:end].float())
            xs = self.scales(dwin[:, :, group * nb:(group + 1) * nb], mwin[:, :, group * nb:(group + 1) * nb], xbase).unsqueeze(1)
            ws = self.scales(self.weight_delta[start:end], self.weight_m[start:end], self.weight_base).unsqueeze(0).unsqueeze(-1).unsqueeze(-1)
            acc[:, start:end] = (partial * xs * ws).sum(dim=(2, 3))
        return acc + self.bias.reshape(1, -1, 1, 1)

    def forward_frac(self, xq, xd, xm, xbase, outbase, relu6):
        real = self.accumulate(xq, xd, xm, xbase)
        if relu6:
            real = real.clamp(0.0, 6.0)
        return frac_quantize_real(real, outbase)


class FracNativeGroupMixNet(nn.Module):
    def __init__(self, fp32, act_base):
        super().__init__()
        self.act_base = act_base
        self.stem = FracConv(*mxbase.fold_bn(fp32.stem, fp32.stem_norm), 1, "pw")
        self.enc = FracConv(*mxbase.fold_bn(fp32.enc.gconv, fp32.enc.norm), 2, "gconv")
        down_w, down_b = mxbase.fold_bn(fp32.down, fp32.down_norm)
        self.down = FracConv(permute_down_weight(down_w), down_b, 1, "pw")
        self.body_gconv, self.body_pw = nn.ModuleList(), nn.ModuleList()
        for block in fp32.body:
            self.body_gconv.append(FracConv(*mxbase.fold_bn(block.gconv, block.gconv_norm), 4, "gconv"))
            self.body_pw.append(FracConv(*mxbase.fold_bn(block.pw, block.pw_norm), 1, "pw"))
        self.reduce = FracConv(*mxbase.fold_bn(fp32.reduce, fp32.reduce_norm), 1, "pw")
        self.dec = FracConv(*mxbase.fold_bn(fp32.dec.gconv, fp32.dec.norm), 2, "gconv")
        self.head = FracConv(*mxbase.fold_bn(fp32.head, fp32.head_norm), 1, "pw")
        self.rgb = FracConv(fp32.rgb.weight.detach(), fp32.rgb.bias.detach(), 1, "gconv")

    @staticmethod
    def residual(q0, d0, m0, q1, d1, m1, b0, b1, bout):
        value = frac_reconstruct(q0, d0, m0, b0) + frac_reconstruct(q1, d1, m1, b1)
        return frac_quantize_real(value.clamp(0.0, 6.0), bout)

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
        q, d, m = frac_quantize_real(F.pixel_unshuffle(padded, 2), self.act_base["input"])
        q, d, m = self.stem.forward_frac(q, d, m, self.act_base["input"], self.act_base["stem"], True)
        bq, bd, bm = self.enc.forward_frac(q, d, m, self.act_base["stem"], self.act_base["enc_gconv"], True)
        q, d, m = self.residual(q, d, m, bq, bd, bm, self.act_base["stem"], self.act_base["enc_gconv"], self.act_base["enc"])
        q, d, m = phase_major_unshuffle(q, d, m)
        q, d, m = self.down.forward_frac(q, d, m, self.act_base["enc"], self.act_base["down"], True)
        for i, (gconv, pw) in enumerate(zip(self.body_gconv, self.body_pw)):
            name = "down" if i == 0 else f"body{i - 1}"
            bq, bd, bm = gconv.forward_frac(q, d, m, self.act_base[name], self.act_base[f"body{i}_gconv"], True)
            bq, bd, bm = pw.forward_frac(bq, bd, bm, self.act_base[f"body{i}_gconv"], self.act_base[f"body{i}_pw"], False)
            q, d, m = self.residual(q, d, m, bq, bd, bm, self.act_base[name], self.act_base[f"body{i}_pw"], self.act_base[f"body{i}"])
        q, d, m = self.reduce.forward_frac(q, d, m, self.act_base["body3"], self.act_base["reduce"], True)
        q, d, m = nearest2(q, d, m)
        bq, bd, bm = self.dec.forward_frac(q, d, m, self.act_base["reduce"], self.act_base["dec_gconv"], True)
        q, d, m = self.residual(q, d, m, bq, bd, bm, self.act_base["reduce"], self.act_base["dec_gconv"], self.act_base["dec"])
        q, d, m = self.head.forward_frac(q, d, m, self.act_base["dec"], self.act_base["head"], False)
        q, d, m = nearest2(q, d, m)
        logits = self.rgb.accumulate(q, d, m, self.act_base["head"])
        out = torch.sigmoid(logits)
        return out[..., :h, :w] if ph or pw else out


def load_video_prefix(count=32):
    cap = cv2.VideoCapture(str(VIDEO))
    values = []
    while len(values) < count:
        ok, frame = cap.read()
        if not ok:
            break
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        values.append(torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))
    cap.release()
    return values


def image_paths():
    roots = [STUDENTS / "data/datasets/coco20k/source", STUDENTS / "data/datasets/div2k/source/DIV2K_train_HR", STUDENTS / "data/datasets/flickr2k/source"]
    return sorted(p for root in roots if root.is_dir() for p in root.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})


def calibration_inputs(video_path):
    paths = image_paths()
    inputs = []
    for index in np.linspace(0, len(paths) - 1, min(96, len(paths)), dtype=int):
        with Image.open(paths[int(index)]) as image:
            array = np.asarray(image.convert("RGB").resize((256, 256), Image.Resampling.BILINEAR), dtype=np.uint8)
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
            inputs.append(torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))
        i += 1
    cap.release()
    return inputs


def save_artifact(model, act_base):
    metadata = {
        "format": "native_groupmix_mx_int4_b4_fracscale_ptq",
        "source_checkpoint": str(CHECKPOINT),
        "source_step": 20000,
        "generator": "NativeGroupMixNet",
        "parameters": 19255,
        "weight_mantissa": "signed INT4 [-7,7]",
        "activation_mantissa": "signed INT4 [-7,7]",
        "block_size": 4,
        "local_exponent_bits": 3,
        "local_exponent_range": [0, 7],
        "fractional_scale_bits": 1,
        "fractional_scale_values": [1.0, 1.5],
        "scale": "m * 2^(E_base+d), m in {1,1.5}",
        "rounding": "round-to-nearest, ties-away-from-zero",
        "weight_policy": "B4 per output/tap block; GConv block never crosses spatial taps",
        "activation_policy": "B4 per pixel/channel block; dynamic m,d, frozen per-layer E_base",
        "pixel_unshuffle": "phase-major complete-block reorder; Down PW input weights permuted",
        "nearest": "copy mantissa, delta, and fractional scale bit without requantization",
        "accumulator": "wide reference; mA*mW represented by 4,6,9 over a common power-of-two base",
        "residual": "wide exponent/scale-aligned add, ReLU6, then one B4 requant",
        "rgb_head": "W4 B4 weights; wide accumulator output to sigmoid/LUT, no final A4 logits clamp",
        "activation_base_exponents": act_base,
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    torch.save({"format": metadata["format"], "model_state": model.state_dict(), "metadata": metadata}, OUT_DIR / "model_mx_int4_b4_fracscale_ptq.pt")
    (OUT_DIR / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {OUT_DIR / 'model_mx_int4_b4_fracscale_ptq.pt'}", flush=True)


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
    inputs = calibration_inputs(VIDEO)
    print(f"Calibration inputs: {len(inputs)}", flush=True)
    act_base = calibrate_bases(fp32, inputs)
    model = FracNativeGroupMixNet(fp32, act_base).cuda().eval()
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
