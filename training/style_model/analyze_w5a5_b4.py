"""Numerical error analysis for the independent W5A5/B4 PTQ experiment."""
from __future__ import annotations

import importlib.util
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np
import torch


HERE = Path(__file__).resolve().parent
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
ARTIFACT = RUN / "ptq_w5a5_b4_step020000/model_w5a5_b4_ptq.pt"
VIDEO = HERE.parents[2] / "our_data/480p/our_data_480p_merged.mp4"
OUT = RUN / "ptq_w5a5_b4_numeric_analysis.json"


def load_w5():
    sys.path.insert(0, str(HERE))
    spec = importlib.util.spec_from_file_location("w5a5_b4_model", HERE / "quantize_w5a5_b4.py")
    if spec is None or spec.loader is None:
        raise ImportError(HERE / "quantize_w5a5_b4.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def metric(ref: torch.Tensor, value: torch.Tensor) -> dict[str, float]:
    diff = value.float() - ref.float()
    mse = float(diff.square().mean().item())
    ref_rms = float(ref.float().square().mean().sqrt().item())
    return {
        "mae": float(diff.abs().mean().item()),
        "rmse": math.sqrt(mse),
        "relative_rmse": math.sqrt(mse) / max(ref_rms, 1e-12),
        "psnr_db": 10.0 * math.log10(1.0 / max(mse, 1e-12)),
        "max_abs": float(diff.abs().max().item()),
    }


def activation_row(w5, values: torch.Tensor, base: int) -> dict[str, float]:
    q, delta = w5.quantize_real(values, base)
    recon = w5.reconstruct(q, delta, base)
    row = metric(values, recon)
    row["q_saturation_fraction"] = float((q.abs() >= w5.QMAX).float().mean().item())
    row["q_zero_fraction"] = float((q == 0).float().mean().item())
    row["delta_mean"] = float(delta.float().mean().item())
    row["delta_max_fraction"] = float((delta == w5.DELTA_MAX).float().mean().item())
    return row


def canonical_weight(w5, fp32, name: str) -> torch.Tensor:
    if name == "stem":
        weight, _ = w5.mxbase.fold_bn(fp32.stem, fp32.stem_norm)
    elif name == "enc":
        weight, _ = w5.mxbase.fold_bn(fp32.enc.gconv, fp32.enc.norm)
    elif name == "down":
        weight, _ = w5.mxbase.fold_bn(fp32.down, fp32.down_norm)
        weight = w5.mxbase.permute_down_weight(weight)
    elif name.startswith("body") and name.endswith("_gconv"):
        i = int(name[4:-6])
        weight, _ = w5.mxbase.fold_bn(fp32.body[i].gconv, fp32.body[i].gconv_norm)
    elif name.startswith("body") and name.endswith("_pw"):
        i = int(name[4:-3])
        weight, _ = w5.mxbase.fold_bn(fp32.body[i].pw, fp32.body[i].pw_norm)
    elif name == "reduce":
        weight, _ = w5.mxbase.fold_bn(fp32.reduce, fp32.reduce_norm)
    elif name == "dec":
        weight, _ = w5.mxbase.fold_bn(fp32.dec.gconv, fp32.dec.norm)
    elif name == "head":
        weight, _ = w5.mxbase.fold_bn(fp32.head, fp32.head_norm)
    elif name == "rgb":
        weight = fp32.rgb.weight.detach()
    else:
        raise KeyError(name)
    if weight.ndim == 4 and weight.shape[-2:] == (3, 3):
        return weight.permute(0, 2, 3, 1).reshape(weight.shape[0], 9, weight.shape[1] // 4, 4)
    return weight.reshape(weight.shape[0], weight.shape[1] // 4, 4)


def main() -> None:
    w5 = load_w5()
    _, fp32, payload = w5.mxbase.load_base().load_source_model(CHECKPOINT)
    artifact = torch.load(ARTIFACT, map_location="cpu", weights_only=False)
    metadata = artifact["metadata"]
    model = w5.W5NativeGroupMixNet(fp32, metadata["activation_base_exponents"]).cuda().eval()

    # Weight-only reconstruction error after BN folding.
    weight_rows = {}
    for raw_name, module in model.named_modules():
        if not isinstance(module, w5.W5Conv):
            continue
        if raw_name.startswith("body_gconv."):
            name = f"body{raw_name.split('.')[-1]}_gconv"
        elif raw_name.startswith("body_pw."):
            name = f"body{raw_name.split('.')[-1]}_pw"
        else:
            name = raw_name
        ref = canonical_weight(w5, fp32, name).cuda()
        recon = w5.reconstruct_blocks(module.qweight.reshape_as(ref), module.weight_delta, module.weight_base)
        row = metric(ref, recon)
        row["weight_base_exponent"] = module.weight_base
        row["q_saturation_fraction"] = float((module.qweight.abs() >= w5.QMAX).float().mean().item())
        row["q_zero_fraction"] = float((module.qweight == 0).float().mean().item())
        weight_rows[name] = row

    # Activation-only error on the same calibration set used by the quantizer.
    inputs = w5.mxbase.calibration_inputs(w5.mxbase.load_base(), VIDEO)
    names = ["input", "stem", "enc_gconv", "enc", "down"]
    for i in range(4):
        names += [f"body{i}_gconv", f"body{i}_pw", f"body{i}"]
    names += ["reduce", "dec_gconv", "dec", "head"]
    act_rows = {name: [] for name in names}
    with torch.inference_mode():
        for x in inputs[: min(16, len(inputs))]:
            trace = w5.trace_fp32(fp32, x)
            for name in names:
                act_rows[name].append(activation_row(w5, trace[name], metadata["activation_base_exponents"][name]))
    activation_rows = {
        name: {key: float(np.mean([row[key] for row in rows])) for key in rows[0]}
        for name, rows in act_rows.items()
    }

    # End-to-end error on the first 32 frames against the FP32 checkpoint.
    cap = cv2.VideoCapture(str(VIDEO))
    e2e_rows = []
    with torch.inference_mode():
        for _ in range(32):
            ok, frame = cap.read()
            if not ok:
                break
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
            ref = w5.trace_fp32(fp32, x)["rgb_logits"]
            ref = torch.sigmoid(ref)[..., : x.shape[-2], : x.shape[-1]]
            value = model(x).clamp(0.0, 1.0)
            e2e_rows.append(metric(ref, value))
    cap.release()

    result = {
        "format": metadata["format"],
        "checkpoint_step": payload["step"],
        "calibration_inputs": min(16, len(inputs)),
        "video_prefix_frames": len(e2e_rows),
        "weight_error": weight_rows,
        "activation_quantization_error": activation_rows,
        "end_to_end_vs_fp32": {key: float(np.mean([row[key] for row in e2e_rows])) for key in e2e_rows[0]},
    }
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
