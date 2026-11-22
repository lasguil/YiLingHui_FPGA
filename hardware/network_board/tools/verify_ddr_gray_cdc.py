#!/usr/bin/env python3
"""Map-aware STA signoff for the four DDR AXI FIFO Gray-pointer CDCs.

The checker proves that each registered Gray source bit is connected directly
to the first EFX_SRL8 synchronizer D pin, verifies the matching max-delay and
hold-only SDC rules, then validates one exact setup report per mapped bit.
It does not start Efinity or modify RTL/SDC.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from pathlib import Path


GROUPS = (
    ("command_rgray", "u_command_write_fifo", "r", "xrd2wr", "core_clk", "proc_clk", 9.0),
    ("command_wgray", "u_command_write_fifo", "w", "wr2rd", "proc_clk", "core_clk", 5.0),
    ("return_rgray", "u_return_fifo", "r", "xrd2wr", "proc_clk", "core_clk", 5.0),
    ("return_wgray", "u_return_fifo", "w", "wr2rd", "core_clk", "proc_clk", 9.0),
)

FF_RE = re.compile(r"EFX_FF\s+\\([^\s]+)\s+\((.*?)\)\s*/\*", re.S)
SRL_RE = re.compile(r"EFX_SRL8\s+\\([^\s]+)\s+\((.*?)\)\s*/\*", re.S)
PIN_RE = re.compile(r"\.(D|CLK|Q)\((.*?)\)", re.S)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def norm(net: str) -> str:
    return re.sub(r"\s+\[", "[", net.strip().replace("\\", ""))


def full_name(cell: str) -> str:
    return cell.replace("\\", "")


def regex_escape(value: str) -> str:
    return "^" + re.sub(r"([][(){}.+*?^$|\\])", r"\\\1", value) + "$"


def parse_map(text: str) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, str]]]:
    ffs: dict[str, dict[str, str]] = {}
    for m in FF_RE.finditer(text):
        pins = dict(PIN_RE.findall(m.group(2)))
        if set(pins) >= {"D", "CLK", "Q"}:
            ffs[full_name(m.group(1))] = {k: norm(pins[k]) for k in ("D", "CLK", "Q")}
    srls: dict[str, dict[str, str]] = {}
    for m in SRL_RE.finditer(text):
        pins = dict(PIN_RE.findall(m.group(2)))
        if set(pins) >= {"D", "CLK", "Q"}:
            srls[full_name(m.group(1))] = {k: norm(pins[k]) for k in ("D", "CLK", "Q")}
    return ffs, srls


MAX_RE = re.compile(
    r"set_max_delay\s+-from\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]\s+"
    r"-to\s+\[get_pins\s+-regexp\s+\{(.*?)\}\]\s+([0-9.]+)", re.S)
HOLD_RE = re.compile(
    r"set_false_path\s+-hold\s+-from\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]\s+"
    r"-to\s+\[get_pins\s+-regexp\s+\{(.*?)\}\]", re.S)
BROAD_FALSE_RE = re.compile(
    r"set_false_path\s+-from\s+\[get_cells\s+-regexp\s+\{(.*?)\}\]\s+"
    r"-to\s+\[get_pins\s+-regexp\s+\{(.*?)\}\]", re.S)


def build_rows(map_text: str) -> tuple[list[dict[str, object]], list[str]]:
    ffs, srls = parse_map(map_text)
    rows: list[dict[str, object]] = []
    errors: list[str] = []
    for group, fifo, direction, sync, source_clk, capture_clk, bound in GROUPS:
        base = f"u_ddr3_top/lb2_axi_clk.u_lb2_axi_clk/{fifo}/u_efx_fifo_top/xefx_fifo_ctl/genblk7."
        source_prefix = base + f"{direction}addr_cntr_gry_r"
        gray_prefix = base + f"{direction}addr_cntr_gry"
        sink_prefix = base + f"{sync}_addr_sync/dff_5/"
        src_bits = [f"{source_prefix}[{bit}]~FF" for bit in range(9)]
        src_q_nets: set[str] = set()
        sinks: dict[str, str] = {}
        for bit, cell in enumerate(src_bits):
            ff = ffs.get(cell)
            if ff is None:
                errors.append(f"{group}[{bit}] source FF missing: {cell}")
                continue
            # Gray MSB equals the binary counter MSB. Efinity may legally
            # collapse that net and drive the registered MSB from the counter.
            counter_base = base.rsplit("genblk7.", 1)[0]
            expected_d = (f"{counter_base}{'raddr_cntr_w' if direction == 'r' else 'waddr_cntr'}[8]"
                          if bit == 8 else f"{gray_prefix}[{bit}]")
            if ff["CLK"] != source_clk:
                errors.append(f"{group}[{bit}] source clock {ff['CLK']} != {source_clk}")
            if ff["D"] != expected_d:
                errors.append(f"{group}[{bit}] source D {ff['D']} is not registered Gray net {expected_d}")
            src_q_nets.add(ff["Q"])
            matches = [(name, pins) for name, pins in srls.items()
                       if name.startswith(sink_prefix) and pins["D"] == ff["Q"]]
            if len(matches) != 1:
                errors.append(f"{group}[{bit}] source Q has {len(matches)} first-stage SRL8.D matches")
                continue
            sink_cell, sink_pins = matches[0]
            if sink_pins["CLK"] != capture_clk:
                errors.append(f"{group}[{bit}] first-stage clock {sink_pins['CLK']} != {capture_clk}")
            sinks[cell] = sink_cell
            rows.append({
                "group": group, "bit": bit, "source_clock": source_clk,
                "capture_clock": capture_clk, "bound_ns": bound,
                "source_ff": cell, "source_q": ff["Q"],
                "sink_cell": sink_cell, "sink_d_net": sink_pins["D"],
                "source_pin": cell + "|Q", "sink_pin": sink_cell + "|D",
                "sta_status": "not_run",
            })
        sink_group = {name: pins for name, pins in srls.items() if name.startswith(sink_prefix)}
        if len(src_q_nets) != 9 or len(sink_group) != 9 or len(sinks) != 9:
            errors.append(f"{group} mapped widths sourceQ={len(src_q_nets)} firstSRL={len(sink_group)} paired={len(sinks)}; expected 9 each")
    return rows, errors


def check_sdc(rows: list[dict[str, object]], sdc_text: str) -> list[str]:
    errors: list[str] = []
    # Accept direct get_* objects or named Tcl object variables.
    variables: dict[str, tuple[str, str]] = {}
    for m in re.finditer(r"set\s+(\w+)\s+\[(get_cells|get_pins)\s+-regexp\s+\{(.*?)\}\]", sdc_text, re.S):
        variables[m.group(1)] = (m.group(2), m.group(3))

    def operand(expr: str, expected: str) -> re.Pattern[str] | None:
        expr = expr.strip()
        m = re.fullmatch(r"\[(get_cells|get_pins)\s+-regexp\s+\{(.*?)\}\]", expr, re.S)
        if m and m.group(1) == expected:
            return re.compile(m.group(2))
        m = re.fullmatch(r"\$(\w+)", expr)
        if m and m.group(1) in variables and variables[m.group(1)][0] == expected:
            return re.compile(variables[m.group(1)][1])
        return None

    max_rules: list[tuple[re.Pattern[str], re.Pattern[str], float]] = []
    hold_rules: list[tuple[re.Pattern[str], re.Pattern[str]]] = []
    broad_rules: list[tuple[re.Pattern[str], re.Pattern[str]]] = []
    for raw_line in sdc_text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        m = re.fullmatch(r"set_max_delay\s+-from\s+(.+?)\s+-to\s+(.+?)\s+([0-9.]+)", line)
        if m:
            src, dst = operand(m.group(1), "get_cells"), operand(m.group(2), "get_pins")
            if src and dst:
                max_rules.append((src, dst, float(m.group(3))))
        m = re.fullmatch(r"set_false_path\s+-hold\s+-from\s+(.+?)\s+-to\s+(.+)", line)
        if m:
            src, dst = operand(m.group(1), "get_cells"), operand(m.group(2), "get_pins")
            if src and dst:
                hold_rules.append((src, dst))
        m = re.fullmatch(r"set_false_path\s+-from\s+(.+?)\s+-to\s+(.+)", line)
        if m:
            src, dst = operand(m.group(1), "get_cells"), operand(m.group(2), "get_pins")
            if src and dst:
                broad_rules.append((src, dst))
    for row in rows:
        src = str(row["source_ff"])
        dst_pin = str(row["sink_pin"])
        dst_cell = str(row["sink_cell"])
        max_match = [r for r in max_rules if r[0].fullmatch(src) and r[1].fullmatch(dst_pin)]
        hold_match = [r for r in hold_rules if r[0].fullmatch(src) and r[1].fullmatch(dst_pin)]
        broad_match = [r for r in broad_rules if r[0].fullmatch(src) and (r[1].fullmatch(dst_pin) or r[1].fullmatch(dst_cell))]
        # A setup false path from the source to the destination cell or pin
        # invalidates the requested bounded setup check.
        if any(r[0].fullmatch(src) and (r[1].fullmatch(dst_pin) or r[1].fullmatch(dst_cell)) for r in broad_rules):
            errors.append(f"{row['group']}[{row['bit']}] unbounded setup false_path still covers {src} -> {dst_pin}")
        if not any(abs(ns - float(row["bound_ns"])) < 0.001 for _, _, ns in max_match):
            errors.append(f"{row['group']}[{row['bit']}] missing exact {row['bound_ns']}ns max_delay on {src} -> {dst_pin}")
        if not hold_match:
            errors.append(f"{row['group']}[{row['bit']}] missing hold-only false_path on {src} -> {dst_pin}")
        row["sdc_max_rules"] = len(max_match)
        row["sdc_hold_rules"] = len(hold_match)
        row["sdc_status"] = "pass" if not broad_match and any(abs(ns - float(row["bound_ns"])) < 0.001 for _, _, ns in max_match) and bool(hold_match) else "fail"
    return errors


def generate(map_path: Path, sdc_path: Path, out_dir: Path) -> int:
    if not map_path.is_file() or not sdc_path.is_file():
        raise SystemExit("map and SDC must both exist")
    out_dir.mkdir(parents=True, exist_ok=True)
    rows, errors = build_rows(map_path.read_text(encoding="utf-8", errors="replace"))
    sdc_text = sdc_path.read_text(encoding="utf-8", errors="replace")
    errors.extend(check_sdc(rows, sdc_text))
    checker_path = Path(__file__).resolve()
    meta = {
        "map_path": str(map_path.resolve()), "map_sha256": sha(map_path),
        "sdc_path": str(sdc_path.resolve()), "sdc_sha256": sha(sdc_path),
        "checker_path": str(checker_path), "checker_sha256": sha(checker_path),
        "dynamic_bits": len(rows), "expected_bits": 36,
        "groups": {g[0]: {"width": 9, "source_clock": g[4], "capture_clock": g[5], "bound_ns": g[6]} for g in GROUPS},
        "errors": errors,
    }
    csv_path = out_dir / "gray_coverage.csv"
    fields = ["group", "bit", "source_clock", "capture_clock", "bound_ns", "source_ff", "source_q", "sink_cell", "sink_d_net", "source_pin", "sink_pin", "sdc_max_rules", "sdc_hold_rules", "sdc_status", "sta_status"]
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields); writer.writeheader(); writer.writerows(rows)
    tcl_path = out_dir / "verify_ddr_gray_cdc.generated.tcl"
    lines = [f'puts {{GRAY_META map_sha256={meta["map_sha256"]} sdc_sha256={meta["sdc_sha256"]} checker_sha256={meta["checker_sha256"]}}}', 'puts {GRAY_COVERAGE_BEGIN}']
    for row in rows:
        lines.extend([
            f'puts {{GRAY_PATH_BEGIN group={row["group"]} bit={row["bit"]} bound_ns={row["bound_ns"]:.3f} launch={row["source_clock"]} capture={row["capture_clock"]} src={row["source_pin"]} dst={row["sink_pin"]}}}',
            f'set gray_src [get_pins -regexp {{{regex_escape(str(row["source_pin"]))}}}]',
            f'set gray_dst [get_pins -regexp {{{regex_escape(str(row["sink_pin"]))}}}]',
            'if {[llength $gray_src] != 1 || [llength $gray_dst] != 1} { error "DDR Gray exact Q/D pin lookup failed" }',
            'report_timing -from $gray_src -to $gray_dst -npaths 1 -setup -stdout',
            f'puts {{GRAY_PATH_END group={row["group"]} bit={row["bit"]}}}',
        ])
    lines.append('puts {GRAY_COVERAGE_END}')
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    meta.update(generated_tcl=str(tcl_path.resolve()), generated_tcl_sha256=sha(tcl_path),
                coverage_csv=str(csv_path.resolve()), coverage_csv_sha256=sha(csv_path))
    meta_path = out_dir / "gray_coverage.json"
    meta["coverage_json"] = str(meta_path.resolve())
    (out_dir / "gray_coverage.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    # A JSON file cannot truthfully contain its own final SHA256. The separate
    # STA report records and verifies this metadata file's hash.
    print(f"MAP_SHA256 {meta['map_sha256']}"); print(f"SDC_SHA256 {meta['sdc_sha256']}")
    print(f"CHECKER_SHA256 {meta['checker_sha256']}"); print(f"TCL_SHA256 {meta['generated_tcl_sha256']}")
    print(f"MAPPED_GRAY_PATHS {len(rows)}"); print(f"COVERAGE_CSV {csv_path}"); print(f"GENERATED_TCL {tcl_path}")
    if len(rows) != 36 and not any("expected 9 each" in e for e in errors):
        errors.append(f"mapped Gray paths={len(rows)}, expected exactly 36")
    if errors:
        print("GRAY_PRECHECK_FAIL")
        for error in errors: print("ERROR " + error)
        return 2
    print("GRAY_PRECHECK_PASS")
    return 0


def validate(log_path: Path, out_dir: Path) -> int:
    meta_path = out_dir / "gray_coverage.json"
    csv_path = out_dir / "gray_coverage.csv"
    tcl_path = out_dir / "verify_ddr_gray_cdc.generated.tcl"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8", newline="")))
    log = log_path.read_text(encoding="utf-8", errors="replace")
    errors: list[str] = []
    if meta.get("errors"):
        errors.extend(meta["errors"])
    if meta.get("map_sha256") != sha(Path(meta["map_path"])):
        errors.append("map hash changed after generate")
    if meta.get("sdc_sha256") != sha(Path(meta["sdc_path"])):
        errors.append("SDC hash changed after generate")
    if meta.get("checker_sha256") != sha(Path(meta["checker_path"])):
        errors.append("checker hash changed after generate")
    if meta.get("generated_tcl_sha256") != sha(tcl_path):
        errors.append("generated Tcl hash changed after generate")
    meta_line = re.search(r"GRAY_META\s+map_sha256=(\S+)\s+sdc_sha256=(\S+)\s+checker_sha256=(\S+)", log)
    if not meta_line:
        errors.append("STA transcript missing Gray map/SDC/checker hash marker")
    elif meta_line.groups() != (meta["map_sha256"], meta["sdc_sha256"], meta["checker_sha256"]):
        errors.append("STA transcript Gray provenance hashes differ from generated coverage")
    block_re = re.compile(r"GRAY_PATH_BEGIN group=(\S+) bit=(\d+) bound_ns=([0-9.]+) launch=(\S+) capture=(\S+) src=(\S+) dst=(\S+)\s*(.*?)GRAY_PATH_END group=\1 bit=\2", re.S)
    indexed = {(r["group"], int(r["bit"])): r for r in rows}
    seen: dict[tuple[str, int], int] = {}
    for m in block_re.finditer(log):
        group, bit_s, bound_s, launch, capture, src, dst, body = m.groups()
        bit = int(bit_s); key = (group, bit); seen[key] = seen.get(key, 0) + 1
        row = indexed.get(key)
        if row is None:
            errors.append(f"unexpected STA block {group}[{bit}]"); continue
        if (src != row["source_pin"] or dst != row["sink_pin"] or launch != row["source_clock"] or capture != row["capture_clock"]
                or abs(float(bound_s) - float(row["bound_ns"])) > 0.001):
            errors.append(f"{group}[{bit}] block endpoint/clock/bound marker mismatch")
        if "No timing path is found" in body:
            errors.append(f"{group}[{bit}] no setup path"); continue
        exc = re.search(r"Timing Exception\s*:\s*Max Delay Path\s+([0-9.]+)\s+ns", body)
        if not exc or abs(float(exc.group(1)) - float(row["bound_ns"])) > 0.001:
            errors.append(f"{group}[{bit}] missing intended max-delay exception")
        slack = re.search(r"Slack\s*:\s*([-+0-9.]+)\s+ns", body)
        if not slack or float(slack.group(1)) <= 0:
            errors.append(f"{group}[{bit}] setup slack absent/non-positive")
        end = re.search(r"Path End\s*:\s*(\S+)", body)
        data_path = re.search(r"(?m)^Data Path\s*$\s*(.*?)^Capture Clock Path\s*$", body, re.S)
        if not data_path or re.search(re.escape(src), data_path.group(1)) is None:
            errors.append(f"{group}[{bit}] exact mapped Gray source Q is absent from STA data path")
        if not end or end.group(1) != dst:
            errors.append(f"{group}[{bit}] STA actual endpoint differs from mapped Gray D")
        launch_report = re.search(r"Launch Clock\s*:\s*(\S+)", body)
        capture_report = re.search(r"Capture Clock\s*:\s*(\S+)", body)
        if (not launch_report or launch_report.group(1) != launch
                or not capture_report or capture_report.group(1) != capture):
            errors.append(f"{group}[{bit}] STA launch/capture clock differs from mapped CDC direction")
        row["sta_status"] = "pass" if not any(f"{group}[{bit}]" in e for e in errors) else "fail"
    for key, row in indexed.items():
        if seen.get(key, 0) != 1:
            errors.append(f"{key[0]}[{key[1]}] has {seen.get(key, 0)} STA blocks; expected exactly one")
            row["sta_status"] = "missing" if not seen.get(key, 0) else "duplicate"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    errors.extend([] if len(rows) == 36 else [f"coverage has {len(rows)} bits; expected 36"])
    report = {**meta, "sta_log": str(log_path.resolve()), "sta_log_sha256": sha(log_path),
              "coverage_csv_sha256": sha(csv_path), "coverage_json_sha256": sha(meta_path),
              "validated_sta_bits": len([r for r in rows if r.get("sta_status") == "pass"]),
              "errors": errors, "status": "PASS" if not errors else "FAIL"}
    report_path = out_dir / "gray_signoff_report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"STA_LOG_SHA256 {report['sta_log_sha256']}")
    print(f"VALIDATED_GRAY_BITS {report['validated_sta_bits']}/36")
    print(f"GRAY_SIGNOFF_REPORT {report_path}")
    print("DDR_GRAY_CDC_SIGNOFF_" + report["status"])
    for error in errors: print("ERROR " + error)
    return 0 if report["status"] == "PASS" else 2


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--map", required=True, type=Path)
    gen.add_argument("--sdc", required=True, type=Path)
    gen.add_argument("--out", required=True, type=Path)
    val = sub.add_parser("validate")
    val.add_argument("--log", required=True, type=Path)
    val.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    return generate(args.map, args.sdc, args.out) if args.cmd == "generate" else validate(args.log, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
