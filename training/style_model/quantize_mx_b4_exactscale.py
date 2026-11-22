"""Diagnostic B4 INT4 path with exact per-block max/7 floating-point scales.

This is intentionally separate from quantize_mx_b4.py.  It keeps the same
B4/W4A4 topology, block layout, residuals, and no-requantization data moves,
but replaces power-of-two scales with scale=max(abs(block))/7.  It is a
diagnostic only and is not the proposed final FPGA format.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

import quantize_mx_b4 as mxbase


HERE = Path(__file__).resolve().parent
STUDENTS = HERE.parents[1]
PROJECT = HERE.parents[3]
RUN = STUDENTS / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
OUT_DIR = RUN / "ptq_mx_int4_b4_exactscale_step020000"
VIDEO_OUT = PROJECT / "ml/our_data/480p/native_groupmix_step020000_ptq_mx_int4_b4_exactscale.mp4"
QMAX = 7


def exact_quantize_real(values: torch.Tensor):
    b, c, h, w = values.shape
    if c % 4:
        raise ValueError(f"B4 requires channels divisible by 4, got {c}")
    blocks = values.reshape(b, c // 4, 4, h, w)
    amax = blocks.abs().amax(dim=2)
    scale = amax / QMAX
    scale = torch.where(amax > 0, scale, torch.ones_like(scale))
    q = mxbase.round_away(blocks / scale.unsqueeze(2)).clamp(-QMAX, QMAX).to(torch.int64)
    return q.reshape_as(values), scale


def exact_reconstruct(q: torch.Tensor, scale: torch.Tensor):
    b, c, h, w = q.shape
    blocks = q.reshape(b, c // 4, 4, h, w)
    return (blocks * scale.unsqueeze(2)).reshape_as(q).float()


def exact_unshuffle(q, scale):
    b, c, h, w = q.shape
    qstd = F.pixel_unshuffle(q, 2).reshape(b, c, 4, h // 2, w // 2)
    qphase = qstd.permute(0, 2, 1, 3, 4).reshape(b, c * 4, h // 2, w // 2)
    nb = scale.shape[1]
    sstd = F.pixel_unshuffle(scale, 2).reshape(b, nb, 4, h // 2, w // 2)
    sphase = sstd.permute(0, 2, 1, 3, 4).reshape(b, nb * 4, h // 2, w // 2)
    return qphase, sphase


def nearest2_integer(q, scale):
    return (
        q.repeat_interleave(2, dim=2).repeat_interleave(2, dim=3),
        scale.repeat_interleave(2, dim=2).repeat_interleave(2, dim=3),
    )


class ExactConv(nn.Module):
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
        amax = canonical.abs().amax(dim=-1)
        wscale = torch.where(amax > 0, amax / QMAX, torch.ones_like(amax))
        qweight = mxbase.round_away(canonical / wscale.unsqueeze(-1)).clamp(-QMAX, QMAX).to(torch.int8)
        self.register_buffer("qweight", qweight)
        self.register_buffer("weight_scale", wscale)
        self.register_buffer("bias", bias.detach().cuda())
        self.padding = 1 if kind == "gconv" else 0

    def accumulate(self, xq, xs):
        xqf = xq.float()
        if self.kind == "pw":
            blocks = self.qweight.shape[1]
            acc = torch.zeros(xq.shape[0], self.out_channels, xq.shape[2], xq.shape[3], device=xq.device)
            for n in range(blocks):
                partial = torch.einsum("bkhw,ok->bohw", xqf[:, n * 4:(n + 1) * 4], self.qweight[:, n, :].float())
                scale = xs[:, n].unsqueeze(1) * self.weight_scale[:, n].reshape(1, -1, 1, 1)
                acc = acc + partial * scale
            return acc + self.bias.reshape(1, -1, 1, 1)

        _, _, h, w = xq.shape
        ocpg = self.out_channels // self.groups
        nb = self.qweight.shape[2]
        padded_q = F.pad(xqf, (1, 1, 1, 1), mode="reflect")
        padded_s = F.pad(xs, (1, 1, 1, 1), mode="reflect")
        qwin = F.unfold(padded_q, 3).reshape(xq.shape[0], self.groups, nb, 4, 9, h * w)
        qwin = qwin.permute(0, 1, 4, 2, 3, 5).reshape(xq.shape[0], self.groups, 9, nb, 4, h, w)
        total_nb = xs.shape[1]
        swin = F.unfold(padded_s, 3).reshape(xq.shape[0], total_nb, 9, h * w)
        swin = swin.permute(0, 2, 1, 3).reshape(xq.shape[0], 9, total_nb, h, w)
        acc = torch.zeros(xq.shape[0], self.out_channels, h, w, device=xq.device)
        for group in range(self.groups):
            start, end = group * ocpg, (group + 1) * ocpg
            partial = torch.einsum("btnkhw,otnk->botnhw", qwin[:, group], self.qweight[start:end].float())
            xscale = swin[:, :, group * nb:(group + 1) * nb].unsqueeze(1)
            wscale = self.weight_scale[start:end].unsqueeze(0).unsqueeze(-1).unsqueeze(-1)
            acc[:, start:end] = (partial * xscale * wscale).sum(dim=(2, 3))
        return acc + self.bias.reshape(1, -1, 1, 1)

    def forward_exact(self, xq, xs, relu6):
        real = self.accumulate(xq, xs)
        if relu6:
            real = real.clamp(0.0, 6.0)
        return exact_quantize_real(real)


class ExactScaleNativeGroupMixNet(nn.Module):
    def __init__(self, fp32):
        super().__init__()
        self.stem = ExactConv(*mxbase.fold_bn(fp32.stem, fp32.stem_norm), 1, "pw")
        self.enc = ExactConv(*mxbase.fold_bn(fp32.enc.gconv, fp32.enc.norm), 2, "gconv")
        down_w, down_b = mxbase.fold_bn(fp32.down, fp32.down_norm)
        self.down = ExactConv(mxbase.permute_down_weight(down_w), down_b, 1, "pw")
        self.body_gconv = nn.ModuleList()
        self.body_pw = nn.ModuleList()
        for block in fp32.body:
            self.body_gconv.append(ExactConv(*mxbase.fold_bn(block.gconv, block.gconv_norm), 4, "gconv"))
            self.body_pw.append(ExactConv(*mxbase.fold_bn(block.pw, block.pw_norm), 1, "pw"))
        self.reduce = ExactConv(*mxbase.fold_bn(fp32.reduce, fp32.reduce_norm), 1, "pw")
        self.dec = ExactConv(*mxbase.fold_bn(fp32.dec.gconv, fp32.dec.norm), 2, "gconv")
        self.head = ExactConv(*mxbase.fold_bn(fp32.head, fp32.head_norm), 1, "pw")
        self.rgb = ExactConv(fp32.rgb.weight.detach(), fp32.rgb.bias.detach(), 1, "gconv")

    @staticmethod
    def _pad_to_4(x):
        h, w = x.shape[-2:]
        ph, pw = (-h) % 4, (-w) % 4
        if ph or pw:
            x = F.pad(x, (0, pw, 0, ph), mode="reflect")
        return x, (ph, pw)

    @staticmethod
    def residual(skip_q, skip_s, branch_q, branch_s):
        return exact_quantize_real((exact_reconstruct(skip_q, skip_s) + exact_reconstruct(branch_q, branch_s)).clamp(0.0, 6.0))

    def forward(self, x):
        h, w = x.shape[-2:]
        padded, (ph, pw) = self._pad_to_4(x)
        q, s = exact_quantize_real(F.pixel_unshuffle(padded, 2))
        q, s = self.stem.forward_exact(q, s, True)
        bq, bs = self.enc.forward_exact(q, s, True)
        q, s = self.residual(q, s, bq, bs)
        q, s = exact_unshuffle(q, s)
        q, s = self.down.forward_exact(q, s, True)
        for i, (gconv, pw) in enumerate(zip(self.body_gconv, self.body_pw)):
            bq, bs = gconv.forward_exact(q, s, True)
            bq, bs = pw.forward_exact(bq, bs, False)
            q, s = self.residual(q, s, bq, bs)
        q, s = self.reduce.forward_exact(q, s, True)
        q, s = nearest2_integer(q, s)
        bq, bs = self.dec.forward_exact(q, s, True)
        q, s = self.residual(q, s, bq, bs)
        q, s = self.head.forward_exact(q, s, False)
        q, s = nearest2_integer(q, s)
        logits = self.rgb.accumulate(q, s)
        output = torch.sigmoid(logits)
        if ph or pw:
            output = output[..., :h, :w]
        return output


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


def run_video(model, fp32, output_path):
    cap = cv2.VideoCapture(str(VIDEO))
    if not cap.isOpened():
        raise RuntimeError(VIDEO)
    width, height = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    writer = cv2.VideoWriter(str(output_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
    if not writer.isOpened():
        raise RuntimeError(output_path)
    with torch.inference_mode():
        index = 0
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
                y = model(x).clamp(0.0, 1.0)
                styled = (y[0].permute(1, 2, 0) * 255.0 + 0.5).to(torch.uint8).cpu().numpy()
                writer.write(cv2.cvtColor(styled, cv2.COLOR_RGB2BGR))
                index += 1
                if index == 1 or index % 100 == 0:
                    print(f"Processed {index}/{total or '?'} frames", flush=True)
        finally:
            cap.release()
            writer.release()
    return index, (width, height, fps)


def save_artifact(model, checkpoint):
    metadata = {
        "format": "native_groupmix_int4_b4_exact_float_scale_diagnostic",
        "source_checkpoint": str(checkpoint),
        "generator": "NativeGroupMixNet",
        "block_size": 4,
        "mantissa": "signed INT4 [-7,7]",
        "scale": "exact max(abs(block))/7 float; diagnostic only",
        "same_as_mx_b4": ["B4 layout", "GConv tap boundaries", "phase-major PixelUnshuffle", "nearest copy", "BN fold", "residual flow"],
        "not_hardware_final_format": True,
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    torch.save({"format": metadata["format"], "model_state": model.state_dict(), "metadata": metadata}, OUT_DIR / "model_mx_int4_b4_exactscale_diagnostic.pt")
    (OUT_DIR / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {OUT_DIR / 'model_mx_int4_b4_exactscale_diagnostic.pt'}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-video", action="store_true")
    args = parser.parse_args()
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required")
    _, fp32, payload = mxbase.load_base().load_source_model(CHECKPOINT)
    model = ExactScaleNativeGroupMixNet(fp32).cuda().eval()
    save_artifact(model, CHECKPOINT)
    with torch.inference_mode():
        smoke = model(torch.rand(1, 3, 256, 256, device="cuda"))
    print(f"Smoke test OK: {tuple(smoke.shape)}", flush=True)
    metrics = {"mae": [], "rmse": []}
    with torch.inference_mode():
        for x in load_video_prefix(32):
            ref = torch.sigmoid(mxbase.trace_fp32(fp32, x)["rgb_logits"])[..., :x.shape[-2], :x.shape[-1]]
            diff = model(x) - ref
            metrics["mae"].append(float(diff.abs().mean().item()))
            metrics["rmse"].append(float(diff.square().mean().sqrt().item()))
    summary = {
        "checkpoint_step": payload["step"],
        "video_first_32_frames": {k: float(np.mean(v)) for k, v in metrics.items()},
    }
    summary["video_first_32_frames"]["psnr_db"] = 10.0 * math.log10(1.0 / max(summary["video_first_32_frames"]["rmse"] ** 2, 1e-12))
    (OUT_DIR / "diagnostic_metrics.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    if args.run_video:
        started = time.time()
        frames, (width, height, fps) = run_video(model, fp32, VIDEO_OUT)
        summary["video"] = {"output": str(VIDEO_OUT), "frames": frames, "size": [width, height], "fps": fps, "elapsed_seconds": time.time() - started}
        (OUT_DIR / "diagnostic_metrics.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
