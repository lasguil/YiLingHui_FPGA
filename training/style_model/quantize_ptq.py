"""PTQ reference/export for the frozen NativeGroupMixNet-v1 checkpoint.

This file is intentionally separate from the FP32 training code.  It creates
two independent post-training artifacts:

* standard symmetric W8A8 INT8 (no MX block scales); and
* signed W4A4 INT4 with per-output-channel power-of-two weight scales and
  per-tensor power-of-two activation scales.

The reference path keeps integer codes at every quantized operator boundary,
uses INT32-like integer accumulation, and dequantizes only to perform the
CUDA convolution primitive.  This makes the rounding/saturation behavior
observable without requiring a custom CUDA kernel.
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
from PIL import Image, ImageOps
from torch import nn
from torch.nn import functional as F


HERE = Path(__file__).resolve().parent
STUDENTS = HERE.parents[1]
PROJECT = HERE.parents[3]
CHECKPOINT = STUDENTS / "runs/native_groupmix_main256_20260910_20k/checkpoints/step_020000.pt"
MODEL_SOURCE = HERE / "model.py"
CALIB_VIDEO = PROJECT / "ml/our_data/480p/our_data_480p_merged.mp4"
DATA_ROOT = STUDENTS / "data/datasets"
OUTPUT_ROOT = STUDENTS / "runs/native_groupmix_main256_20260910_20k"
VIDEO_OUTPUT_ROOT = PROJECT / "ml/our_data/480p"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_source_model(checkpoint: Path):
    spec = importlib.util.spec_from_file_location("native_groupmix_ptq_source", MODEL_SOURCE)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot import {MODEL_SOURCE}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    payload = torch.load(checkpoint, map_location="cpu", weights_only=True)
    if payload.get("step") != 20000:
        raise ValueError(f"Expected step 20000 checkpoint, got {payload.get('step')}")
    config = payload.get("config", {})
    if config.get("generator") != "NativeGroupMixNet":
        raise ValueError(f"Unexpected generator: {config.get('generator')}")
    model = module.NativeGroupMixNet().cuda().eval()
    model.load_state_dict(payload["model"], strict=True)
    if sum(p.numel() for p in model.parameters()) != 19255:
        raise ValueError("Unexpected NativeGroupMixNet parameter count")
    return module, model, payload


def fold_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> tuple[torch.Tensor, torch.Tensor]:
    if conv.bias is None:
        conv_bias = torch.zeros_like(bn.running_mean)
    else:
        conv_bias = conv.bias
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    weight = conv.weight * scale.reshape(-1, 1, 1, 1)
    bias = (conv_bias - bn.running_mean) * scale + bn.bias
    return weight.detach(), bias.detach()


def trace_fp32(model, x: torch.Tensor) -> dict[str, torch.Tensor]:
    """Trace exactly the activation boundaries used by the quantized path."""
    x, (ph, pw) = model._pad_to_4(x)
    values: dict[str, torch.Tensor] = {}
    y = F.pixel_unshuffle(x, 2)
    y = F.relu6(model.stem_norm(model.stem(y)))
    values["stem"] = y

    branch = F.relu6(model.enc.norm(model.enc.gconv(y)))
    values["enc_gconv"] = branch
    y = F.relu6(y + branch)
    values["enc"] = y

    y = F.pixel_unshuffle(y, 2)
    y = F.relu6(model.down_norm(model.down(y)))
    values["down"] = y

    for index, block in enumerate(model.body):
        branch = F.relu6(block.gconv_norm(block.gconv(y)))
        values[f"body{index}_gconv"] = branch
        branch = block.pw_norm(block.pw(branch))
        values[f"body{index}_pw"] = branch
        y = F.relu6(y + branch)
        values[f"body{index}"] = y

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
    logits = model.rgb(y)
    values["rgb_logits"] = logits
    output = torch.sigmoid(logits)
    if ph or pw:
        output = output[..., : x.shape[-2] - ph if ph else x.shape[-2],
                        : x.shape[-1] - pw if pw else x.shape[-1]]
    values["output"] = output
    return values


def image_paths() -> list[Path]:
    roots = [
        DATA_ROOT / "coco20k/source",
        DATA_ROOT / "div2k/source/DIV2K_train_HR",
        DATA_ROOT / "flickr2k/source",
    ]
    paths: list[Path] = []
    for root in roots:
        if root.is_dir():
            paths.extend(p for p in root.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
    return sorted(paths)


def load_calibration_inputs(video_path: Path, image_count: int = 96, video_count: int = 16):
    inputs: list[torch.Tensor] = []
    paths = image_paths()
    if not paths:
        raise RuntimeError("No local calibration images found")
    indices = np.linspace(0, len(paths) - 1, min(image_count, len(paths)), dtype=int)
    for index in indices:
        with Image.open(paths[int(index)]) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            image = ImageOps.fit(image, (256, 256), method=Image.Resampling.BILINEAR)
            array = np.asarray(image, dtype=np.uint8)
        inputs.append(torch.from_numpy(array.copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))

    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise RuntimeError(f"Cannot open calibration video: {video_path}")
    total = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    wanted = set(np.linspace(0, max(0, total - 1), video_count, dtype=int).tolist())
    index = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        if index in wanted:
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            inputs.append(torch.from_numpy(np.ascontiguousarray(rgb).copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))
        index += 1
    capture.release()
    if not inputs:
        raise RuntimeError("No calibration inputs")
    return inputs


def pow2_scale(amax: float, qmax: int) -> float:
    if not math.isfinite(amax) or amax <= 0.0:
        return 1.0 / qmax
    return float(2.0 ** math.ceil(math.log2(amax / qmax)))


def ordinary_scale(amax: float, qmax: int) -> float:
    if not math.isfinite(amax) or amax <= 0.0:
        return 1.0 / qmax
    return float(max(amax / qmax, 1e-12))


def calibrate(model, inputs: list[torch.Tensor], bits: int) -> tuple[dict[str, float], dict[str, float]]:
    qmax = 127 if bits == 8 else 7
    maxima: dict[str, float] = {}
    with torch.inference_mode():
        for index, x in enumerate(inputs, 1):
            traced = trace_fp32(model, x)
            for name, value in traced.items():
                current = float(value.detach().abs().amax().item())
                maxima[name] = max(maxima.get(name, 0.0), current)
            if index % 16 == 0 or index == len(inputs):
                print(f"Calibrated {index}/{len(inputs)} inputs", flush=True)
    make_scale = ordinary_scale if bits == 8 else pow2_scale
    scales = {name: make_scale(value, qmax) for name, value in maxima.items()}
    scales["input"] = 1.0 / qmax
    return scales, maxima


def quantize_weight(weight: torch.Tensor, bits: int) -> tuple[torch.Tensor, torch.Tensor]:
    qmax = 127 if bits == 8 else 7
    amax = weight.abs().amax(dim=tuple(range(1, weight.ndim)), keepdim=True)
    if bits == 8:
        scale = torch.clamp(amax / qmax, min=1e-12)
    else:
        scale = torch.pow(torch.tensor(2.0, device=weight.device),
                          torch.ceil(torch.log2(torch.clamp(amax / qmax, min=2.0 ** -30))))
    q = torch.round(weight / scale).clamp(-qmax, qmax).to(torch.int8)
    return q, scale.reshape(-1)


def quantize_code(x: torch.Tensor, scale: float, bits: int) -> torch.Tensor:
    qmax = 127 if bits == 8 else 7
    return torch.round(x / scale).clamp(-qmax, qmax)


class QConv(nn.Module):
    def __init__(self, weight: torch.Tensor, bias: torch.Tensor, groups: int,
                 bits: int, output_bits: int | None = None):
        super().__init__()
        qweight, wscale = quantize_weight(weight.cuda(), bits)
        self.register_buffer("qweight", qweight)
        self.register_buffer("weight_scale", wscale)
        self.register_buffer("bias", bias.cuda())
        self.groups = groups
        self.bits = bits
        self.qmax = 127 if bits == 8 else 7
        self.output_bits = bits if output_bits is None else output_bits
        self.output_qmax = 127 if self.output_bits == 8 else 7
        self.padding = weight.shape[-1] // 2

    def forward(self, xq: torch.Tensor, in_scale: float, out_scale: float) -> torch.Tensor:
        # qweight and xq are integer codes represented as float for the CUDA
        # convolution primitive.  The following is the INT32-domain equation:
        # acc = conv(qx, qw) + round(bias / (Sx * Sw)).
        acc = F.conv2d(
            F.pad(xq, (self.padding,) * 4, mode="reflect") if self.padding else xq,
            self.qweight.float(),
            bias=None,
            groups=self.groups,
        )
        bias_q = torch.round(self.bias / (in_scale * self.weight_scale))
        acc = acc + bias_q.reshape(1, -1, 1, 1)
        factor = (in_scale * self.weight_scale / out_scale).reshape(1, -1, 1, 1)
        return torch.round(acc * factor).clamp(-self.output_qmax, self.output_qmax)


class QuantizedNativeGroupMixNet(nn.Module):
    def __init__(self, fp32, scales: dict[str, float], bits: int,
                 rgb_output_bits: int | None = None):
        super().__init__()
        self.bits = bits
        self.qmax = 127 if bits == 8 else 7
        self.scales = scales
        self.stem = QConv(*fold_bn(fp32.stem, fp32.stem_norm), 1, bits)
        self.enc = QConv(*fold_bn(fp32.enc.gconv, fp32.enc.norm), 2, bits)
        self.down = QConv(*fold_bn(fp32.down, fp32.down_norm), 1, bits)
        self.body_gconv = nn.ModuleList()
        self.body_pw = nn.ModuleList()
        for block in fp32.body:
            self.body_gconv.append(QConv(*fold_bn(block.gconv, block.gconv_norm), 4, bits))
            self.body_pw.append(QConv(*fold_bn(block.pw, block.pw_norm), 1, bits))
        self.reduce = QConv(*fold_bn(fp32.reduce, fp32.reduce_norm), 1, bits)
        self.dec = QConv(*fold_bn(fp32.dec.gconv, fp32.dec.norm), 2, bits)
        self.head = QConv(*fold_bn(fp32.head, fp32.head_norm), 1, bits)
        self.rgb = QConv(fp32.rgb.weight.detach(), fp32.rgb.bias.detach(), 1, bits,
                         output_bits=rgb_output_bits)

    def relu6(self, q: torch.Tensor, in_scale: float, out_scale: float) -> torch.Tensor:
        return torch.round((q * in_scale).clamp(0.0, 6.0) / out_scale).clamp(-self.qmax, self.qmax)

    def residual(self, skip: torch.Tensor, skip_scale: float,
                 branch: torch.Tensor, branch_scale: float, out_scale: float) -> torch.Tensor:
        skip_aligned = torch.round(skip * (skip_scale / out_scale))
        branch_aligned = torch.round(branch * (branch_scale / out_scale))
        summed = (skip_aligned + branch_aligned) * out_scale
        return torch.round(summed.clamp(0.0, 6.0) / out_scale).clamp(-self.qmax, self.qmax)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        input_scale = self.scales["input"]
        xq = quantize_code(x, input_scale, self.bits)
        h, w = x.shape[-2:]
        ph, pw = (-h) % 4, (-w) % 4
        if ph or pw:
            xq = F.pad(xq, (0, pw, 0, ph), mode="reflect")

        y = F.pixel_unshuffle(xq, 2)
        y = self.stem(y, input_scale, self.scales["stem"])
        y = self.relu6(y, self.scales["stem"], self.scales["stem"])
        branch = self.enc(y, self.scales["stem"], self.scales["enc_gconv"])
        branch = self.relu6(branch, self.scales["enc_gconv"], self.scales["enc_gconv"])
        y = self.residual(y, self.scales["stem"], branch, self.scales["enc_gconv"], self.scales["enc"])

        y = F.pixel_unshuffle(y * self.scales["enc"], 2)
        y = quantize_code(y, self.scales["enc"], self.bits)
        y = self.down(y, self.scales["enc"], self.scales["down"])
        y = self.relu6(y, self.scales["down"], self.scales["down"])

        for index, (gconv, pw) in enumerate(zip(self.body_gconv, self.body_pw)):
            input_name = "down" if index == 0 else f"body{index - 1}"
            input_scale_i = self.scales[input_name]
            branch = gconv(y, input_scale_i, self.scales[f"body{index}_gconv"])
            branch = self.relu6(branch, self.scales[f"body{index}_gconv"], self.scales[f"body{index}_gconv"])
            branch = pw(branch, self.scales[f"body{index}_gconv"], self.scales[f"body{index}_pw"])
            y = self.residual(y, input_scale_i, branch, self.scales[f"body{index}_pw"], self.scales[f"body{index}"])

        y = self.reduce(y, self.scales["body3"], self.scales["reduce"])
        y = self.relu6(y, self.scales["reduce"], self.scales["reduce"])
        y = F.interpolate(y * self.scales["reduce"], scale_factor=2, mode="nearest")
        y = quantize_code(y, self.scales["reduce"], self.bits)

        branch = self.dec(y, self.scales["reduce"], self.scales["dec_gconv"])
        branch = self.relu6(branch, self.scales["dec_gconv"], self.scales["dec_gconv"])
        y = self.residual(y, self.scales["reduce"], branch, self.scales["dec_gconv"], self.scales["dec"])
        y = self.head(y, self.scales["dec"], self.scales["head"])
        y = F.interpolate(y * self.scales["head"], scale_factor=2, mode="nearest")
        y = quantize_code(y, self.scales["head"], self.bits)
        y = self.rgb(y, self.scales["head"], self.scales["rgb_logits"])
        logits = y * self.scales["rgb_logits"]
        output = torch.sigmoid(logits)
        if ph or pw:
            output = output[..., :h, :w]
        return output


def pack_int4(q: torch.Tensor) -> bytes:
    values = (q.detach().cpu().flatten().to(torch.int16) + 8).clamp(0, 15).numpy().astype(np.uint8)
    if values.size % 2:
        values = np.concatenate([values, np.zeros(1, dtype=np.uint8)])
    return (values[0::2] | (values[1::2] << 4)).tobytes()


def collect_quant_metadata(model: QuantizedNativeGroupMixNet, bits: int, scales, maxima, checkpoint):
    weights = {}
    packed = {}
    for name, module in model.named_modules():
        if isinstance(module, QConv):
            weights[name] = {
                "shape": list(module.qweight.shape),
                "qmin": -module.qmax,
                "qmax": module.qmax,
                "weight_scale": module.weight_scale.detach().cpu().tolist(),
            }
            if bits == 4:
                packed[name] = pack_int4(module.qweight)
    return {
        "format": "standard_symmetric_w8a8_ptq" if bits == 8 else "signed_w4a4_ptq_power2",
        "source_checkpoint": str(checkpoint),
        "source_step": 20000,
        "generator": "NativeGroupMixNet",
        "parameters": 19255,
        "weight_bits": bits,
        "activation_bits": bits,
        "weight_policy": "per-output-channel symmetric; ordinary scale" if bits == 8 else "per-output-channel symmetric; power-of-two scale",
        "activation_policy": "per-tensor symmetric static; ordinary scale" if bits == 8 else "per-tensor symmetric; power-of-two scale",
        "mx_block_scale": False,
        "accumulator": "INT32-domain reference accumulation with round and saturation",
        "bn": "all 14 Conv+BN pairs folded before weight quantization; no runtime BN",
        "residual": "skip and branch are aligned to the output activation domain before INT32-like add, ReLU6, and saturation",
        "padding": "reflect pad-to-4 before PixelUnshuffle; reflect convolution padding; crop back to original size",
        "external_io": "RGB float [0,1] in reference, RGB888 output",
        "calibration_scales": scales,
        "calibration_amax": maxima,
        "quantized_weights": weights,
        "packed_int4_nibbles": "q+8, low nibble first" if bits == 4 else None,
        "source_model_sha256": sha256(MODEL_SOURCE),
        "source_checkpoint_sha256": sha256(checkpoint),
    }


def save_preview(image: np.ndarray, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), image, [cv2.IMWRITE_JPEG_QUALITY, 95])


def run_video(fp32, quant_models, input_path: Path, output_paths: dict[int, Path], preview_frame: int = 400):
    capture = cv2.VideoCapture(str(input_path))
    if not capture.isOpened():
        raise RuntimeError(f"Cannot open video: {input_path}")
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(capture.get(cv2.CAP_PROP_FPS)) or 30.0
    expected = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    writers = {}
    for bits, path in output_paths.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
        if not writer.isOpened():
            capture.release()
            raise RuntimeError(f"Cannot create output: {path}")
        writers[bits] = writer

    metrics = {bits: {"count": 0, "mae": 0.0, "mse": 0.0, "max_abs": 0.0} for bits in quant_models}
    previews = {}
    frame_index = 0
    with torch.inference_mode():
        try:
            while True:
                ok, frame = capture.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                x = torch.from_numpy(np.ascontiguousarray(rgb).copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
                reference = fp32(x)
                for bits, model in quant_models.items():
                    output = model(x).clamp(0.0, 1.0)
                    diff = (output - reference).abs()
                    if frame_index < 32:
                        metrics[bits]["count"] += int(diff.numel())
                        metrics[bits]["mae"] += float(diff.sum().item())
                        metrics[bits]["mse"] += float(diff.square().sum().item())
                        metrics[bits]["max_abs"] = max(metrics[bits]["max_abs"], float(diff.max().item()))
                    styled = (output[0].permute(1, 2, 0) * 255.0 + 0.5).to(torch.uint8).cpu().numpy()
                    bgr = cv2.cvtColor(styled, cv2.COLOR_RGB2BGR)
                    writers[bits].write(bgr)
                    if frame_index == preview_frame:
                        previews[bits] = bgr.copy()
                frame_index += 1
                if frame_index == 1 or frame_index % 100 == 0:
                    print(f"Processed {frame_index}/{expected or '?'} frames", flush=True)
        finally:
            capture.release()
            for writer in writers.values():
                writer.release()
    if frame_index == 0:
        raise RuntimeError("Video has no readable frames")
    for bits, values in metrics.items():
        if values["count"]:
            values["mae"] /= values["count"]
            values["mse"] /= values["count"]
            values["psnr_db"] = 10.0 * math.log10(1.0 / max(values["mse"], 1e-12))
    return frame_index, (width, height, fps), metrics, previews


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, default=CHECKPOINT)
    parser.add_argument("--calibration-video", type=Path, default=CALIB_VIDEO)
    parser.add_argument("--input-video", type=Path, default=CALIB_VIDEO)
    parser.add_argument("--output-root", type=Path, default=OUTPUT_ROOT)
    parser.add_argument("--run-video", action="store_true")
    args = parser.parse_args()

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required; refusing CPU quantization")
    for path in (args.checkpoint, args.calibration_video, MODEL_SOURCE):
        if not path.is_file():
            raise FileNotFoundError(path)

    torch.backends.cudnn.benchmark = True
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    _, fp32, payload = load_source_model(args.checkpoint)
    print(f"Loaded FP32 checkpoint step={payload['step']} params=19255", flush=True)
    inputs = load_calibration_inputs(args.calibration_video)
    print(f"Calibration set: {len(inputs)} inputs", flush=True)

    quant_models = {}
    metadata_by_bits = {}
    for bits, name in ((8, "ptq_int8_step020000"), (4, "ptq_w4a4_step020000")):
        print(f"--- calibrating {name} ---", flush=True)
        scales, maxima = calibrate(fp32, inputs, bits)
        model = QuantizedNativeGroupMixNet(fp32, scales, bits).cuda().eval()
        # There are 14 Conv+BN pairs plus the final RGB Conv without BN.
        if len([m for m in model.modules() if isinstance(m, QConv)]) != 15:
            raise AssertionError("Expected 15 quantized convolutions (14 BN-folded + RGB head)")
        quant_models[bits] = model
        metadata_by_bits[bits] = (name, collect_quant_metadata(model, bits, scales, maxima, args.checkpoint))

    for bits, (name, metadata) in metadata_by_bits.items():
        output_dir = args.output_root / name
        output_dir.mkdir(parents=True, exist_ok=True)
        artifact = output_dir / ("model_int8_ptq.pt" if bits == 8 else "model_w4a4_ptq.pt")
        packed_weights = {
            module_name: pack_int4(module.qweight)
            for module_name, module in quant_models[bits].named_modules()
            if isinstance(module, QConv) and bits == 4
        }
        torch.save({
            "format": metadata["format"],
            "bits": bits,
            "model_state": quant_models[bits].state_dict(),
            "packed_weights": packed_weights,
            "metadata": metadata,
        }, artifact)
        (output_dir / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Saved {artifact}", flush=True)

    if args.run_video:
        output_paths = {
            8: VIDEO_OUTPUT_ROOT / "native_groupmix_step020000_ptq_int8.mp4",
            4: VIDEO_OUTPUT_ROOT / "native_groupmix_step020000_ptq_w4a4.mp4",
        }
        started = time.time()
        frames, (width, height, fps), metrics, previews = run_video(fp32, quant_models, args.input_video, output_paths)
        for bits, image in previews.items():
            name = metadata_by_bits[bits][0]
            save_preview(image, args.output_root / name / "preview_frame_000400.jpg")
        video_metadata = {
            "input": str(args.input_video),
            "source_size": [width, height],
            "output_size": [width, height],
            "fps": fps,
            "frames": frames,
            "outputs": {str(bits): str(path) for bits, path in output_paths.items()},
            "fp32_comparison_first_32_frames": metrics,
            "elapsed_seconds": time.time() - started,
        }
        (args.output_root / "ptq_video_comparison.json").write_text(
            json.dumps(video_metadata, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(json.dumps(video_metadata, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
