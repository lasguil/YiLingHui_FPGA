"""CUDA implementation of the FPGA integer inference contract.

This runs the packed FPGA arithmetic on the local CUDA GPU so the camera UI is
responsive. It is a software emulator of the integer datapath, not execution on
the Ti60 board. Conv MAC sums use FP32 CUDA kernels with reduced precision
disabled; the integer sums stay exactly representable for this model's range.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
import onnx
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from int8_reference import Packed  # noqa: E402

MODEL = ROOT.parents[3] / "software/gesture/models/reference/hand_landmark_lite_int8.onnx"


def _round_shift(value: torch.Tensor, shift: int) -> torch.Tensor:
    """Signed round-to-nearest-even after an arithmetic right shift."""
    quotient = torch.bitwise_right_shift(value, shift)
    remainder = value - torch.bitwise_left_shift(quotient, shift)
    half = 1 << (shift - 1)
    up = (remainder > half) | ((remainder == half) & ((quotient & 1) != 0))
    return quotient + up.to(torch.int64)


class FpgaIntegerCuda:
    """Run packed NPU arithmetic on CUDA and return dequantized ONNX outputs."""

    def __init__(self, device: str = "cuda:0", build: Path | None = None):
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA is required for the FPGA integer demo; CPU fallback is disabled")
        self.device = torch.device(device)
        if self.device.type != "cuda" or self.device.index is None:
            raise ValueError("select an explicit CUDA device, for example cuda:0")
        if self.device.index >= torch.cuda.device_count():
            raise ValueError(f"CUDA device {self.device} is unavailable")

        torch.backends.cudnn.allow_tf32 = False
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.benchmark = True
        self.packed = Packed(build=build) if build else Packed()
        self.layers = self.packed.layers
        self.weights = {}
        self.params = {}
        for x in self.layers:
            if x["op"] not in ("PW", "DW", "CONV"):
                continue
            self.weights[x["index"]] = torch.as_tensor(
                self.packed.weights_of(x).astype(np.float32), device=self.device)
            p = self.packed.param[x["index"]]
            self.params[x["index"]] = {
                key: torch.as_tensor(p[key], dtype=torch.int64, device=self.device)
                for key in ("m18", "post", "zp", "bfix")
            }

        model = onnx.load(str(MODEL), load_external_data=False)
        init = {item.name: onnx.numpy_helper.to_array(item)
                for item in model.graph.initializer}
        self.output_q = {
            name: (float(init[f"{name}_scale"].reshape(-1)[0]),
                   int(init[f"{name}_zero_point"].reshape(-1)[0]))
            for name in ("Identity", "Identity_1", "Identity_2", "Identity_3")
        }
        self.output_layers = {name: self.layers[index]
                              for index, name in ((59, "Identity_1"),
                                                  (60, "Identity_2"),
                                                  (61, "Identity"),
                                                  (62, "Identity_3"))}
        self.gpu_name = torch.cuda.get_device_name(self.device)
        # cuDNN may spend seconds selecting kernels on its first invocation.
        # Do that before the camera display loop starts so displayed latency is
        # representative of steady state.
        self._run_codes(np.zeros((224, 224, 3), dtype=np.float32))
        torch.cuda.synchronize(self.device)

    def _conv(self, src: torch.Tensor, x: dict) -> torch.Tensor:
        acc = src.to(torch.float32) - 128.0
        pad_t, pad_l, pad_b, pad_r = x["pads"]
        if pad_t or pad_l or pad_b or pad_r:
            acc = F.pad(acc, (pad_l, pad_r, pad_t, pad_b),
                        value=float(x["zp_in"] - 128))
        # Integer-valued operands and partial sums remain exactly representable
        # in FP32 here (the model's maximum MAC sum is below 2^20).
        acc = F.conv2d(acc, self.weights[x["index"]], bias=None,
                       stride=tuple(x["stride"]), padding=0,
                       groups=int(x["group"]))
        acc = acc.to(torch.int64)
        p = self.params[x["index"]]
        prod = acc * p["m18"].view(1, -1, 1, 1)
        post = p["post"]
        # The exported descriptor keeps post_shift in [14, 51].
        shifted = torch.bitwise_right_shift(prod, (post - 10).view(1, -1, 1, 1))
        total = shifted + p["bfix"].view(1, -1, 1, 1)
        q = _round_shift(total, 10) + p["zp"].view(1, -1, 1, 1)
        return q.clamp_(0, 255).to(torch.uint8)

    @staticmethod
    def _requant_add(value: torch.Tensor, scale: float, zp: int,
                     output_scale: float) -> torch.Tensor:
        ratio = scale / output_scale
        exponent = math.floor(math.log2(ratio)) if ratio > 0 else 0
        post = 16 - exponent
        m18 = max(min(round(ratio * (1 << post)), (1 << 17) - 1), 1 << 16)
        bfix = round((128 - zp) * ratio * (1 << 10))
        return torch.bitwise_right_shift((value.to(torch.int64) - 128) * m18,
                                         post - 10) + bfix

    def _run_codes(self, image_rgb: np.ndarray) -> dict[str, torch.Tensor]:
        image = np.asarray(image_rgb, dtype=np.float32)
        if image.ndim != 3 or image.shape != (224, 224, 3):
            raise ValueError(f"expected RGB image (224,224,3); got {image.shape}")
        tensor = torch.as_tensor(image.transpose(2, 0, 1)[None],
                                 dtype=torch.float32, device=self.device)
        first = self.layers[0]
        s_in, zp_in = float(first["s_in"]), int(first["zp_in"])
        input_code = torch.round(tensor / s_in + zp_in).clamp(0, 255).to(torch.uint8)
        codes: dict[str, torch.Tensor] = {first["in_code"]: input_code}

        for x in self.layers:
            op = x["op"]
            if op in ("PW", "DW", "CONV"):
                out = self._conv(codes[x["in_code"]], x)
            elif op == "MAXPOOL":
                src = codes[x["in_code"]].to(torch.float32)
                out = F.max_pool2d(src, kernel_size=x["kernel"],
                                   stride=x["stride"]).to(torch.uint8)
            elif op == "ADD":
                a = codes[x["src_a"]][0].to(torch.int64)
                b = codes[x["src_b"]][0].to(torch.int64)
                fixed = self._requant_add(a, x["s_a"], x["zp_a"], x["s_out"])
                fixed += self._requant_add(b, x["s_b"], x["zp_b"], x["s_out"])
                out = (_round_shift(fixed, 10) + x["zp_out"]).clamp(0, 255)
                out = out.to(torch.uint8)[None]
            elif op == "GAP":
                n = int(x["count"])
                ratio = x["s_in"] / (n * x["s_out"])
                exponent = math.floor(math.log2(ratio)) if ratio > 0 else 0
                post = 16 - exponent
                m18 = max(min(round(ratio * (1 << post)), (1 << 17) - 1), 1 << 16)
                bfix = round(n * (128 - x["zp_in"]) * ratio * (1 << 10))
                acc = (codes[x["in_code"]].to(torch.int64) - 128).sum((2, 3))
                total = torch.bitwise_right_shift(acc * m18, post - 10) + bfix
                out = (_round_shift(total, 10) + x["zp_out"]).clamp(0, 255)
                out = out.to(torch.uint8).reshape(1, x["cin"], 1, 1)
            else:
                raise RuntimeError(f"unhandled FPGA layer {x['index']}: {op}")
            codes[x["out_code"]] = out
        return codes

    def infer(self, image_rgb: np.ndarray) -> dict[str, np.ndarray]:
        codes = self._run_codes(image_rgb)
        result = {}
        for name in ("Identity", "Identity_3"):
            layer = self.output_layers[name]
            scale, zp = self.output_q[name]
            q = codes[layer["out_code"]].to(torch.float32)
            result[name] = ((q - zp) * scale).reshape(-1).cpu().numpy()

        for name in ("Identity_1", "Identity_2"):
            layer = self.output_layers[name]
            logits = codes[layer["out_code"]].to(torch.float32)
            logits = (logits - layer["zp_out"]) * layer["s_out"]
            score = torch.sigmoid(logits)
            scale, zp = self.output_q[name]
            q = torch.round(score / scale + zp).clamp(0, 255)
            result[name] = ((q - zp) * scale).reshape(-1).cpu().numpy()
        return result
