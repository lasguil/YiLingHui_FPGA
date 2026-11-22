#!/usr/bin/env python3
"""Map-aware signoff for bundled CDC payload capture paths.

The mapped netlist, rather than RTL vector widths, is authoritative: optimized
constant fields are classified from the source FF D pin, while dynamic bits
must resolve to a destination-clock FF whose D pin is driven by that source Q.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Bank:
    name: str
    source_prefix: str
    source_signal: str
    width: int
    source_clock: str
    dest_clock: str
    bound_ns: int
    known_static: dict[int, str]


def reasons(ranges: list[tuple[int, int, str]]) -> dict[int, str]:
    return {b: why for lo, hi, why in ranges for b in range(lo, hi + 1)}


BANKS = [
    Bank("cpu_aw", "u_cpu_ddr_bridge/u_aw_mailbox", "data_q", 49, "core_clk", "proc_clk", 10,
         reasons([(0, 1, "AWBURST fixed INCR=01"), (2, 4, "AWSIZE fixed 128-bit=4"),
                  (5, 12, "AWLEN fixed single beat=0"), (13, 16, "AWADDR 16-byte aligned"),
                  (45, 48, "DDR client AWID fixed 0")])),
    Bank("cpu_w", "u_cpu_ddr_bridge/u_w_mailbox", "data_q", 145, "core_clk", "proc_clk", 10,
         {0: "WLAST fixed 1 for serialized single-beat transactions"}),
    Bank("cpu_ar", "u_cpu_ddr_bridge/u_ar_mailbox", "data_q", 49, "core_clk", "proc_clk", 10,
         reasons([(0, 1, "ARBURST fixed INCR=01"), (2, 4, "ARSIZE fixed 128-bit=4"),
                  (5, 12, "ARLEN fixed single beat=0"), (13, 16, "ARADDR 16-byte aligned"),
                  (45, 48, "DDR client ARID fixed 0")])),
    Bank("cpu_b", "u_cpu_ddr_bridge/u_b_mailbox", "data_q", 6, "proc_clk", "core_clk", 18,
         reasons([(0, 1, "BRESP is fixed OKAY=00 for the DDR bridge")])),
    Bank("cpu_r", "u_cpu_ddr_bridge/u_r_mailbox", "data_q", 135, "proc_clk", "core_clk", 18,
         reasons([(1, 2, "RRESP is fixed OKAY=00 for the DDR bridge")])),
]
for window in ("g_apb_cdc", "v_apb_cdc"):
    BANKS.extend([
        Bank(f"{window}_addr", window, "addr_q", 12, "core_clk", "proc_clk", 10,
             reasons([(0, 1, "APB address word aligned")])),
        Bank(f"{window}_write", window, "write_q", 1, "core_clk", "proc_clk", 10, {}),
        Bank(f"{window}_wdata", window, "wdata_q", 32, "core_clk", "proc_clk", 10, {}),
        Bank(f"{window}_rdata", window, "remote_rdata_q", 32, "proc_clk", "core_clk", 18, {}),
        Bank(f"{window}_error", window, "remote_error_q", 1, "proc_clk", "core_clk", 18,
             {0: "APB endpoint PSLVERR tied low"}),
    ])

FF_RE = re.compile(r"EFX_FF\s+\\([^\s]+)\s+\((.*?)\)\s*/\*", re.S)
PIN_RE = re.compile(r"\.(D|CLK|Q)\((.*?)\)", re.S)
CONST_RE = re.compile(r"^1'b([01])$")


@dataclass(frozen=True)
class FF:
    name: str
    d: str
    clk: str
    q: str


def norm_net(net: str) -> str:
    # Efinity writes escaped vector nets as "\\foo [17]".
    s = net.strip().replace("\\", "")
    s = re.sub(r"\s+\[", "[", s)
    return s


def parse_ffs(text: str) -> dict[str, FF]:
    result: dict[str, FF] = {}
    for match in FF_RE.finditer(text):
        name, body = match.groups()
        pins = {k: v for k, v in PIN_RE.findall(body)}
        if set(pins) >= {"D", "CLK", "Q"}:
            result[name] = FF(name, norm_net(pins["D"]), norm_net(pins["CLK"]), norm_net(pins["Q"]))
    return result


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def source_cell(bank: Bank, bit: int) -> str:
    suffix = f"[{bit}]" if bank.width > 1 else ""
    return f"{bank.source_prefix}/{bank.source_signal}{suffix}~FF"


def tcl_re(name: str) -> str:
    return "^" + re.sub(r"([][(){}.+*?^$|\\])", r"\\\1", name) + "$"


MAX_RE = re.compile(
    r"set_max_delay\s+-from\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]\s+"
    r"-to\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]\s+([0-9.]+)", re.S)
HOLD_RE = re.compile(
    r"set_false_path\s+-hold\s+-from\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]\s+"
    r"-to\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]", re.S)


def sdc_coverage(sdc_path: Path, rows: list[dict[str, object]]) -> tuple[list[dict[str, object]], list[str]]:
    sdc = sdc_path.read_text(encoding="utf-8", errors="replace")
    max_rules = [(re.compile(src), re.compile(dst), float(ns)) for src, dst, ns in MAX_RE.findall(sdc)]
    hold_rules = [(re.compile(src), re.compile(dst)) for src, dst in HOLD_RE.findall(sdc)]
    failures: list[str] = []
    for row in rows:
        if row["classification"] not in ("dynamic", "static_capture"):
            continue
        src, dst, bound = str(row["source_ff"]), str(row["capture_ff"]), float(row["bound_ns"])
        matched_max = [rule for rule in max_rules if rule[0].fullmatch(src) and rule[1].fullmatch(dst)]
        matched_hold = [rule for rule in hold_rules if rule[0].fullmatch(src) and rule[1].fullmatch(dst)]
        okay = any(abs(ns - bound) < 0.001 for _, _, ns in matched_max) and bool(matched_hold)
        row["sdc_max_rules"] = len(matched_max)
        row["sdc_hold_rules"] = len(matched_hold)
        row["sdc_status"] = "pass" if okay else "fail"
        if not matched_max:
            failures.append(f"{row['bank']}[{row['bit']}] no SDC max_delay covers {src} -> {dst}")
        elif not any(abs(ns - bound) < 0.001 for _, _, ns in matched_max):
            failures.append(f"{row['bank']}[{row['bit']}] SDC max_delay bound differs from {bound}ns")
        if not matched_hold:
            failures.append(f"{row['bank']}[{row['bit']}] no matching hold false_path for bundled payload")
    return rows, failures


def generate(map_path: Path, out_dir: Path, sdc_path: Path) -> int:
    if not map_path.is_file():
        raise SystemExit(f"mapped netlist not found: {map_path}")
    out_dir.mkdir(parents=True, exist_ok=True)
    text = map_path.read_text(encoding="utf-8", errors="replace")
    ffs = parse_ffs(text)
    q_to_source = {ff.q: ff for ff in ffs.values()}
    map_hash = sha256(map_path)
    script_path = Path(__file__).resolve()
    script_hash = sha256(script_path)
    rows: list[dict[str, object]] = []
    failures: list[str] = []

    for bank in BANKS:
        bank_counts = {"dynamic": 0, "static": 0, "static_capture": 0}
        for bit in range(bank.width):
            src_name = source_cell(bank, bit)
            src = ffs.get(src_name)
            row: dict[str, object] = {
                "bank": bank.name, "bit": bit, "source_ff": src_name,
                "source_present": bool(src), "source_clock": bank.source_clock,
                "dest_clock": bank.dest_clock, "bound_ns": bank.bound_ns,
                "source_d": src.d if src else "", "source_q": src.q if src else "",
                "capture_ff": "", "capture_d": "", "classification": "unresolved",
                "reason": "", "sta_status": "not_run",
            }
            if src is None:
                # A missing source FF is accepted only for an explicitly known
                # constant field; all other absences need mapped evidence.
                if bit in bank.known_static:
                    row.update(classification="static", reason=bank.known_static[bit] + "; source FF optimized away")
                    bank_counts["static"] += 1
                else:
                    row["reason"] = "source FF absent with no approved static-field rationale"
                    failures.append(f"{bank.name}[{bit}] source FF absent")
                rows.append(row)
                continue

            const = CONST_RE.match(src.d)
            if const:
                if bit not in bank.known_static:
                    row["reason"] = f"source D is constant {const.group(1)} but bit has no approved static rationale"
                    failures.append(f"{bank.name}[{bit}] unapproved constant source D={const.group(1)}")
                else:
                    expected = re.search(r"fixed\s+([01])(?:\D|$)", bank.known_static[bit])
                    why = bank.known_static[bit]
                    if expected and expected.group(1) != const.group(1):
                        row["reason"] = f"mapped constant {const.group(1)} disagrees with rationale: {why}"
                        failures.append(f"{bank.name}[{bit}] static constant mismatch")
                    else:
                        # A constant D does not prove a constant Q during reset
                        # release. Retained source/capture flops still need a
                        # bounded physical path and per-bit STA signoff.
                        sinks = [ff for ff in ffs.values() if ff.clk == bank.dest_clock and ff.d == src.q]
                        if len(sinks) == 1:
                            sink = sinks[0]
                            row.update(classification="static_capture",
                                       reason=f"source D is tied {const.group(1)} but source/capture flops remain; {why}",
                                       capture_ff=sink.name, capture_d=sink.d)
                            bank_counts["static_capture"] += 1
                        elif len(sinks) == 0:
                            row.update(classification="static", reason=f"mapped source D={const.group(1)}; no capture FF remains; {why}")
                            bank_counts["static"] += 1
                        else:
                            row["reason"] = f"constant source Q has {len(sinks)} destination-clock FF D sinks; expected at most one"
                            failures.append(f"{bank.name}[{bit}] constant capture sink count {len(sinks)}")
                rows.append(row)
                continue

            sinks = [ff for ff in ffs.values() if ff.clk == bank.dest_clock and ff.d == src.q]
            if len(sinks) != 1:
                row["reason"] = f"dynamic source Q has {len(sinks)} destination-clock FF D sinks; expected exactly one"
                failures.append(f"{bank.name}[{bit}] capture sink count {len(sinks)}")
                rows.append(row)
                continue
            sink = sinks[0]
            row.update(classification="dynamic", reason="source Q directly drives mapped destination-clock capture D",
                       capture_ff=sink.name, capture_d=sink.d)
            bank_counts["dynamic"] += 1
            rows.append(row)
        print(f"BANK {bank.name}: dynamic={bank_counts['dynamic']} static_capture={bank_counts['static_capture']} static={bank_counts['static']} width={bank.width}")

    if not sdc_path.is_file():
        failures.append(f"SDC file not found: {sdc_path}")
    else:
        _, sdc_failures = sdc_coverage(sdc_path, rows)
        failures.extend(sdc_failures)

    csv_path = out_dir / "coverage.csv"
    fields = list(dict.fromkeys(k for row in rows for k in row))
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader(); writer.writerows(rows)

    tcl_path = out_dir / "verify_cdc_payloads.generated.tcl"
    sdc_hash = sha256(sdc_path) if sdc_path.is_file() else "missing"
    lines = [
        f'puts {{CDC_META map_sha256={map_hash} sdc_sha256={sdc_hash} python_sha256={script_hash}}}',
        'puts {CDC_COVERAGE_BEGIN}',
    ]
    required_rows = [r for r in rows if r["classification"] in ("dynamic", "static_capture")]
    for row in required_rows:
        lines.extend([
            f'puts {{CDC_PATH_BEGIN bank={row["bank"]} bit={row["bit"]} class={row["classification"]} bound_ns={row["bound_ns"]} sink={row["capture_ff"]}}}',
            f'set cdc_src [get_cells -regexp {{{tcl_re(str(row["source_ff"]))}}}]',
            f'set cdc_dst [get_cells -regexp {{{tcl_re(str(row["capture_ff"]))}}}]',
            'if {[llength $cdc_src] != 1 || [llength $cdc_dst] != 1} { error "CDC exact endpoint lookup failed" }',
            'report_timing -from $cdc_src -to $cdc_dst -npaths 1 -setup -stdout',
            f'puts {{CDC_PATH_END bank={row["bank"]} bit={row["bit"]}}}',
        ])
    lines.append('puts {CDC_COVERAGE_END}')
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    tcl_hash = sha256(tcl_path)
    meta = {"map_path": str(map_path.resolve()), "map_sha256": map_hash,
            "sdc_path": str(sdc_path.resolve()), "sdc_sha256": sha256(sdc_path) if sdc_path.is_file() else None,
            "python_script": str(script_path), "python_sha256": script_hash,
            "generated_tcl": str(tcl_path.resolve()), "generated_tcl_sha256": tcl_hash,
            "mapped_named_efx_ff_cells": len(ffs),
            "dynamic_bits": sum(r["classification"] == "dynamic" for r in rows),
            "static_capture_bits": sum(r["classification"] == "static_capture" for r in rows),
            "required_path_bits": len(required_rows),
            "coverage_rows": len(rows), "failures": failures}
    (out_dir / "coverage.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"MAP_SHA256 {map_hash}"); print(f"PYTHON_SHA256 {script_hash}")
    print(f"SDC_SHA256 {meta['sdc_sha256']}"); print(f"TCL_SHA256 {tcl_hash}")
    print(f"NAMED_EFX_FF_CELLS {len(ffs)}")
    print(f"DYNAMIC_PATHS {meta['dynamic_bits']}")
    print(f"STATIC_CAPTURE_PATHS {meta['static_capture_bits']}")
    print(f"REQUIRED_PATHS {meta['required_path_bits']}")
    print(f"COVERAGE_CSV {csv_path}"); print(f"GENERATED_TCL {tcl_path}")
    if failures:
        print("PRECHECK_FAIL " + "; ".join(failures[:30])); return 2
    print("PRECHECK_PASS")
    return 0


def validate(log_path: Path, out_dir: Path) -> int:
    rows = list(csv.DictReader((out_dir / "coverage.csv").open(encoding="utf-8", newline="")))
    log = log_path.read_text(encoding="utf-8", errors="replace")
    meta = json.loads((out_dir / "coverage.json").read_text(encoding="utf-8"))
    errors: list[str] = []
    seen: set[tuple[str, int]] = set()
    block_counts: dict[tuple[str, int], int] = {}
    meta_line = re.search(r"CDC_META\s+map_sha256=(\S+)\s+sdc_sha256=(\S+)\s+python_sha256=(\S+)", log)
    if not meta_line:
        errors.append("STA transcript missing tool/map/SDC hash marker")
    else:
        got_map, got_sdc, got_python = meta_line.groups()
        if got_map != meta.get("map_sha256"):
            errors.append("STA transcript map hash differs from generated coverage")
        if got_sdc != meta.get("sdc_sha256"):
            errors.append("STA transcript SDC hash differs from generated coverage")
        if got_python != meta.get("python_sha256"):
            errors.append("STA transcript verifier hash differs from generated coverage")
    block_re = re.compile(r"CDC_PATH_BEGIN bank=(\S+) bit=(\d+)(?: class=(\S+))? bound_ns=(\d+) sink=(\S+)\s*(.*?)CDC_PATH_END bank=\1 bit=\2", re.S)
    for m in block_re.finditer(log):
        bank, bit_s, cls_marker, bound_s, sink, body = m.groups()
        bit, bound = int(bit_s), int(bound_s); key = (bank, bit); seen.add(key)
        block_counts[key] = block_counts.get(key, 0) + 1
        row = next((r for r in rows if r["bank"] == bank and int(r["bit"]) == bit), None)
        if row is None or row["classification"] not in ("dynamic", "static_capture"):
            errors.append(f"unexpected STA block {bank}[{bit}]"); continue
        if cls_marker and cls_marker != row["classification"]:
            errors.append(f"{bank}[{bit}] class marker mismatch")
        if sink != row["capture_ff"]:
            errors.append(f"{bank}[{bit}] sink marker mismatch")
        if bound != int(row["bound_ns"]):
            errors.append(f"{bank}[{bit}] marker bound differs from generated payload contract")
        if "No timing path is found" in body:
            errors.append(f"{bank}[{bit}] no setup path"); continue
        ex = re.search(r"Timing Exception\s*:\s*Max Delay Path\s+([0-9.]+)\s+ns", body)
        if not ex or abs(float(ex.group(1)) - bound) > 0.001:
            errors.append(f"{bank}[{bit}] missing {bound}ns max-delay exception (or overridden by false path)")
        slack = re.search(r"Slack\s*:\s*([-+0-9.]+)\s+ns", body)
        if not slack or float(slack.group(1)) <= 0:
            errors.append(f"{bank}[{bit}] setup slack is absent or non-positive")
        end = re.search(r"Path End\s*:\s*(\S+)", body)
        if not end or end.group(1) != sink + "|D":
            errors.append(f"{bank}[{bit}] path endpoint differs from mapped capture D")
        row["sta_status"] = "pass" if not any(f"{bank}[{bit}]" in e for e in errors) else "fail"
    for row in rows:
        if row["classification"] in ("dynamic", "static_capture") and (row["bank"], int(row["bit"])) not in seen:
            errors.append(f"{row['bank']}[{row['bit']}] no STA block")
            row["sta_status"] = "missing"
    for key, count in block_counts.items():
        if count != 1:
            errors.append(f"{key[0]}[{key[1]}] appears in {count} STA blocks; expected exactly one")
    with (out_dir / "coverage.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    coverage_csv = out_dir / "coverage.csv"
    coverage_json = out_dir / "coverage.json"
    class_counts: dict[str, int] = {}
    static_by_bank: dict[str, int] = {}
    for row in rows:
        cls = str(row["classification"])
        class_counts[cls] = class_counts.get(cls, 0) + 1
        if cls == "static":
            name = str(row["bank"])
            static_by_bank[name] = static_by_bank.get(name, 0) + 1
        if cls == "static_capture":
            if row.get("sta_status") != "pass":
                errors.append(f"Static retained payload bit {row['bank']}[{row['bit']}] lacks per-bit STA PASS")
    if class_counts.get("unresolved", 0) or class_counts.get("mismatch", 0):
        errors.append("coverage table contains unresolved/mismatched mapped payload bits")
    dynamic_blocks = sum(r["classification"] == "dynamic" and (r["bank"], int(r["bit"])) in seen for r in rows)
    static_capture_blocks = sum(r["classification"] == "static_capture" and (r["bank"], int(r["bit"])) in seen for r in rows)
    required_path_bits = sum(r["classification"] in ("dynamic", "static_capture") for r in rows)
    report = {**meta, "sta_log": str(log_path.resolve()), "sta_log_sha256": sha256(log_path),
              "dynamic_sta_blocks": dynamic_blocks, "static_capture_sta_blocks": static_capture_blocks,
              "required_path_sta_blocks": len(seen), "required_path_bits": required_path_bits,
              "static_bits": sum(r["classification"] == "static" for r in rows),
              "classification_counts": class_counts, "static_bits_by_bank": static_by_bank,
              "coverage_csv": str(coverage_csv.resolve()), "coverage_csv_sha256": sha256(coverage_csv),
              "coverage_json": str(coverage_json.resolve()), "coverage_json_sha256": sha256(coverage_json),
              "errors": errors, "status": "PASS" if not errors and not meta["failures"] else "FAIL"}
    path = out_dir / "signoff_report.json"; path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"STA_LOG_SHA256 {report['sta_log_sha256']}")
    print(f"VALIDATED_REQUIRED_PATHS {report['required_path_sta_blocks']}/{report['required_path_bits']}")
    print(f"DYNAMIC_PATHS {report['dynamic_sta_blocks']}; STATIC_CAPTURE_PATHS {report['static_capture_sta_blocks']}")
    print(f"STATIC_BITS {report['static_bits']}"); print(f"SIGNOFF_REPORT {path}")
    if report["status"] != "PASS":
        print("SIGNOFF_FAIL")
        for e in errors[:50]: print("ERROR " + e)
        if meta["failures"]: print("PRECHECK_FAILURES " + "; ".join(meta["failures"][:20]))
        return 2
    print("CDC_PAYLOAD_SIGNOFF_PASS"); return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate"); g.add_argument("--map", required=True, type=Path); g.add_argument("--out", required=True, type=Path)
    g.add_argument("--sdc", type=Path, default=Path(__file__).resolve().parents[1] / "ti60f225_oob.sdc")
    v = sub.add_parser("validate"); v.add_argument("--log", required=True, type=Path); v.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    return generate(args.map, args.out, args.sdc) if args.cmd == "generate" else validate(args.log, args.out)


if __name__ == "__main__":
    sys.exit(main())
