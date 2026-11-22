"""Extract the quantized hand-landmark ONNX graph into a hardware layer table.

The source model is a QDQ-format graph (QuantizeLinear/DequantizeLinear around
every Conv/Gemm), produced by `onnx.quantize`.  This script resolves the QDQ
chains into a plain integer arithmetic description that the RTL can implement
directly:

    code_out[c] = clamp8( rne( (sum_i a_signed[i] * w[c][i] + bias_total[c]) * M[c] ) + zp_out )

where a_signed[i] = a_code[i] ^ 0x80  (uint8 code reinterpreted as signed) and

    bias_total[c] = bias_q[c] + (128 - zp_in) * sum_i w[c][i]
    M[c]          = s_in * s_w[c] / s_out

Outputs (into build/):
    layers.json     ordered layer descriptors consumed by the RTL generator
    weights.bin     int8 weights, layer-concatenated
    bias.bin        int32 folded bias (bias_q + zero-point correction)
    scale.bin       per-channel requant descriptor (pre_shift, M18, post_shift)
    tensors.json    per-tensor quantization table (scale, zero point, dtype)

Run from this directory: python extract_model.py
"""
from __future__ import annotations

import json
import math
import sys
from collections import OrderedDict
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper

ROOT = Path(__file__).resolve().parent
MODEL = ROOT.parents[3] / "software/gesture/models/reference/hand_landmark_lite_int8.onnx"
BUILD = ROOT / "build"

# Requant fixed-point contract, mirrored by rtl/gesture_rq_lane.sv.
PRE_SHIFT = 0          # accumulator >> pre_shift before the multiply
M18_MIN_BIT = 16       # multiplier mantissa normalised into [2^16, 2^17)


def load_graph():
    model = onnx.load(str(MODEL))
    graph = model.graph
    inits = {i.name: numpy_helper.to_array(i) for i in graph.initializer}
    producer = OrderedDict()
    for node in graph.node:
        for out in node.output:
            producer[out] = node
    return graph, inits, producer


def build_quant_maps(graph, inits, producer):
    """Map every float tensor to its code tensor and quantization triple."""
    float_to_code = {}    # float tensor name -> (code name, scale, zero point)
    code_to_quant = {}    # code tensor name  -> (scale, zero point, dtype)
    code_source = {}      # code tensor name  -> float tensor it quantizes
    for node in graph.node:
        if node.op_type != "QuantizeLinear":
            continue
        scale = inits[node.input[1]]
        zp = inits[node.input[2]] if len(node.input) > 2 else np.zeros(1, np.uint8)
        code = node.output[0]
        float_tensor = node.input[0]
        float_to_code[float_tensor] = (code, float(scale), int(np.ravel(zp)[0]))
        code_to_quant[code] = (float(scale), int(np.ravel(zp)[0]), str(zp.dtype))
        code_source[code] = float_tensor
    return float_to_code, code_to_quant, code_source


def build_alias_groups(graph, code_to_quant, producer):
    """Group code tensors that denote the same values.

    Squeeze/QuantizeLinear pairs after GlobalAveragePool re-name the same code
    buffer, so the consumer's `in_code` is not the producer's `out_code`.  Union
    them so lookups by either name resolve.
    """
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    # DequantizeLinear is included so a Squeeze that consumes the float view of
    # a code tensor still resolves back to that code tensor.
    TRANSPARENT = ("Squeeze", "Reshape", "Transpose", "Flatten", "DequantizeLinear")

    def resolve_code(src):
        for _ in range(12):
            step = producer.get(src)
            if step is None or step.op_type not in TRANSPARENT:
                break
            src = step.input[0]
        return src if src in code_to_quant else None

    for node in graph.node:
        if node.op_type not in ("Squeeze", "QuantizeLinear"):
            continue
        source = resolve_code(node.input[0])
        if source is not None:
            union(node.output[0], source)
    return {name: find(name) for name in parent}


def canon(name, aliases):
    return aliases.get(name, name)


def deq_source(name, producer):
    """Resolve a Conv/Gemm operand to the code tensor feeding a DequantizeLinear."""
    node = producer.get(name)
    if node is not None and node.op_type == "DequantizeLinear":
        return node.input[0]
    return name


