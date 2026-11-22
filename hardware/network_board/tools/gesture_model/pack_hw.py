"""Emit the hardware-facing images: repacked weights, parameter table, descriptors.

The engine reads 32 weight bytes per cycle, one per MAC lane.  Lane l of an
op step always wants the weight of *output channel* (block_base + l), so the
weights must be transposed into [step][channel] order:

  1x1 expand / project : step = input channel   -> [cin][cout]
  depthwise            : step = kernel tap      -> [k*k][channels]
  stem conv 3x3        : lane = output channel, step = (ky,kx,ci)

Reading 32 consecutive channels at a fixed step is then one aligned 32-byte
transfer, which is exactly the weight buffer's natural word.

Outputs (into build/):
  weights_hw.bin   repacked int8 weights, per-layer byte offsets in ops.json
  param_hw.bin     8 bytes per output channel: m18:u24, post:u8, bfix:i32, zp:u8
  desc.svh         the descriptor table as SystemVerilog localparams
  memmap.json      DDR byte offsets for weights / params / image / scores

Run from this directory: python pack_hw.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
sys_path = ROOT
import sys
sys.path.insert(0, str(sys_path))
from int8_reference import Packed  # noqa: E402

BUILD = ROOT / "build"
C32 = 32          # activation channel block / lane count
DDR_ALIGN = 4096


def align(value: int, boundary: int = DDR_ALIGN) -> int:
    return (value + boundary - 1) // boundary * boundary


def main() -> int:
    packed = Packed()
    ops = json.loads((BUILD / "ops.json").read_text())["ops"]

    weight_blob = bytearray()
    descs = []

    def emit_layer(x, layout: str) -> dict:
        """Append one layer's weights transposed, return its offsets/params."""
        w = packed.weights_of(x).astype(np.int8)      # (cout, cin_g, kh, kw)
        p = packed.param[x["index"]]
        co = x["cout"]
        cin_g = x["cin"] // x["group"]
        kh, kw = x["kernel"]

        if layout == "pointwise":
            # [ci][co]  -> 32 consecutive co per step
            blob = np.ascontiguousarray(w[:, :, 0, 0].T)          # (cin, co)
            steps = cin_g
        elif layout == "depthwise":
            blob = np.ascontiguousarray(w[:, 0, :, :].reshape(co, kh * kw).T)  # (k*k, co)
            steps = kh * kw
        elif layout == "stem":
            # lane = output channel, step = (ky, kx, ci)
            # step = ((ky*kw)+kx)*cin + ci  ->  (kh, kw, ci, co) flattened to 2-D
            blob = np.ascontiguousarray(w.transpose(2, 3, 1, 0).reshape(kh * kw * cin_g, co))
            steps = kh * kw * cin_g
        else:
            raise ValueError(layout)

        # the engine reads whole 32-byte groups, so pad cout up to a multiple
        pad = (C32 - co % C32) % C32
        if pad:
            blob = np.concatenate([blob, np.zeros((blob.shape[0], pad), np.int8)], axis=1)
        off = len(weight_blob)
        weight_blob.extend(blob.tobytes())

        # parameter table: one 8-byte record per output channel
        p_off = len(param_blob) // 8
        for c in range(co):
            param_blob.extend(int(p["m18"][c]).to_bytes(3, "little"))
            param_blob.extend(int(p["post"][c]).to_bytes(1, "little"))
            param_blob.extend(int(p["bfix"][c]).to_bytes(4, "little", signed=True))
            param_blob.extend(int(p["zp"][c]).to_bytes(1, "little"))
        for _ in range(pad):
            param_blob.extend(b"\x00" * 8)

        return {
            "co": co, "co_padded": co + pad, "cin": cin_g,
            "k": kh, "stride": x["stride"][0],
            "pad_top": x["pads"][0], "pad_left": x["pads"][1],
            "steps": steps, "w_off": off, "p_off": p_off,
            "s_in": x["s_in"], "zp_in": x["zp_in"],
            "in_code": x["in_code"], "out_code": x["out_code"],
            "groups": co + pad,
        }

    param_blob = bytearray()

    for op in ops:
        if op["kind"] == "HEAD":
            descs.append({"kind": 3, "head": [emit_layer(x, "pointwise")
                                              for x in op["head"]]})
            continue
        entry = {"kind": {"STEM": 0, "BLOCK": 1, "TAIL": 2}[op["kind"]],
                 "tensor_in": op["id"] - 1 if op["id"] > 0 else None,
                 "tensor_out": op["id"],
                 "skip": op["skip_tensor"],
                 "in_c": (op["pre"] or op["exp"])["cin"],
                 "in_hw": (op["pre"] or op["exp"])["in_hw"],
                 "out_hw": op["dw"]["out_hw"]}
        if op["pre"] is not None:
            entry["stem"] = emit_layer(op["pre"], "stem")
        if op["exp"] is not None:
            entry["expand"] = emit_layer(op["exp"], "pointwise")
        entry["dw"] = emit_layer(op["dw"], "depthwise")
        if op["proj"] is not None:
            entry["proj"] = emit_layer(op["proj"], "pointwise")
        descs.append(entry)

    (BUILD / "weights_hw.bin").write_bytes(bytes(weight_blob))
    (BUILD / "param_hw.bin").write_bytes(bytes(param_blob))

    # ---- DDR memory map -------------------------------------------------
    w_base = 0
    p_base = align(w_base + len(weight_blob))
    img_base = align(p_base + len(param_blob))
    out_base = align(img_base + 224 * 224 * 3)
    memmap = {
        "weights": {"base": w_base, "bytes": len(weight_blob)},
        "params":  {"base": p_base, "bytes": len(param_blob)},
        "image":   {"base": img_base, "bytes": 224 * 224 * 3, "hwc": [224, 224, 3]},
        "scores":  {"base": out_base, "bytes": 128},
        "total":   out_base + 128,
    }

    # ---- descriptor table as SystemVerilog ------------------------------
    ops_json = json.loads((BUILD / "ops.json").read_text())
    addr = {int(k): v for k, v in ops_json["tensor_addr"].items()}
    size = {int(k): v for k, v in ops_json["tensor_size"].items()}

    # park the tensors in DDR right after the image
    t_base = {}
    cursor = align(img_base + 224 * 224 * 3)
    for tid in sorted(size):
        t_base[tid] = cursor
        cursor = align(cursor + size[tid])
    memmap["tensors"] = {"base": align(img_base + 224 * 224 * 3),
                         "bytes": cursor - align(img_base + 224 * 224 * 3),
                         "per_op": {str(k): v for k, v in t_base.items()}}
    memmap["total"] = cursor

    def flat(entry, key, field, default=0):
        return entry.get(key, {}).get(field, default) if key in entry else default

    lines = ["// 由 pack_hw.py 生成，不要手改。",
             "// 每个算子一条记录；张量地址是 DDR 字节偏移。",
             "`ifndef GESTURE_DESC_SVH",
             "`define GESTURE_DESC_SVH",
             "",
             "typedef struct packed {",
             "    logic [1:0]  kind;      // 0=stem 1=block 2=tail 3=head",
             "    logic [3:0]  mode;      // 位：{skip, proj, expand, stem}",
             "    logic [9:0]  in_c, in_w, in_h;",
             "    logic [9:0]  mid_w, mid_h;",
             "    logic [9:0]  out_w, out_h;",
             "    logic [9:0]  exp_c, dw_c, proj_c;",
             "    logic [2:0]  k, stride, pad_t, pad_l;",
             "    logic [2:0]  pre_k, pre_s, pre_pad_t, pre_pad_l;",
             "    logic [31:0] w_stem, w_exp, w_dw, w_proj;",
             "    logic [31:0] p_stem, p_exp, p_dw, p_proj, p_skip;",
             "    logic [31:0] t_in, t_out, t_skip;",
             "} gesture_op_t;",
             "",
             f"localparam int OP_COUNT = {len(descs)};",
             "",
             "function automatic gesture_op_t gesture_op(input int unsigned id);",
             "    gesture_op_t r;",
             "    r = '0;",
             "    case (id)"]
    head_only = []
    for n, d in enumerate(descs):
        if d["kind"] == 3:
            head_only.append(n)
            lines.append(f"        32'd{n}: r = '{{kind:2'd3, default:0}};")
            continue
        mode = 0
        if "stem" in d:   mode |= 1
        if "expand" in d: mode |= 2
        if "proj" in d:   mode |= 4
        if d.get("skip") is not None: mode |= 8
        t_in = t_base[d["tensor_in"]] if d["tensor_in"] is not None else img_base
        t_out = t_base[d["tensor_out"]]
        t_skip = t_base[d["skip"]] if d.get("skip") is not None else 0
        dw = d["dw"]
        if "stem" in d:
            pre = d["stem"]
            mid_w, mid_h = d["out_hw"]
            pre_k, pre_s = pre["k"], pre["stride"]
            pre_pt, pre_pl = pre["pad_top"], pre["pad_left"]
        else:
            mid_w, mid_h = d["in_hw"][1], d["in_hw"][0]
            pre_k = pre_s = pre_pt = pre_pl = 0
        lines.append(
            f"        32'd{n}: r = '{{kind:2'd{d['kind']}, mode:4'd{mode}, "
            f"in_c:10'd{d['in_c']}, in_w:10'd{d['in_hw'][1]}, in_h:10'd{d['in_hw'][0]}, "
            f"mid_w:10'd{mid_w}, mid_h:10'd{mid_h}, "
            f"out_w:10'd{d['out_hw'][1]}, out_h:10'd{d['out_hw'][0]}, "
            f"exp_c:10'd{flat(d,'expand','co_padded')}, dw_c:10'd{dw['co_padded']}, "
            f"proj_c:10'd{flat(d,'proj','co_padded')}, "
            f"k:3'd{dw['k']}, stride:3'd{dw['stride']}, "
            f"pad_t:3'd{dw['pad_top']}, pad_l:3'd{dw['pad_left']}, "
            f"pre_k:3'd{pre_k}, pre_s:3'd{pre_s}, "
            f"pre_pad_t:3'd{pre_pt}, pre_pad_l:3'd{pre_pl}, "
            f"w_stem:32'd{flat(d,'stem','w_off')}, w_exp:32'd{flat(d,'expand','w_off')}, "
            f"w_dw:32'd{dw['w_off']}, w_proj:32'd{flat(d,'proj','w_off')}, "
            f"p_stem:32'd{flat(d,'stem','p_off')}, p_exp:32'd{flat(d,'expand','p_off')}, "
            f"p_dw:32'd{dw['p_off']}, p_proj:32'd{flat(d,'proj','p_off')}, "
            f"p_skip:32'd{flat(d,'proj','p_off')}, "
            f"t_in:32'd{t_in}, t_out:32'd{t_out}, t_skip:32'd{t_skip}}};")
    lines += ["        default: r = '0;",
              "    endcase",
              "    gesture_op = r;",
              "endfunction",
              ""]
    for n in head_only:
        h = descs[n]["head"]
        for j, e in enumerate(h):
            lines.append(f"localparam logic [31:0] HEAD{j}_W = 32'd{e['w_off']};")
            lines.append(f"localparam logic [31:0] HEAD{j}_P = 32'd{e['p_off']};")
            lines.append(f"localparam int HEAD{j}_CIN = {e['cin']};")
            lines.append(f"localparam int HEAD{j}_COUT = {e['co']};")
        lines.append(f"localparam int HEAD_N = {len(h)};")
        lines.append(f"localparam int HEAD_OP = {n};")
    lines += ["", "`endif", ""]
    (BUILD / "desc.svh").write_text("\n".join(lines), encoding="utf-8")

    print(f"weights_hw : {len(weight_blob):,} B")
    print(f"param_hw   : {len(param_blob):,} B  ({len(param_blob)//8} channels)")
    print(f"ops        : {len(descs)}")
    print("DDR map:")
    for k, v in memmap.items():
        if isinstance(v, dict):
            print(f"   {k:8} @ 0x{v['base']:08X}  {v['bytes']:,} B")
        else:
            print(f"   {'total':8}   0x{v:08X}  ({v/1024/1024:.2f} MiB)")
    (BUILD / "memmap.json").write_text(json.dumps(memmap, indent=1))
    (BUILD / "desc.json").write_text(json.dumps(descs, indent=1, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
