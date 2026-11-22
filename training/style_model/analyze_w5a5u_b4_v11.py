"""Endpoint error analysis for the W5A5-U/B4 v1.1 PTQ experiment."""
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
ARTIFACT = RUN / "ptq_w5a5u_b4_v11_step020000/model_w5a5u_b4_v11_ptq.pt"
VIDEO = HERE.parents[2] / "our_data/480p/our_data_480p_merged.mp4"
OUT = RUN / "ptq_w5a5u_b4_v11_numeric_analysis.json"


def load_module():
    sys.path.insert(0, str(HERE))
    path = HERE / "quantize_w5a5u_b4_v11.py"
    spec = importlib.util.spec_from_file_location("w5a5u_b4_v11", path)
    if spec is None or spec.loader is None:
        raise ImportError(path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def metric(ref, value):
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


def main():
    v11 = load_module()
    base = v11.load_base_script()
    _, fp32, payload = base.mxbase.load_base().load_source_model(CHECKPOINT)
    artifact = torch.load(ARTIFACT, map_location="cpu", weights_only=False)
    model = v11.NativeGroupMixNetV11(base, fp32, artifact["metadata"]["activation_base_exponents"]).cuda().eval()

    cap = cv2.VideoCapture(str(VIDEO))
    rows = []
    with torch.inference_mode():
        for _ in range(32):
            ok, frame = cap.read()
            if not ok:
                break
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            x = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0)
            ref = torch.sigmoid(base.trace_fp32(fp32, x)["rgb_logits"])[..., :x.shape[-2], :x.shape[-1]]
            value = model(x).clamp(0.0, 1.0)
            rows.append(metric(ref, value))
    cap.release()
    result = {
        "format": artifact["metadata"]["format"],
        "checkpoint_step": payload["step"],
        "video_prefix_frames": len(rows),
        "end_to_end_vs_fp32": {key: float(np.mean([row[key] for row in rows])) for key in rows[0]},
    }
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