def deq_initializer(name, producer, inits):
    node = producer.get(name)
    if node is not None and node.op_type == "DequantizeLinear":
        weight = inits[node.input[0]]
        scale = inits[node.input[1]]
        zp = inits[node.input[2]] if len(node.input) > 2 else None
        return weight, scale, zp, node.input[0]
    return None, None, None, name


def requant_descriptor(m: float, pre_shift: int) -> tuple[int, int]:
    """Return (M18, post_shift) with m ~= M18 * 2^-post_shift, M18 in [2^16, 2^17).

    `pre_shift` is the amount the accumulator is pre-shifted before the
    multiply, so the effective multiplier is m * 2^pre_shift.
    """
    value = m * (1 << pre_shift)
    if value <= 0:
        return 0, 0
    exponent = math.floor(math.log2(value))
    post_shift = 16 - exponent            # M18 = value * 2^post_shift in [2^16,2^17)
    m18 = int(round(value * (1 << post_shift)))
    if m18 >= (1 << 17):                  # rounding pushed it over
        post_shift -= 1
        m18 = int(round(value * (1 << post_shift)))
    m18 = max(m18, 1 << 16)
    m18 = min(m18, (1 << 17) - 1)
    return m18, post_shift


def main() -> int:
    graph, inits, producer = load_graph()
    float_to_code, code_to_quant, code_source = build_quant_maps(graph, inits, producer)
    aliases = build_alias_groups(graph, code_to_quant, producer)

    value_info = {v.name: v for v in list(graph.value_info) + list(graph.input) + list(graph.output)}
    elem_type = {1: "f32", 2: "u8", 3: "i8", 6: "i32", 7: "i64"}

    def tensor_type(name):
        v = value_info.get(name)
        if v is None:
            return "?"
        return elem_type.get(v.type.tensor_type.elem_type, "?")

    def quant_of_code(code):
        """Quantization of a code tensor (falls back to its QuantizeLinear)."""
        if code in code_to_quant:
            return code_to_quant[code]
        node = producer.get(code)
        if node is not None and node.op_type == "QuantizeLinear":
            scale = inits[node.input[1]]
            zp = inits[node.input[2]]
            return float(scale), int(np.ravel(zp)[0]), str(zp.dtype)
        raise KeyError(f"no quantization known for tensor {code!r}")

    # ---- shape propagation over the logical (post-QDQ) graph -------------
    shapes = {}
    shapes["input_1"] = (1, 224, 224, 3)

    def shape(name):
        return shapes.get(name)

    def conv_hw(h, w, k, s, p_begin, p_end):
        return (h + p_begin + p_end - k) // s + 1, (w + p_begin + p_end - k) // s + 1

    layers = []
    stats = {
        "total_mac": 0,
        "weight_bytes": 0,
        "bias_bytes": 0,
        "param_bytes": 0,
    }

    weight_blob = bytearray()
    bias_blob = bytearray()
    bfix_blob = bytearray()
    param_blob = bytearray()

    def emit_weight(row: np.ndarray) -> int:
        off = len(weight_blob)
        weight_blob.extend(row.astype(np.int8).tobytes())
        return off

    def emit_bias(row: np.ndarray) -> int:
        off = len(bias_blob)
        bias_blob.extend(row.astype("<i4").tobytes())
        return off

    def emit_bfix(row: np.ndarray) -> int:
        off = len(bfix_blob)
        bfix_blob.extend(row.astype("<i4").tobytes())
        return off

    def emit_param(pre_shift: int, m18: np.ndarray, post_shift: np.ndarray, zp_out: np.ndarray) -> int:
        """Per-channel (pre_shift, M18, post_shift, zero point) descriptor, 6 bytes."""
        off = len(param_blob)
        for i in range(len(m18)):
            param_blob.extend(int(pre_shift).to_bytes(2, "little"))
            param_blob.extend(int(m18[i]).to_bytes(3, "little"))
            param_blob.extend(int(post_shift[i]).to_bytes(1, "little"))
        param_blob.extend(np.asarray(zp_out, np.uint8).tobytes())
        return off

    # ---- walk the graph ---------------------------------------------------
    for node in graph.node:
        if node.op_type == "Transpose":
            src = shape(node.input[0])
            shapes[node.output[0]] = (src[0], src[3], src[1], src[2])
            continue
        if node.op_type in ("QuantizeLinear", "DequantizeLinear"):
            if node.input[0] in shapes:
                shapes[node.output[0]] = shapes[node.input[0]]
            continue
        if node.op_type == "Squeeze":
            src = shape(node.input[0])
            shapes[node.output[0]] = (1, src[1])
            continue
        if node.op_type == "Sigmoid":
            shapes[node.output[0]] = shape(node.input[0])
            continue

        attrs = {a.name: (list(a.ints) if a.ints else a.i) for a in node.attribute}

        if node.op_type in ("Conv", "Gemm"):
            activation_code = canon(deq_source(node.input[0], producer), aliases)
            s_in, zp_in, _ = quant_of_code(activation_code)
            weight, w_scale, w_zp, wname = deq_initializer(node.input[1], producer, inits)
            if weight is None:
                raise RuntimeError(f"unresolved weight for {node.name}")

            float_out = node.output[0]
            if node.op_type == "Gemm":
                # Gemm is Y = A*B + C with B shaped (K, N): the classifier matrix
                # is stored transposed relative to a Conv weight, so flip it to
                # the (cout, cin) layout used everywhere else.
                weight = np.ascontiguousarray(weight.T)
                out_code, s_out, zp_out = float_to_code[float_out]
                co = weight.shape[0]
                kernel = (1, 1)
                stride = (1, 1)
                pads = (0, 0, 0, 0)
                group = 1
                cin = weight.shape[1]
                hw = (1, 1)
                hw_in = (1, 1)
                kind = "PW"
                macs = co * cin
            else:
                out_code, s_out, zp_out = float_to_code[float_out]
                kernel = tuple(attrs["kernel_shape"])
                stride = tuple(attrs.get("strides", [1, 1]))
                pads = tuple(attrs.get("pads", [0, 0, 0, 0]))
                group = attrs.get("group", 1)
                in_shape = shape(activation_code)
                ho, wo = conv_hw(in_shape[2], in_shape[3], kernel[0], stride[0], pads[0], pads[2])
                hw = (ho, wo)
                hw_in = (in_shape[2], in_shape[3])
                cout = weight.shape[0]
                cin_per_group = weight.shape[1]
                cin = cin_per_group * group
                macs = ho * wo * kernel[0] * kernel[1] * cin_per_group * cout
                if group > 1:
                    kind = "DW"
                elif kernel[0] == 1 and kernel[1] == 1:
                    kind = "PW"
                else:
                    kind = "CONV"

            shapes[out_code] = (1, len(w_scale) if w_scale.ndim > 0 else 1, *hw)

            co = weight.shape[0]
            w_scale = np.atleast_1d(w_scale).astype(np.float64)
            if w_scale.size == 1:
                w_scale = np.repeat(w_scale, co)
            w_zp_arr = np.atleast_1d(w_zp) if w_zp is not None else np.zeros(1)
            if w_zp_arr.size == 1:
                w_zp_arr = np.repeat(w_zp_arr, co)
            bias_q = None
            if len(node.input) > 2:
                _, _, _, bname = deq_initializer(node.input[2], producer, inits)
                # bias is a plain int32 initializer (no DequantizeLinear wrapper)
                cand = inits.get(bname)
                if cand is None:
                    cand = inits.get(node.input[2])
                bias_q = np.asarray(cand, np.int64)
            if bias_q is None:
                bias_q = np.zeros(co, np.int64)

            # fold the input zero point into the bias: the MAC runs on
            # a_signed = a_code ^ 0x80, i.e. a_code - 128.
            row_sum = weight.reshape(co, -1).astype(np.int64).sum(axis=1)
            bias_total = bias_q + (128 - zp_in) * row_sum

            # requant multiplier: M = s_in * s_w / s_out
            m = (s_in * w_scale) / s_out
            m18 = np.zeros(co, np.int64)
            post = np.zeros(co, np.int64)
            for c in range(co):
                m18[c], post[c] = requant_descriptor(float(m[c]), PRE_SHIFT)

            # Hardware form of the requant: the bias is pre-reduced into the
            # same shifted domain as the product, in units of 2^-10 output codes,
            # so the accumulator never has to hold the (often enormous) bias.
            #   y = rne( ((p * m18) >> (post-10)) + B_fixed , 10 ) + zp
            bfix = np.rint(bias_total.astype(np.float64) * m18 *
                            np.exp2(-(post.astype(np.float64) - 10))).astype(np.int64)
            w_off = emit_weight(weight.reshape(co, -1))
            b_off = emit_bias(bias_total)
            f_off = emit_bfix(bfix)
            p_off = emit_param(PRE_SHIFT, m18, post, np.full(co, zp_out, np.uint8))

            stats["total_mac"] += int(macs)
            stats["weight_bytes"] += int(weight.size)
            stats["bias_bytes"] += int(bias_total.nbytes)
            stats["param_bytes"] += int(6 * co + co)

            layers.append({
                "index": len(layers),
                "onnx_name": node.name,
                "name": node.name.split(";")[0][:48],
                "op": kind,
                "cin": int(cin),
                "cout": int(co),
                "group": int(group),
                "kernel": list(kernel),
                "stride": list(stride),
                "pads": list(pads),
                "in_hw": list(hw_in),
                "out_hw": list(hw),
                "macs": int(macs),
                "in_code": activation_code,
                "out_code": out_code,
                "s_in": s_in, "zp_in": zp_in,
                "s_out": s_out, "zp_out": zp_out,
                "s_w_first": float(w_scale[0]),
                "s_w_last": float(w_scale[-1]),
                "w_zero_point": int(w_zp_arr[0]),
                "w_zero_point_all_zero": bool(np.all(w_zp_arr == 0)),
                "bias_absmax": int(np.abs(bias_total).max()),
                "acc_absmax_loose": int(np.abs(bias_total).max() + 128 * np.abs(weight.reshape(co, -1)).sum(axis=1).max()),
                "m_min": float(m.min()), "m_max": float(m.max()),
                "m18_min": int(m18.min()), "m18_max": int(m18.max()),
                "post_shift_min": int(post.min()), "post_shift_max": int(post.max()),
                "weight_off": w_off, "bias_off": b_off, "param_off": p_off,
                "bfix_off": f_off,
                "bfix_absmax": int(np.abs(bfix).max()),
            })
            continue

        if node.op_type == "MaxPool":
            src = canon(deq_source(node.input[0], producer), aliases)
            in_shape = shape(src)
            k = attrs["kernel_shape"][0]
            s = attrs.get("strides", [1, 1])[0]
            ho = (in_shape[2] - k) // s + 1
            wo = (in_shape[3] - k) // s + 1
            out_code, s_out, zp_out = float_to_code[node.output[0]]
            shapes[out_code] = (1, in_shape[1], ho, wo)
            layers.append({
                "index": len(layers), "onnx_name": node.name, "name": "maxpool",
                "op": "MAXPOOL", "cin": in_shape[1], "cout": in_shape[1], "group": 1,
                "kernel": [k, k], "stride": [s, s], "pads": [0, 0, 0, 0],
                "in_hw": [in_shape[2], in_shape[3]], "out_hw": [ho, wo], "macs": 0,
                "in_code": src, "out_code": out_code,
                "s_in": quant_of_code(src)[0], "zp_in": quant_of_code(src)[1],
                "s_out": s_out, "zp_out": zp_out,
            })
            continue

        if node.op_type == "Add":
            a_code = canon(deq_source(node.input[0], producer), aliases)
            b_code = canon(deq_source(node.input[1], producer), aliases)
            out_code, s_out, zp_out = float_to_code[node.output[0]]
            shapes[out_code] = shape(a_code)
            layers.append({
                "index": len(layers), "onnx_name": node.name, "name": "add",
                "op": "ADD", "cin": shape(a_code)[1], "cout": shape(a_code)[1], "group": 1,
                "kernel": [1, 1], "stride": [1, 1], "pads": [0, 0, 0, 0],
                "in_hw": list(shape(a_code)[2:]), "out_hw": list(shape(a_code)[2:]),
                "macs": 0, "src_a": a_code, "src_b": b_code, "out_code": out_code,
                "s_a": quant_of_code(a_code)[0], "zp_a": quant_of_code(a_code)[1],
                "s_b": quant_of_code(b_code)[0], "zp_b": quant_of_code(b_code)[1],
                "s_out": s_out, "zp_out": zp_out,
            })
            continue

        if node.op_type == "GlobalAveragePool":
            src = canon(deq_source(node.input[0], producer), aliases)
            in_shape = shape(src)
            out_code, s_out, zp_out = float_to_code[node.output[0]]
            shapes[out_code] = (1, in_shape[1], 1, 1)
            layers.append({
                "index": len(layers), "onnx_name": node.name, "name": "gap", "op": "GAP",
                "cin": in_shape[1], "cout": in_shape[1], "group": 1,
                "kernel": [1, 1], "stride": [1, 1], "pads": [0, 0, 0, 0],
                "in_hw": [in_shape[2], in_shape[3]], "out_hw": [1, 1], "macs": 0,
                "in_code": src, "out_code": out_code,
                "s_in": quant_of_code(src)[0], "zp_in": quant_of_code(src)[1],
                "s_out": s_out, "zp_out": zp_out,
                "count": in_shape[2] * in_shape[3],
            })
            continue

        if node.op_type in ("Relu", "Clip"):
            shapes[node.output[0]] = shape(node.input[0])
            continue

        raise RuntimeError(f"unhandled op {node.op_type} ({node.name})")

    # ---- outputs ---------------------------------------------------------
    for x in layers:
        for key in ("in_code", "out_code", "src_a", "src_b"):
            if key in x:
                x[key] = canon(x[key], aliases)

    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "weights.bin").write_bytes(bytes(weight_blob))
    (BUILD / "bias.bin").write_bytes(bytes(bias_blob))
    (BUILD / "bfix.bin").write_bytes(bytes(bfix_blob))
    (BUILD / "param.bin").write_bytes(bytes(param_blob))
    (BUILD / "layers.json").write_text(json.dumps(layers, indent=1, default=str))

    conv_layers = [x for x in layers if x["op"] in ("PW", "DW", "CONV")]
    print(f"layers: {len(layers)}  (conv/pw/dw {len(conv_layers)}, "
          f"maxpool {sum(1 for x in layers if x['op']=='MAXPOOL')}, "
          f"add {sum(1 for x in layers if x['op']=='ADD')}, gap {sum(1 for x in layers if x['op']=='GAP')})")
    print(f"total MAC          : {stats['total_mac']:,}  ({stats['total_mac']/1e6:.2f} MMAC)")
    print(f"int8 weight bytes  : {stats['weight_bytes']:,}")
    print(f"int32 bias bytes   : {stats['bias_bytes']:,}")
    print(f"packed param bytes : {stats['param_bytes']:,}")
    bf = [x.get("bfix_absmax", 0) for x in layers if "bfix_absmax" in x]
    print(f"B_fixed width      : {max(bf).bit_length()} bit signed (max {max(bf):,}, "
          f"{max(bf)/1024:.1f} output codes)")

    worst = [x for x in conv_layers if not x["w_zero_point_all_zero"]]
    print(f"conv layers with non-zero weight zero point: {len(worst)}")
    bad_post = [x for x in conv_layers if x["post_shift_min"] < 0]
    print(f"conv layers with negative post_shift: {len(bad_post)}")
    print("\npost_shift / M18 / m ranges:")
    for x in conv_layers[:6] + conv_layers[-4:]:
        print(f"  [{x['index']:2d}] {x['op']:4} {x['cin']:4}->{x['cout']:<4} k{x['kernel'][0]} "
              f"s{x['stride'][0]} {x['out_hw']} m=[{x['m_min']:.3e},{x['m_max']:.3e}] "
              f"M18=[{x['m18_min']},{x['m18_max']}] post=[{x['post_shift_min']},{x['post_shift_max']}] "
              f"zp_out={x['zp_out']} bias_amax={x['bias_absmax']:,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
