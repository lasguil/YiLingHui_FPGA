"""Trace FP32 and quantized activation values layer by layer."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import numpy as np
import torch


HERE = Path(__file__).resolve().parent
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
BASE = HERE / "quantize_ptq.py"
VIDEO = HERE.parents[3] / "ml/our_data/480p/our_data_480p_merged.mp4"


def load_base():
    spec = importlib.util.spec_from_file_location("native_groupmix_activation_analysis", BASE)
    if spec is None or spec.loader is None:
        raise ImportError(BASE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def quant_trace(q, model, x):
    """Return dequantized values and integer codes at every quantized boundary."""
    s = model.scales
    trace = {}
    codes = {}

    def put(name, qvalue, scale):
        codes[name] = qvalue
        trace[name] = qvalue * scale

    input_scale = s["input"]
    xq = q.quantize_code(x, input_scale, model.bits)
    put("input", xq, input_scale)
    h, w = x.shape[-2:]
    ph, pw = (-h) % 4, (-w) % 4
    if ph or pw:
        xq = torch.nn.functional.pad(xq, (0, pw, 0, ph), mode="reflect")

    y = torch.nn.functional.pixel_unshuffle(xq, 2)
    y = model.stem(y, input_scale, s["stem"])
    y = model.relu6(y, s["stem"], s["stem"])
    put("stem", y, s["stem"])
    branch = model.enc(y, s["stem"], s["enc_gconv"])
    branch = model.relu6(branch, s["enc_gconv"], s["enc_gconv"])
    put("enc_gconv", branch, s["enc_gconv"])
    y = model.residual(y, s["stem"], branch, s["enc_gconv"], s["enc"])
    put("enc", y, s["enc"])

    y = torch.nn.functional.pixel_unshuffle(y * s["enc"], 2)
    y = q.quantize_code(y, s["enc"], model.bits)
    y = model.down(y, s["enc"], s["down"])
    y = model.relu6(y, s["down"], s["down"])
    put("down", y, s["down"])

    for index, (gconv, pw) in enumerate(zip(model.body_gconv, model.body_pw)):
        input_name = "down" if index == 0 else f"body{index - 1}"
        input_scale = s[input_name]
        branch = gconv(y, input_scale, s[f"body{index}_gconv"])
        branch = model.relu6(branch, s[f"body{index}_gconv"], s[f"body{index}_gconv"])
        put(f"body{index}_gconv", branch, s[f"body{index}_gconv"])
        branch = pw(branch, s[f"body{index}_gconv"], s[f"body{index}_pw"])
        put(f"body{index}_pw", branch, s[f"body{index}_pw"])
        y = model.residual(y, input_scale, branch, s[f"body{index}_pw"], s[f"body{index}"])
        put(f"body{index}", y, s[f"body{index}"])

    y = model.reduce(y, s["body3"], s["reduce"])
    y = model.relu6(y, s["reduce"], s["reduce"])
    put("reduce", y, s["reduce"])
    y = torch.nn.functional.interpolate(y * s["reduce"], scale_factor=2, mode="nearest")
    y = q.quantize_code(y, s["reduce"], model.bits)
    branch = model.dec(y, s["reduce"], s["dec_gconv"])
    branch = model.relu6(branch, s["dec_gconv"], s["dec_gconv"])
    put("dec_gconv", branch, s["dec_gconv"])
    y = model.residual(y, s["reduce"], branch, s["dec_gconv"], s["dec"])
    put("dec", y, s["dec"])
    y = model.head(y, s["dec"], s["head"])
    put("head", y, s["head"])
    y = torch.nn.functional.interpolate(y * s["head"], scale_factor=2, mode="nearest")
    y = q.quantize_code(y, s["head"], model.bits)
    y = model.rgb(y, s["head"], s["rgb_logits"])
    put("rgb_logits", y, s["rgb_logits"])
    output = torch.sigmoid(trace["rgb_logits"])
    if ph or pw:
        output = output[..., :h, :w]
    trace["output"] = output
    return trace, codes


def update_stat(bucket, fp, actual, code, scale, qmax, bits):
    fp = fp.detach().float()
    actual = actual.detach().float()
    code = code.detach()
    local = (q.quantize_code(fp, scale, bits) * scale).detach()
    diff_actual = actual - fp
    diff_local = local - fp
    n = fp.numel()
    bucket["n"] += n
    bucket["fp_sum"] += float(fp.sum().item())
    bucket["fp_sq_sum"] += float(fp.square().sum().item())
    bucket["actual_abs_sum"] += float(diff_actual.abs().sum().item())
    bucket["actual_sq_sum"] += float(diff_actual.square().sum().item())
    bucket["local_abs_sum"] += float(diff_local.abs().sum().item())
    bucket["local_sq_sum"] += float(diff_local.square().sum().item())
    bucket["fp_abs_max"] = max(bucket["fp_abs_max"], float(fp.abs().max().item()))
    bucket["actual_abs_max"] = max(bucket["actual_abs_max"], float(diff_actual.abs().max().item()))
    bucket["actual_q_abs_max"] = max(bucket["actual_q_abs_max"], float(code.abs().max().item()))
    bucket["zero_count"] += int((code == 0).sum().item())
    bucket["limit_count"] += int((code.abs() == qmax).sum().item())
    bucket["codes"].update(int(v) for v in torch.unique(code).cpu().tolist())


def finish_stat(bucket, scale, qmax):
    n = bucket.pop("n")
    fp_mean = bucket.pop("fp_sum") / n
    fp_second = bucket.pop("fp_sq_sum") / n
    fp_std = max(fp_second - fp_mean * fp_mean, 0.0) ** 0.5
    actual_mae = bucket.pop("actual_abs_sum") / n
    actual_rmse = (bucket.pop("actual_sq_sum") / n) ** 0.5
    local_mae = bucket.pop("local_abs_sum") / n
    local_rmse = (bucket.pop("local_sq_sum") / n) ** 0.5
    zero = bucket.pop("zero_count") / n
    limit = bucket.pop("limit_count") / n
    codes = sorted(bucket.pop("codes"))
    return {
        "fp32_mean": fp_mean,
        "fp32_std": fp_std,
        "fp32_abs_max": bucket.pop("fp_abs_max"),
        "actual_dequant_mae": actual_mae,
        "actual_dequant_rmse": actual_rmse,
        "actual_relative_rmse": actual_rmse / max(fp_std, 1e-12),
        "local_representation_mae": local_mae,
        "local_representation_rmse": local_rmse,
        "local_relative_rmse": local_rmse / max(fp_std, 1e-12),
        "actual_q_abs_max": bucket.pop("actual_q_abs_max"),
        "zero_fraction": zero,
        "limit_fraction": limit,
        "unique_codes": len(codes),
        "codes": codes,
        "scale": scale,
        "representable_abs_max": qmax * scale,
    }


def empty_stat():
    return {"n": 0, "fp_sum": 0.0, "fp_sq_sum": 0.0,
            "actual_abs_sum": 0.0, "actual_sq_sum": 0.0,
            "local_abs_sum": 0.0, "local_sq_sum": 0.0,
            "fp_abs_max": 0.0, "actual_abs_max": 0.0,
            "actual_q_abs_max": 0.0, "zero_count": 0,
            "limit_count": 0, "codes": set()}


def main():
    global q
    q = load_base()
    checkpoint = RUN / "checkpoints/step_020000.pt"
    _, fp32, payload = q.load_source_model(checkpoint)
    all_inputs = q.load_calibration_inputs(VIDEO)
    indices = np.linspace(0, len(all_inputs) - 1, min(32, len(all_inputs)), dtype=int)
    inputs = [all_inputs[int(i)] for i in indices]

    report = {"checkpoint_step": payload["step"], "sample_count": len(inputs), "variants": {}}
    for key, dirname, rgb_bits in (
        ("w4a4", "ptq_w4a4_step020000", 4),
        ("w4a4_rgb8out", "ptq_w4a4_rgb8_step020000", 8),
        ("int8", "ptq_int8_step020000", 8),
    ):
        metadata = json.loads((RUN / dirname / "metadata.json").read_text(encoding="utf-8"))
        model = q.QuantizedNativeGroupMixNet(
            fp32, metadata["calibration_scales"], 4 if key != "int8" else 8,
            rgb_output_bits=rgb_bits if key != "int8" else None,
        ).cuda().eval()
        artifact_name = "model_w4a4_ptq.pt" if key == "w4a4" else (
            "model_w4a4_rgb8out_ptq.pt" if key == "w4a4_rgb8out" else "model_int8_ptq.pt"
        )
        artifact = torch.load(RUN / dirname / artifact_name, map_location="cpu", weights_only=False)
        model.load_state_dict(artifact["model_state"], strict=True)
        model_bits = model.bits
        qmax = 127 if model_bits == 8 else 7
        stats = {}
        with torch.inference_mode():
            for index, x in enumerate(inputs, 1):
                fp_trace = q.trace_fp32(fp32, x)
                actual_trace, code_trace = quant_trace(q, model, x)
                for name, fp_value in fp_trace.items():
                    if name == "output":
                        continue
                    stats.setdefault(name, empty_stat())
                    activation_bits = rgb_bits if name == "rgb_logits" and key == "w4a4_rgb8out" else model_bits
                    scale = metadata["calibration_scales"][name]
                    update_stat(stats[name], fp_value, actual_trace[name], code_trace[name], scale,
                                127 if activation_bits == 8 else 7, activation_bits)
                if index % 8 == 0 or index == len(inputs):
                    print(f"{key}: traced {index}/{len(inputs)}", flush=True)
        report["variants"][key] = {
            "format": metadata["format"],
            "layers": {
                name: finish_stat(value, metadata["calibration_scales"][name],
                                  127 if (name == "rgb_logits" and key == "w4a4_rgb8out") or key == "int8" else 7)
                for name, value in stats.items()
            },
        }

    output = RUN / "ptq_activation_analysis.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Saved {output}")


if __name__ == "__main__":
    main()
