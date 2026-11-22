"""Numeric comparison of FP32, standard INT8 PTQ, and MX-INT4 B4 PTQ."""
from __future__ import annotations

import importlib.util
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image
from torch.nn import functional as F


HERE = Path(__file__).resolve().parent
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
CHECKPOINT = RUN / "checkpoints/step_020000.pt"
VIDEO = HERE.parents[2] / "our_data/480p/our_data_480p_merged.mp4"
MX_META = RUN / "ptq_mx_int4_b4_step020000/metadata.json"
INT8_META = RUN / "ptq_int8_step020000/metadata.json"
OUT = RUN / "ptq_mx_int4_b4_numeric_analysis.json"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_inputs(mx, count: int = 8):
    paths = mx.image_paths()
    values = []
    for index in np.linspace(0, len(paths) - 1, count, dtype=int):
        with Image.open(paths[int(index)]) as image:
            image = image.convert("RGB").resize((256, 256), Image.Resampling.BILINEAR)
            array = np.asarray(image, dtype=np.uint8)
        values.append(torch.from_numpy(array.copy()).permute(2, 0, 1).unsqueeze(0).cuda().float().div_(255.0))
    return values


def load_video_prefix(count: int = 32):
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


def dequant_layer(q, d, base):
    return qmx.mx_reconstruct(q, d, base)


def mx_trace(model, x):
    """Trace dequantized MX values after every stored activation boundary."""
    h, w = x.shape[-2:]
    padded, _ = model._pad_to_4(x)
    values = {}
    input_values = F.pixel_unshuffle(padded, 2)
    qx, dx = qmx.mx_quantize_real(input_values, model.act_base["input"])
    values["input"] = dequant_layer(qx, dx, model.act_base["input"])
    yq, yd = model.stem.forward_mx(qx, dx, model.act_base["input"], model.act_base["stem"], True)
    values["stem"] = dequant_layer(yq, yd, model.act_base["stem"])
    bq, bd = model.enc.forward_mx(yq, yd, model.act_base["stem"], model.act_base["enc_gconv"], True)
    values["enc_gconv"] = dequant_layer(bq, bd, model.act_base["enc_gconv"])
    yq, yd = model.residual(yq, yd, model.act_base["stem"], bq, bd, model.act_base["enc_gconv"], model.act_base["enc"])
    values["enc"] = dequant_layer(yq, yd, model.act_base["enc"])
    yq, yd = qmx.phase_major_unshuffle(yq, yd)
    yq, yd = model.down.forward_mx(yq, yd, model.act_base["enc"], model.act_base["down"], True)
    values["down"] = dequant_layer(yq, yd, model.act_base["down"])
    for i, (gconv, pw) in enumerate(zip(model.body_gconv, model.body_pw)):
        in_name = "down" if i == 0 else f"body{i - 1}"
        bq, bd = gconv.forward_mx(yq, yd, model.act_base[in_name], model.act_base[f"body{i}_gconv"], True)
        values[f"body{i}_gconv"] = dequant_layer(bq, bd, model.act_base[f"body{i}_gconv"])
        bq, bd = pw.forward_mx(bq, bd, model.act_base[f"body{i}_gconv"], model.act_base[f"body{i}_pw"], False)
        values[f"body{i}_pw"] = dequant_layer(bq, bd, model.act_base[f"body{i}_pw"])
        yq, yd = model.residual(yq, yd, model.act_base[in_name], bq, bd, model.act_base[f"body{i}_pw"], model.act_base[f"body{i}"])
        values[f"body{i}"] = dequant_layer(yq, yd, model.act_base[f"body{i}"])
    yq, yd = model.reduce.forward_mx(yq, yd, model.act_base["body3"], model.act_base["reduce"], True)
    values["reduce"] = dequant_layer(yq, yd, model.act_base["reduce"])
    yq, yd = qmx.nearest2_integer(yq), qmx.nearest2_integer(yd)
    bq, bd = model.dec.forward_mx(yq, yd, model.act_base["reduce"], model.act_base["dec_gconv"], True)
    values["dec_gconv"] = dequant_layer(bq, bd, model.act_base["dec_gconv"])
    yq, yd = model.residual(yq, yd, model.act_base["reduce"], bq, bd, model.act_base["dec_gconv"], model.act_base["dec"])
    values["dec"] = dequant_layer(yq, yd, model.act_base["dec"])
    yq, yd = model.head.forward_mx(yq, yd, model.act_base["dec"], model.act_base["head"], False)
    values["head"] = dequant_layer(yq, yd, model.act_base["head"])
    yq, yd = qmx.nearest2_integer(yq), qmx.nearest2_integer(yd)
    logits_acc, logits_exp = model.rgb.accumulate(yq, yd, model.act_base["head"])
    logits = logits_acc.float() * (2.0 ** logits_exp)
    values["rgb_logits"] = logits
    output = torch.sigmoid(logits)
    values["output"] = output[..., :h, :w]
    return values


