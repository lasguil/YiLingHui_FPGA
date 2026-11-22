"""Fold the flat layer list into the hardware op list, with tensor allocation.

An op is one fused unit the RTL engine executes:

  STEM   conv 3x3/s2 -> depthwise -> 1x1 project          (image -> t0)
  BLOCK  1x1 expand  -> depthwise -> 1x1 project (+ skip)
  TAIL   1x1 expand  -> depthwise                (feeds the global average pool)
  HEAD   global average pool + 4 fully connected layers

Grouping uses the graph's own tensor wiring, not layer adjacency, because ADD
and MAXPOOL layers sit between convolutions.  The expansion tensor inside an op
is never materialised (112x112x64 alone is 802 KiB against a 320 KiB device);
the fused row pipeline is what keeps the whole thing on chip.

Residual wiring is subtler than "add the previous op".  Every ADD joins two
tensors; the ADD belongs to whichever of the two *ops* runs later, and that op
reads the earlier one as its skip.  That is what makes `add_2 = B4.project +
B3.project` work: B3's project stays live until B4 finishes.

Run from this directory: python build_ops.py
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"

T_IMAGE = 0xFE
T_RESULT = 0xFF


def main() -> int:
    layers = json.loads((BUILD / "layers.json").read_text())
    conv = [x for x in layers if x["op"] in ("PW", "DW", "CONV")]
    adds = [x for x in layers if x["op"] == "ADD"]
    pools = {x["out_code"]: x for x in layers if x["op"] == "MAXPOOL"}
    gaps = [x for x in layers if x["op"] == "GAP"]

    # ------------------------------------------------------------- grouping
    ops = []
    i = 0
    while i < len(conv):
        a = conv[i]
        b = conv[i + 1] if i + 1 < len(conv) else None
        c = conv[i + 2] if i + 2 < len(conv) else None
        chain_dw = b is not None and b["op"] == "DW" and b["in_code"] == a["out_code"]
        chain_pw = (c is not None and c["op"] == "PW" and c["in_code"] == b["out_code"]
                    and c["cin"] == b["cout"] and a["cout"] == b["cin"] == b["cout"])

        if a["op"] == "CONV" and chain_dw and chain_pw:
            ops.append({"kind": "STEM", "pre": a, "exp": None, "dw": b, "proj": c})
            i += 3
        elif chain_dw and chain_pw and a["kernel"][0] == 1:
            ops.append({"kind": "BLOCK", "pre": None, "exp": a, "dw": b, "proj": c})
            i += 3
        elif chain_dw and a["kernel"][0] == 1:
            ops.append({"kind": "TAIL", "pre": None, "exp": a, "dw": b, "proj": None})
            i += 2
        elif a["in_hw"] == [1, 1]:
            head = [x for x in conv[i:] if x["in_hw"] == [1, 1]]
            ops.append({"kind": "HEAD", "pre": None, "exp": None, "dw": None,
                        "proj": None, "head": head})
            i += len(head)
        else:
            raise SystemExit(f"layer {a['index']} ({a['op']} {a['cin']}->{a['cout']}) "
                             f"is not groupable")

    for n, op in enumerate(ops):
        op["id"] = n

    # --------------------------------------------------- op membership maps
    op_of_layer = {}
    for op in ops:
        for key in ("pre", "exp", "dw", "proj"):
            if op[key] is not None:
                op_of_layer[op[key]["index"]] = op["id"]
        for lyr in op.get("head", []):
            op_of_layer[lyr["index"]] = op["id"]

    layer_of_code = {x["out_code"]: x["index"] for x in conv}

    def op_of_code(code):
        """Op that produces `code`, looking through a max pool if needed."""
        if code in pools:
            code = pools[code]["in_code"]
        idx = layer_of_code.get(code)
        return None if idx is None else op_of_layer[idx]

    # ------------------------------------------------------------- residuals
    for op in ops:
        if op["kind"] != "HEAD":
            op["own_code"] = (op["proj"] or op["dw"])["out_code"]
            op["out_code"] = op["own_code"]
        else:
            op["own_code"] = None
            op["out_code"] = T_RESULT
        op["skip_tensor"] = None

    for add in adds:
        oa, ob = op_of_code(add["src_a"]), op_of_code(add["src_b"])
        if oa is None or ob is None or oa == ob:
            continue
        later, earlier = (oa, ob) if oa > ob else (ob, oa)
        if ops[later]["kind"] == "HEAD":
            continue
        ops[later]["out_code"] = add["out_code"]
        ops[later]["skip_tensor"] = earlier

    names = {T_IMAGE: "image", T_RESULT: "result"}
    for op in ops:
        if op["kind"] != "HEAD":
            names[op["id"]] = f"t{op['id']}"

    print("op chain:")
    for op in ops:
        d, p = op["dw"], op["proj"]
        if op["kind"] == "HEAD":
            print(f"  op{op['id']:2d} HEAD   {len(op['head'])} fc layers"
                  f"  ({', '.join(f'{x['cin']}->{x['cout']}' for x in op['head'])})")
            continue
        src = op["pre"] or op["exp"]
        print(f"  op{op['id']:2d} {op['kind']:5} in={src['cin']:4d} "
              f"exp={op['exp']['cout'] if op['exp'] else '-':>4} "
              f"conv={op['pre']['cout'] if op['pre'] else '-':>4} "
              f"dw={d['cout']:4d}x{d['kernel'][0]}s{d['stride'][0]} "
              f"proj={p['cout'] if p else '-':>4} @{d['out_hw']}  "
              f"out={names[op['id']]:5} skip={names.get(op['skip_tensor'], '-')}")

    # ------------------------------------------------- sizes and liveness
    size_of = {}
    for op in ops:
        if op["kind"] == "HEAD":
            continue
        proj = op["proj"] or op["dw"]
        h, w = proj["out_hw"]
        c = op["proj"]["cout"] if op["proj"] else op["dw"]["cout"]
        size_of[op["id"]] = h * w * c

    last_read = {}
    for op in ops:
        if op["kind"] == "HEAD":
            continue
        src = op["pre"] or op["exp"]
        producer = op_of_code(src["in_code"])
        if producer is not None:
            last_read[producer] = max(last_read.get(producer, -1), op["id"])
        if op["skip_tensor"] is not None:
            last_read[op["skip_tensor"]] = max(last_read.get(op["skip_tensor"], -1), op["id"])

    # ------------------------------------------------------------ allocation
    addr, free, high = {}, [], 0
    for op in ops:
        if op["kind"] == "HEAD":
            continue
        tid = op["id"]
        for t in [t for t in addr if last_read.get(t, 1 << 30) < tid]:
            base = addr.pop(t)
            free.append((base, size_of[t]))
        free.sort()
        want = size_of[tid]
        placed = None
        for k, (base, cap) in enumerate(free):
            if cap >= want:
                placed = base
                free.pop(k)
                if cap > want:
                    free.append((base + want, cap - want))
                    free.sort()
                break
        if placed is None:
            placed = high
            high += want
        addr[tid] = placed

    print(f"\nactivation store: {high:,} B = {high/1024:.1f} KiB")
    for tid in sorted(addr, key=lambda t: addr[t]):
        print(f"   {names[tid]:5} @ {addr[tid]:7,}  size {size_of[tid]:7,}  "
              f"last read by op {last_read.get(tid, -1)}")
    if gaps:
        print(f"head: gap + {len(ops[-1]['head'])} fc layers -> result")

    (BUILD / "ops.json").write_text(json.dumps({
        "ops": ops, "tensor_addr": addr, "tensor_size": size_of,
        "activation_bytes": high,
    }, indent=1, default=str))
    print(f"\nwrote {BUILD/'ops.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
