"""Numerical layerwise analysis for the NativeGroupMixNet PTQ artifacts."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import torch


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
RUN = HERE.parents[1] / "runs/native_groupmix_main256_20260910_20k"
QUANTIZER = HERE / "quantize_ptq.py"


def load_quantizer():
    spec = importlib.util.spec_from_file_location("native_groupmix_ptq_analysis", QUANTIZER)
    if spec is None or spec.loader is None:
        raise ImportError(QUANTIZER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rel_l2(a: torch.Tensor, b: torch.Tensor) -> float:
    return float((a - b).norm().item() / max(a.norm().item(), 1e-12))


def layer_map(fp32):
    rows = [
        ("stem", fp32.stem, fp32.stem_norm),
        ("enc", fp32.enc.gconv, fp32.enc.norm),
        ("down", fp32.down, fp32.down_norm),
    ]
    for i, block in enumerate(fp32.body):
        rows.extend([
            (f"body_gconv.{i}", block.gconv, block.gconv_norm),
            (f"body_pw.{i}", block.pw, block.pw_norm),
        ])
    rows.extend([
        ("reduce", fp32.reduce, fp32.reduce_norm),
        ("dec", fp32.dec.gconv, fp32.dec.norm),
        ("head", fp32.head, fp32.head_norm),
        ("rgb", fp32.rgb, None),
    ])
    return rows


def qmodule_map(qmodel):
    rows = [("stem", qmodel.stem), ("enc", qmodel.enc), ("down", qmodel.down)]
    for i, (g, p) in enumerate(zip(qmodel.body_gconv, qmodel.body_pw)):
        rows.extend([(f"body_gconv.{i}", g), (f"body_pw.{i}", p)])
    rows.extend([("reduce", qmodel.reduce), ("dec", qmodel.dec), ("head", qmodel.head), ("rgb", qmodel.rgb)])
    return rows


def main():
    q = load_quantizer()
    checkpoint = RUN / "checkpoints/step_020000.pt"
    _, fp32, payload = q.load_source_model(checkpoint)
    report = {
        "checkpoint_step": payload["step"],
        "generator": payload["config"]["generator"],
        "parameter_count": sum(p.numel() for p in fp32.parameters()),
        "variants": {},
    }

    for bits, dirname in ((8, "ptq_int8_step020000"), (4, "ptq_w4a4_step020000")):
        metadata = json.loads((RUN / dirname / "metadata.json").read_text(encoding="utf-8"))
        qmodel = q.QuantizedNativeGroupMixNet(fp32, metadata["calibration_scales"], bits).cuda().eval()
        artifact = torch.load(RUN / dirname / ("model_int8_ptq.pt" if bits == 8 else "model_w4a4_ptq.pt"), map_location="cpu", weights_only=False)
        qmodel.load_state_dict(artifact["model_state"], strict=True)
        qmax = 127 if bits == 8 else 7
        rows = []
        qmap = dict(qmodule_map(qmodel))
        for name, conv, bn in layer_map(fp32):
            weight, bias = q.fold_bn(conv, bn) if bn is not None else (conv.weight.detach(), conv.bias.detach())
            qm = qmap[name]
            recon = qm.qweight.float().cuda() * qm.weight_scale.reshape(-1, *([1] * (weight.ndim - 1)))
            target = weight.cuda()
            qw = qm.qweight
            max_abs = float(target.abs().max().item())
            row = {
                "layer": name,
                "shape": list(weight.shape),
                "weight_max_abs": max_abs,
                "weight_scale_min": float(qm.weight_scale.min().item()),
                "weight_scale_max": float(qm.weight_scale.max().item()),
                "weight_mae": float((target - recon).abs().mean().item()),
                "weight_rmse": float((target - recon).square().mean().sqrt().item()),
                "weight_relative_l2": rel_l2(target, recon),
                "q_zero_fraction": float((qw == 0).float().mean().item()),
                "q_limit_fraction": float((qw.abs() == qmax).float().mean().item()),
                "q_unique_count": int(torch.unique(qw).numel()),
                "q_min": int(qw.min().item()),
                "q_max": int(qw.max().item()),
            }
            input_name = {
                "stem": "input", "enc": "stem", "down": "enc", "reduce": "body3",
                "dec": "reduce", "head": "dec", "rgb": "head",
            }.get(name)
            if name.startswith("body_gconv."):
                i = int(name.rsplit(".", 1)[1])
                input_name = "down" if i == 0 else f"body{i - 1}"
            elif name.startswith("body_pw."):
                i = int(name.rsplit(".", 1)[1])
                input_name = f"body{i}_gconv"
            in_scale = metadata["calibration_scales"][input_name]
            bias_q = torch.round(bias.cuda() / (in_scale * qm.weight_scale.cuda()))
            bias_recon = bias_q * in_scale * qm.weight_scale.cuda()
            row.update({
                "bias_max_abs": float(bias.abs().max().item()),
                "bias_mae": float((bias.cuda() - bias_recon).abs().mean().item()),
                "bias_relative_l2": rel_l2(bias.cuda(), bias_recon),
            })
            rows.append(row)

        act_rows = []
        for name, scale in metadata["calibration_scales"].items():
            if name == "input":
                continue
            amax = metadata["calibration_amax"].get(name, 0.0)
            act_rows.append({
                "layer": name,
                "amax": amax,
                "scale": scale,
                "step_as_percent_of_amax": 100.0 * scale / max(amax, 1e-12),
                "representable_abs_max": qmax * scale,
                "headroom_or_clip_ratio": (qmax * scale) / max(amax, 1e-12),
            })
        report["variants"][str(bits)] = {
            "format": metadata["format"],
            "weight_rows": rows,
            "activation_rows": act_rows,
            "weight_mae_mean": sum(r["weight_mae"] for r in rows) / len(rows),
            "weight_relative_l2_mean": sum(r["weight_relative_l2"] for r in rows) / len(rows),
            "zero_fraction_mean": sum(r["q_zero_fraction"] for r in rows) / len(rows),
            "limit_fraction_mean": sum(r["q_limit_fraction"] for r in rows) / len(rows),
        }

    output = RUN / "ptq_numeric_analysis.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Saved {output}")


if __name__ == "__main__":
    main()