def stat(x):
    x = x.detach().float()
    return {
        "mean": float(x.mean().item()),
        "std": float(x.std(unbiased=False).item()),
        "rms": float(x.square().mean().sqrt().item()),
        "abs_max": float(x.abs().max().item()),
        "zero_fraction": float((x == 0).float().mean().item()),
    }


def err(ref, value):
    d = (value.float() - ref.float()).abs()
    mse = float(d.square().mean().item())
    ref_rms = float(ref.float().square().mean().sqrt().item())
    return {
        "mae": float(d.mean().item()),
        "rmse": math.sqrt(mse),
        "relative_rmse": math.sqrt(mse) / max(ref_rms, 1e-12),
        "max_abs": float(d.max().item()),
    }


def mx_weight_real(module):
    q = module.qweight.float()
    d = module.weight_delta.long()
    if module.kind == "pw":
        scale = torch.pow(torch.tensor(2.0, device=q.device), (module.weight_base + d).float()).unsqueeze(-1)
        return (q * scale).reshape(module.out_channels, module.group_channels, 1, 1)
    scale = torch.pow(torch.tensor(2.0, device=q.device), (module.weight_base + d).float()).unsqueeze(-1)
    return (q * scale).permute(0, 2, 3, 1).reshape(module.out_channels, module.group_channels, 3, 3)


def folded_weights(fp32):
    out = {}
    out["stem"] = qmx.fold_bn(fp32.stem, fp32.stem_norm)[0]
    out["enc"] = qmx.fold_bn(fp32.enc.gconv, fp32.enc.norm)[0]
    down = qmx.fold_bn(fp32.down, fp32.down_norm)[0]
    out["down"] = qmx.permute_down_weight(down)
    for i, block in enumerate(fp32.body):
        out[f"body_gconv.{i}"] = qmx.fold_bn(block.gconv, block.gconv_norm)[0]
        out[f"body_pw.{i}"] = qmx.fold_bn(block.pw, block.pw_norm)[0]
    out["reduce"] = qmx.fold_bn(fp32.reduce, fp32.reduce_norm)[0]
    out["dec"] = qmx.fold_bn(fp32.dec.gconv, fp32.dec.norm)[0]
    out["head"] = qmx.fold_bn(fp32.head, fp32.head_norm)[0]
    out["rgb"] = fp32.rgb.weight.detach()
    return out


