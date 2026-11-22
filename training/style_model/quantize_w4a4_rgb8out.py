"""W4A4 NativeGroupMix PTQ with an INT8 final RGB-logit boundary."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import torch


HERE = Path(__file__).resolve().parent
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
BASE = HERE / "quantize_ptq.py"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
OUT_DIR = RUN / "ptq_w4a4_rgb8_step020000"
VIDEO = HERE.parents[3] / "ml/our_data/480p/our_data_480p_merged.mp4"
VIDEO_OUT = HERE.parents[3] / "ml/our_data/480p/native_groupmix_step020000_ptq_w4a4_rgb8out.mp4"


def load_base():
    spec = importlib.util.spec_from_file_location("native_groupmix_ptq_hybrid", BASE)
    if spec is None or spec.loader is None:
        raise ImportError(BASE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    q = load_base()
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required; refusing CPU quantization")
    torch.backends.cudnn.benchmark = True
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False

    _, fp32, payload = q.load_source_model(CHECKPOINT)
    inputs = q.load_calibration_inputs(VIDEO)
    scales, maxima = q.calibrate(fp32, inputs, 4)
    # Keep every internal activation W4A4.  Only the final RGB logits get an
    # A8 boundary, using a power-of-two scale for the LUT address path.
    scales["rgb_logits"] = q.pow2_scale(maxima["rgb_logits"], 127)
    model = q.QuantizedNativeGroupMixNet(fp32, scales, 4, rgb_output_bits=8).cuda().eval()
    if len([m for m in model.modules() if isinstance(m, q.QConv)]) != 15:
        raise AssertionError("Expected 15 quantized convolutions")

    metadata = q.collect_quant_metadata(model, 4, scales, maxima, CHECKPOINT)
    metadata.update({
        "format": "signed_w4a4_ptq_rgb_logits_a8",
        "activation_bits": 4,
        "rgb_head_weight_bits": 4,
        "rgb_head_output_bits": 8,
        "rgb_head_policy": "W4 weights; signed A8 RGB logits; sigmoid/LUT after A8 requant",
        "mx_block_scale": False,
        "ablation": "Only final RGB Conv output boundary changed from A4 to A8; all preceding domains remain W4A4",
    })
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    packed = {
        name: q.pack_int4(module.qweight)
        for name, module in model.named_modules() if isinstance(module, q.QConv)
    }
    artifact = OUT_DIR / "model_w4a4_rgb8out_ptq.pt"
    torch.save({
        "format": metadata["format"],
        "bits": 4,
        "rgb_output_bits": 8,
        "model_state": model.state_dict(),
        "packed_weights": packed,
        "metadata": metadata,
    }, artifact)
    (OUT_DIR / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {artifact}", flush=True)

    output_paths = {4: VIDEO_OUT}
    frames, (width, height, fps), metrics, previews = q.run_video(
        fp32, {4: model}, VIDEO, output_paths, preview_frame=400
    )
    if 4 in previews:
        q.save_preview(previews[4], OUT_DIR / "preview_frame_000400.jpg")
    result = {
        "input": str(VIDEO),
        "output": str(VIDEO_OUT),
        "source_size": [width, height],
        "output_size": [width, height],
        "fps": fps,
        "frames": frames,
        "fp32_comparison_first_32_frames": metrics[4],
        "artifact": str(artifact),
    }
    (OUT_DIR / "video_comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
