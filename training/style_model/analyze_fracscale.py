"""Compare fractional-scale and exact-float B4 outputs on the same video prefix."""
from __future__ import annotations

import json
import math
from pathlib import Path

import cv2
import importlib.util
import numpy as np
import torch


HERE = Path(__file__).resolve().parent
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = HERE.parents[2] / "our_data/480p/our_data_480p_merged.mp4"
FRAC_META = RUN / "ptq_mx_int4_b4_fracscale_step020000/metadata.json"
OUT = RUN / "ptq_mx_int4_b4_fracscale_numeric_analysis.json"


def load_file(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def metric(ref, value):
    diff = value.float() - ref.float()
    mse = float(diff.square().mean().item())
    return {
        "mae": float(diff.abs().mean().item()),
        "rmse": math.sqrt(mse),
        "psnr_db": 10.0 * math.log10(1.0 / max(mse, 1e-12)),
        "max_abs": float(diff.abs().max().item()),
    }


def main():
    frac = load_file("fracscale_model", HERE / "quantize_mx_b4_fracscale.py")
    exact = load_file("exactscale_model", HERE / "quantize_mx_b4_exactscale.py")
    _, fp32, payload = frac.mxbase.load_base().load_source_model(CHECKPOINT)
    meta = json.loads(FRAC_META.read_text(encoding="utf-8"))
    frac_model = frac.FracNativeGroupMixNet(fp32, meta["activation_base_exponents"]).cuda().eval()
    exact_model = exact.ExactScaleNativeGroupMixNet(fp32).cuda().eval()
    cap = cv2.VideoCapture(str(VIDEO))
    rows = {"fractional_vs_fp32": [], "exact_vs_fp32": [], "fractional_vs_exact": []}
    with torch.inference_mode():
        for _ in range(32):
            ok, frame = cap.read()
            if not ok:
                break
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
            ref = frac.mxbase.trace_fp32(fp32, x)
            ref = torch.sigmoid(ref["rgb_logits"])[..., :x.shape[-2], :x.shape[-1]]
            frac_out = frac_model(x).clamp(0.0, 1.0)
            exact_out = exact_model(x).clamp(0.0, 1.0)
            rows["fractional_vs_fp32"].append(metric(ref, frac_out))
            rows["exact_vs_fp32"].append(metric(ref, exact_out))
            rows["fractional_vs_exact"].append(metric(exact_out, frac_out))
    cap.release()
    result = {"checkpoint_step": payload["step"], "frames": len(rows["fractional_vs_fp32"])}
    result.update({name: {key: float(np.mean([row[key] for row in values])) for key in values[0]} for name, values in rows.items()})
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