def main():
    global qmx
    qmx = load_module("mx_b4_analysis_quant", HERE / "quantize_mx_b4.py")
    ptq = load_module("standard_ptq_analysis_quant", HERE / "quantize_ptq.py")
    _, fp32, payload = qmx.load_base().load_source_model(CHECKPOINT)
    mx_meta = json.loads(MX_META.read_text(encoding="utf-8"))
    int8_meta = json.loads(INT8_META.read_text(encoding="utf-8"))
    mx_model = qmx.MXNativeGroupMixNet(fp32, mx_meta["activation_base_exponents"]).cuda().eval()
    int8_model = ptq.QuantizedNativeGroupMixNet(fp32, int8_meta["calibration_scales"], 8).cuda().eval()
    inputs = load_inputs(qmx, 8)
    names = ["input", "stem", "enc_gconv", "enc", "down"]
    for i in range(4):
        names += [f"body{i}_gconv", f"body{i}_pw", f"body{i}"]
    names += ["reduce", "dec_gconv", "dec", "head", "rgb_logits", "output"]
    sums = {n: {"mx": [], "int8": [], "local_mx": [], "local_int8": []} for n in names}
    block_stats = {n: [] for n in names if n in mx_meta["activation_base_exponents"]}
    final = {"mx": [], "int8": []}
    with torch.inference_mode():
        for x in inputs:
            ref = qmx.trace_fp32(fp32, x)
            mxv = mx_trace(mx_model, x)
            int8v = ptq.trace_fp32(fp32, x)
            # Standard INT8 output is captured separately; layer traces here
            # measure the common FP32-boundary local representation error.
            int8_out = int8_model(x).clamp(0.0, 1.0)
            for n in names:
                refn = torch.sigmoid(ref["rgb_logits"]) if n == "output" else ref[n]
                sums[n]["mx"].append(err(refn, mxv[n]))
                base = mx_meta["activation_base_exponents"].get(n)
                if base is not None:
                    q, d = qmx.mx_quantize_real(refn, base)
                    sums[n]["local_mx"].append(err(refn, qmx.mx_reconstruct(q, d, base)))
                    scale = torch.pow(torch.tensor(2.0, device=d.device), (base + d).float())
                    block_stats[n].append({
                        "d_mean": float(d.float().mean().item()),
                        "d7_fraction": float((d == 7).float().mean().item()),
                        "q_zero_fraction": float((q == 0).float().mean().item()),
                        "q_limit_fraction": float((q.abs() == 7).float().mean().item()),
                        "element_step_mean": float(scale.repeat_interleave(4, dim=1).mean().item()),
                        "element_step_median": float(scale.median().item()),
                    })
                if n in int8_meta["calibration_scales"]:
                    scale = float(int8_meta["calibration_scales"][n])
                    q = torch.round(refn / scale).clamp(-127, 127)
                    sums[n]["local_int8"].append(err(refn, q * scale))
            ref_output = torch.sigmoid(ref["rgb_logits"])
            sums["output"]["int8"].append(err(ref_output, int8_out))
            final["mx"].append(err(ref_output, mxv["output"]))
            final["int8"].append(err(ref_output, int8_out))

    report = {"checkpoint_step": payload["step"], "samples": len(inputs), "layers": {}}
    first_ref = qmx.trace_fp32(fp32, inputs[0])
    for n in names:
        row = {"fp32": stat(torch.sigmoid(first_ref["rgb_logits"]) if n == "output" else first_ref[n])}
        for key in ("mx", "int8", "local_mx", "local_int8"):
            vals = sums[n][key]
            if vals:
                row[key] = {k: float(np.mean([v[k] for v in vals])) for k in vals[0]}
        report["layers"][n] = row
    report["final_output"] = {k: {name: float(np.mean([v[name] for v in vals])) for name in vals[0]} for k, vals in final.items()}
    report["mx_activation_block_stats"] = {
        n: {key: float(np.mean([v[key] for v in vals])) for key in vals[0]}
        for n, vals in block_stats.items()
    }

    video_final = {"mx": [], "int8": []}
    with torch.inference_mode():
        for x in load_video_prefix(32):
            ref = qmx.trace_fp32(fp32, x)
            ref_output = torch.sigmoid(ref["rgb_logits"])[..., :x.shape[-2], :x.shape[-1]]
            video_final["mx"].append(err(ref_output, mx_trace(mx_model, x)["output"]))
            video_final["int8"].append(err(ref_output, int8_model(x).clamp(0.0, 1.0)))
    report["video_first_32_frames"] = {k: {name: float(np.mean([v[name] for v in vals])) for name in vals[0]} for k, vals in video_final.items()}

    fw = folded_weights(fp32)
    weight_rows = {}
    for name, module in mx_model.named_modules():
        if not isinstance(module, qmx.MXConv):
            continue
        source_name = name
        if name.startswith("body_gconv."):
            source_name = name
        source = fw[source_name]
        weight_rows[name] = err(source, mx_weight_real(module))
    report["mx_weight_error"] = weight_rows
    report["mx_weight_error_mean_relative_rmse"] = float(np.mean([v["relative_rmse"] for v in weight_rows.values()]))
    report["reference_int8_weight_relative_l2_mean_from_existing_report"] = 0.005937043927048986
    report["reference_standard_w4a4_weight_relative_l2_mean_from_existing_report"] = 0.16137738717724395
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report["final_output"], ensure_ascii=False, indent=2))
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
