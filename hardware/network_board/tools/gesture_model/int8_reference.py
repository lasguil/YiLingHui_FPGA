"""Bit-exact integer reference for the extracted hand-landmark graph.

This is the golden model the RTL is checked against.  It implements exactly the
arithmetic the hardware performs:

    acc        = sum_i (a_code[i] ^ 0x80) * w[c][i] + bias_total[c]
    y_code     = clamp8( rne( acc * M[c] ) + zp_out )

where `a_code ^ 0x80` reinterprets the uint8 activation code as signed and the
zero-point shift is already folded into `bias_total` by extract_model.py.

Run from this directory: python int8_reference.py [image.npy|random]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"


def rne_shift(value: np.ndarray, shift: np.ndarray) -> np.ndarray:
    """Round-to-nearest-even right shift; `shift` broadcasts against `value`."""
    value = np.asarray(value, dtype=np.int64)
    shift = np.broadcast_to(np.asarray(shift, dtype=np.int64), value.shape)
    quotient = np.where(shift > 0, value >> np.maximum(shift, 1), value)
    remainder = value - (quotient << np.where(shift > 0, shift, 0))
    half = np.int64(1) << np.maximum(shift - 1, 0)
    round_up = (remainder > half) | ((remainder == half) & ((quotient & 1) == 1))
    return quotient + (round_up & (shift > 0)).astype(np.int64)


def requant(acc: np.ndarray, m18: np.ndarray, post: np.ndarray,
            bfix: np.ndarray) -> np.ndarray:
    """Hardware-exact requant, in units of 2^-10 output codes.

        y = rne( ((acc * m18) >> (post - 10)) + B_fixed , 10 )

    The bias rides along in the same shifted domain as the product, so the
    accumulator only ever holds the (much smaller) MAC sum.  `>>` is an
    arithmetic (floor) shift, matching the RTL barrel shifter.
    """
    acc = acc.astype(np.int64)
    prod = acc * m18.reshape(-1, 1, 1).astype(np.int64)
    shifted = prod >> (post.reshape(-1, 1, 1).astype(np.int64) - 10)
    total = shifted + bfix.reshape(-1, 1, 1)
    return rne_shift(total, np.full(total.shape, 10, np.int64))


class Packed:
    """Access to the packed weight/bias/param blobs produced by extract_model."""

    def __init__(self, build: Path = BUILD):
        self.layers = json.loads((build / "layers.json").read_text())
        self.weights = np.frombuffer((build / "weights.bin").read_bytes(), np.int8)
        self.bias = np.frombuffer((build / "bias.bin").read_bytes(), "<i4")
        self.bfix = np.frombuffer((build / "bfix.bin").read_bytes(), "<i4")
        raw = np.frombuffer((build / "param.bin").read_bytes(), np.uint8)

        self.param = {}
        for x in self.layers:
            if x["op"] not in ("PW", "DW", "CONV"):
                continue
            co = x["cout"]
            off = x["param_off"]
            block = raw[off:off + 7 * co]
            # layout written by extract_model.emit_param: per channel
            # [pre_shift:u16][m18:u24][post_shift:u8], then co bytes of zero point
            rec = block[0:6 * co].reshape(co, 6).astype(np.int64)
            pre = rec[:, 0] | (rec[:, 1] << 8)
            m18 = rec[:, 2] | (rec[:, 3] << 8) | (rec[:, 4] << 16)
            post = rec[:, 5]
            zp = block[6 * co:7 * co].astype(np.int64)
            boff = x["bfix_off"] // 4
            self.param[x["index"]] = dict(pre=pre, m18=m18, post=post, zp=zp,
                                          bfix=self.bfix[boff:boff + co].astype(np.int64))

    def weights_of(self, x) -> np.ndarray:
        off = x["weight_off"]
        kh, kw = x["kernel"]
        cin_g = x["cin"] // x["group"]
        n = x["cout"] * cin_g * kh * kw
        return self.weights[off:off + n].reshape(x["cout"], cin_g, kh, kw)

    def bias_of(self, x) -> np.ndarray:
        off = x["bias_off"] // 4          # offsets in layers.json are byte offsets
        return self.bias[off:off + x["cout"]].astype(np.int64)


def sigmoid_uint8(code: np.ndarray, s: float, zp: int) -> np.ndarray:
    value = (code.astype(np.float64) - zp) * s
    return np.clip(value, -1e30, 1e30)


def run_reference(packed: Packed, image_f32: np.ndarray, verbose=True):
    """Execute the extracted graph. image_f32 is HWC float32 in [0, 1]."""
    layers = packed.layers

    # input quantization (opset-13 QDQ on the transposed tensor)
    input_q = next(x for x in layers if x["index"] == 0)
    s_in, zp_in = input_q["s_in"], input_q["zp_in"]
    # NHWC -> NCHW
    img_chw = np.transpose(image_f32, (2, 0, 1))[None, ...]
    codes = {}

    def quantize(name, value):
        return value

    # quantized input tensor
    img_code = np.clip(np.rint(img_chw / s_in) + zp_in, 0, 255).astype(np.uint8)
    codes["__input__"] = img_code
    input_code_name = layers[0]["in_code"]
    codes[input_code_name] = img_code

    stats = []

    for x in layers:
        op = x["op"]
        if op in ("PW", "DW", "CONV"):
            src = codes[x["in_code"]]
            w = packed.weights_of(x)
            b = packed.bias_of(x)
            p = packed.param[x["index"]]
            co = x["cout"]
            kh, kw = x["kernel"]
            sh, sw = x["stride"]
            pt, pl, pb, pr = x["pads"]
            hi, wi = x["in_hw"]
            ho, wo = x["out_hw"]

            signed = (src.astype(np.int16) ^ 0x80).astype(np.int8).astype(np.int64)
            # Zero padding carries this layer's input zero point, so in the
            # signed domain (code ^ 0x80) it is zp_in - 128.  bias_total was
            # folded with exactly this convention: the correction term
            # (128 - zp_in) * sum(w) cancels the padding contribution.
            pad_signed = int(x["zp_in"]) - 128
            padded = np.pad(signed[0], ((0, 0), (pt, pb), (pl, pr)),
                            constant_values=pad_signed)

            acc = np.zeros((co, ho, wo), np.int64)
            w4 = w.astype(np.int64)
            for ky in range(kh):
                for kx in range(kw):
                    win = padded[:, ky:ky + ho * sh:sh, kx:kx + wo * sw:sw]
                    if x["group"] > 1:            # depthwise: one tap drives one channel
                        acc += win[:co].astype(np.int64) * w4[:, 0, ky, kx, None, None]
                    else:                          # full reduction over cin
                        acc += np.einsum("chw,oc->ohw", win.astype(np.int64), w4[:, :, ky, kx])
            mac_peak = int(np.abs(acc).max())      # bias-free: what the multiplier sees
            stats.append((x["index"], x["name"],
                          int(np.abs(acc + b[:, None, None]).max()), mac_peak))
            y = requant(acc, p["m18"], p["post"], p["bfix"]) + p["zp"][:, None, None]
            y = np.clip(y, 0, 255).astype(np.uint8)
            codes[x["out_code"]] = y[None, ...]
            continue

        if op == "MAXPOOL":
            src = codes[x["in_code"]]
            k, s = x["kernel"][0], x["stride"][0]
            c, hi, wi = src.shape[1:]
            ho = (hi - k) // s + 1
            wo = (wi - k) // s + 1
            out = np.full((1, c, ho, wo), 0, np.uint8)
            for dy in range(k):
                for dx in range(k):
                    out = np.maximum(out, src[:, :, dy:dy + ho * s:s, dx:dx + wo * s:s])
            codes[x["out_code"]] = out
            continue

        if op == "ADD":
            a = codes[x["src_a"]].astype(np.int64)[0]
            b_ = codes[x["src_b"]].astype(np.int64)[0]

            def add_term_q10(value, scale, zp):
                ratio = scale / x["s_out"]
                exp = math.floor(math.log2(ratio)) if ratio > 0 else 0
                post = 16 - exp
                m18 = max(min(int(round(ratio * (1 << post))), (1 << 17) - 1),
                          1 << 16)
                bfix = int(round((128.0 - zp) * ratio * (1 << 10)))
                return ((value - 128) * m18 >> (post - 10)) + bfix

            import math
            fixed = add_term_q10(a, x["s_a"], x["zp_a"]) \
                  + add_term_q10(b_, x["s_b"], x["zp_b"])
            out = np.clip(rne_shift(fixed, np.full(fixed.shape, 10, np.int64))
                          + x["zp_out"], 0, 255).astype(np.uint8)[None, ...]
            codes[x["out_code"]] = out
            continue

        if op == "GAP":
            # Match the GAP path in pack_layers.py and RTL: sum values centered
            # at 128, then use the same fixed-point multiplier/Bfix requant.
            src = codes[x["in_code"]].astype(np.int64)[0]
            n = int(x["count"])
            ratio = x["s_in"] / (n * x["s_out"])
            import math
            exp = math.floor(math.log2(ratio)) if ratio > 0 else 0
            post = 16 - exp
            mval = max(min(int(round(ratio * (1 << post))), (1 << 17) - 1),
                           1 << 16)
            m18 = np.full(x["cin"], mval, dtype=np.int64)
            bfix = np.full(x["cin"], int(round(n * (128.0 - x["zp_in"])
                                                * ratio * (1 << 10))), dtype=np.int64)
            acc = (src - 128).sum(axis=(1, 2))
            out = requant(acc[:, None, None], m18, np.full(x["cin"], post), bfix)
            out = np.clip(out.reshape(1, x["cin"], 1, 1) + x["zp_out"],
                          0, 255).astype(np.uint8)
            codes[x["out_code"]] = out
            continue

        raise RuntimeError(f"unhandled op {op} at layer {x['index']}")

    if verbose:
        print("per-layer accumulator peak (int64 exact):")
        for idx, name, peak in stats:
            print(f"  [{idx:2d}] peak={peak:>12,}  {name}")
    return codes, stats


def main() -> int:
    packed = Packed()
    rng = np.random.default_rng(0)
    if len(sys.argv) > 1 and sys.argv[1].endswith(".npy"):
        image = np.load(sys.argv[1])
    else:
        image = rng.uniform(0, 1, (224, 224, 3)).astype(np.float32)
    codes, stats = run_reference(packed, image)
    print("\noutput codes:")
    for name in ("Identity_QuantizeLinear_Output", "Identity_3_QuantizeLinear_Output"):
        if name in codes:
            arr = codes[name].ravel()
            print(f"  {name}: shape={arr.shape} first8={arr[:8]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
