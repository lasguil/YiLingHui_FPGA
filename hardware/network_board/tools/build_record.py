"""Freeze board-build inputs and accept a bit only after setup/hold checks."""
from pathlib import Path
import hashlib
import json
import re
import sys
import csv
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build'
OUT.mkdir(exist_ok=True)
PENDING = OUT / 'build_inputs.json'
ACCEPT = ROOT / 'build_accept.json'
CDC_OUT = OUT / 'cdc_payload_signoff'
CDC_REPORT = CDC_OUT / 'signoff_report.json'
GRAY_REPORT = CDC_OUT / 'gray_signoff_report.json'
CDC_LOG = CDC_OUT / 'sta.log'
SIGNOFF_TIMING = CDC_OUT / 'signoff_timing_summary.rpt'
CDC_CHECKER = ROOT / 'tools/verify_cdc_payloads.py'
GRAY_CHECKER = ROOT / 'tools/verify_ddr_gray_cdc.py'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def reject_invalid_sdc(log_text, source):
    fatal_patterns = (
        r'Error\(s\) found while executing SDC file',
        r'\binvalid command name\b',
        r'\bwrong # args\b',
        r'\bcan.t read .*\bno such variable\b',
        r'\bTcl error\b',
    )
    fatal = [line.strip() for line in log_text.splitlines()
             if any(re.search(pattern, line, flags=re.I) for pattern in fatal_patterns)]
    if fatal:
        raise SystemExit(f'{source} contains SDC/Tcl execution errors: ' + ' | '.join(fatal[:8]))
    bad = []
    for line in log_text.splitlines():
        if not re.search(
            r'WARNING.*(?:\.sdc:\d+|No cells matched|Object\(s\).*no vaild endpoints|Unable to run .*constraint)',
            line, flags=re.I):
            continue
        # efx_sta auto-creates 1 ns clocks before the Tcl wrapper can read the
        # routed project's SDC. Its exact same-name overwrite notice is expected;
        # every other SDC warning (including zero-match constraints) rejects.
        if re.search(r'WARNING.*\.sdc:\d+.*A clock with name .+ already exists\. Overwriting the previous clock with the same name',
                     line, flags=re.I):
            continue
        bad.append(line.strip())
    if bad:
        raise SystemExit(f'{source} contains rejected SDC/constraint warnings: ' + ' | '.join(bad[:8]))

def inputs():
    import os
    import xml.etree.ElementTree as ET
    project = ET.parse(ROOT / 'ti60f225_oob.xml').getroot()
    ns = {'efx': 'http://www.efinixinc.com/enf_proj'}
    files = {ROOT / p for p in [
        'ti60f225_oob.xml', 'ti60f225_oob.peri.xml', 'ti60f225_oob.sdc',
        'sources.f', 'package_settings.xml', 'compile.bat',
        'tools/build_record.py', 'tools/generate_sources_f.py',
        'tools/verify_cdc_payloads.py', 'tools/verify_ddr_gray_cdc.py',
        'tools/verify_cdc_payloads.tcl', 'tools/run_payload_sta.bat',
        'software/build_gesture_firmware.bat',
    ]}
    files |= {ROOT / node.get('name') for node in project.findall('.//efx:design_file', ns)}
    files |= set(ROOT.glob('EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol*.bin'))
    files |= set(ROOT.glob('*.hex')) | set(ROOT.glob('*.inithex'))
    fw_root = ROOT / 'software/gesture_firmware'
    files |= {p for p in fw_root.rglob('*') if p.is_file() and not (
        p.parent.name == 'build' and p.name.startswith('test_') and p.suffix.lower() == '.exe'
    )}
    # Hash recursively referenced Verilog includes as first-class build inputs.
    include_re = re.compile(r'^\s*`include\s+[\"<]([^\">]+)[\">]', re.M)
    pending = list(files)
    while pending:
        source = pending.pop()
        if not source.is_file() or source.suffix.lower() not in {'.v', '.sv', '.vh', '.vhd'}:
            continue
        content = source.read_text(encoding='utf-8', errors='replace')
        for inc in include_re.findall(content):
            candidates = [source.parent / inc, ROOT / inc, ROOT / 'rtl' / inc, ROOT / 'rtl/soc' / inc]
            found = next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)
            if found is None:
                raise SystemExit(f'Unresolved source include in {source.relative_to(ROOT)}: {inc}')
            if found not in files:
                files.add(found)
                pending.append(found)
    return {Path(os.path.relpath(p, ROOT)).as_posix(): sha(p) for p in sorted(files) if p.is_file()}

def begin():
    # Efinity serializes the project XML again at the end of a flow. Keep the
    # exact input too, so formatting changes can be audited without guessing.
    (OUT / 'build_project_input.xml').write_bytes((ROOT / 'ti60f225_oob.xml').read_bytes())
    # Never let a report from an earlier run authorize this build.
    CDC_REPORT.unlink(missing_ok=True)
    GRAY_REPORT.unlink(missing_ok=True)
    SIGNOFF_TIMING.unlink(missing_ok=True)
    PENDING.write_text(json.dumps({'started': datetime.now().isoformat(), 'inputs': inputs()}, indent=2), encoding='utf-8')

def payload_signoff(start):
    if not CDC_REPORT.is_file() or not CDC_LOG.is_file():
        raise SystemExit('Per-bit bundled CDC payload signoff is missing; bit not accepted')
    report = json.loads(CDC_REPORT.read_text(encoding='utf-8'))
    if report.get('status') != 'PASS' or report.get('errors') or report.get('failures'):
        raise SystemExit('Per-bit bundled CDC payload signoff did not PASS; bit not accepted')
    reject_invalid_sdc(CDC_LOG.read_text(encoding='utf-8', errors='replace'), 'Payload CDC STA')
    if report.get('dynamic_bits', 0) <= 0 or report.get('dynamic_sta_blocks') != report.get('dynamic_bits'):
        raise SystemExit('Payload signoff does not cover every mapped dynamic bit; bit not accepted')
    coverage_csv = Path(report.get('coverage_csv', ''))
    coverage_json = Path(report.get('coverage_json', ''))
    if (not coverage_csv.is_file() or report.get('coverage_csv_sha256') != sha(coverage_csv)
            or not coverage_json.is_file() or report.get('coverage_json_sha256') != sha(coverage_json)):
        raise SystemExit('Payload per-bit CSV/JSON evidence is missing or its hash changed')
    with coverage_csv.open(encoding='utf-8', newline='') as f:
        coverage_rows = list(csv.DictReader(f))
    coverage_meta = json.loads(coverage_json.read_text(encoding='utf-8'))
    if len(coverage_rows) != report.get('coverage_rows') or coverage_meta.get('coverage_rows') != len(coverage_rows):
        raise SystemExit('Payload coverage row count differs from its report')
    for key in ('map_sha256', 'sdc_sha256', 'python_sha256', 'dynamic_bits',
                'static_capture_bits', 'required_path_bits', 'coverage_rows', 'failures'):
        if coverage_meta.get(key) != report.get(key):
            raise SystemExit(f'Payload coverage JSON and signoff report disagree on {key}')
    if coverage_meta.get('failures'):
        raise SystemExit('Payload coverage JSON records unresolved map/SDC failures')
    counts = {}
    static_by_bank = {}
    for row in coverage_rows:
        cls = row.get('classification', '')
        counts[cls] = counts.get(cls, 0) + 1
        if cls == 'static':
            static_by_bank[row.get('bank', '')] = static_by_bank.get(row.get('bank', ''), 0) + 1
            if not row.get('reason', '').strip():
                raise SystemExit(f"Static payload bit {row.get('bank')}[{row.get('bit')}] has no rationale")
        elif cls in ('dynamic', 'static_capture'):
            if row.get('sta_status') != 'pass':
                raise SystemExit(f"Required payload path {row.get('bank')}[{row.get('bit')}] lacks per-bit STA PASS")
        else:
            raise SystemExit(f"Payload bit {row.get('bank')}[{row.get('bit')}] is {cls or 'unclassified'}")
    if (counts != report.get('classification_counts')
            or sum(counts.values()) != report.get('coverage_rows')
            or counts.get('dynamic', 0) != report.get('dynamic_bits')
            or counts.get('static_capture', 0) != report.get('static_capture_bits')
            or counts.get('dynamic', 0) + counts.get('static_capture', 0) != report.get('required_path_bits')
            or report.get('required_path_sta_blocks') != report.get('required_path_bits')
            or counts.get('static', 0) != report.get('static_bits')
            or static_by_bank != report.get('static_bits_by_bank')):
        raise SystemExit('Payload dynamic/static classification counts disagree with coverage evidence')
    if report.get('map_sha256') != sha(ROOT / 'outflow/ti60f225_oob.map.v'):
        raise SystemExit('Payload signoff map hash differs from the current mapped design')
    if report.get('sdc_sha256') != sha(ROOT / 'ti60f225_oob.sdc'):
        raise SystemExit('Payload signoff SDC hash differs from the current constraints')
    if report.get('python_sha256') != sha(CDC_CHECKER):
        raise SystemExit('Payload signoff checker hash differs from the current checker')
    tcl_path = Path(report.get('generated_tcl', ''))
    if not tcl_path.is_file() or report.get('generated_tcl_sha256') != sha(tcl_path):
        raise SystemExit('Payload signoff generated Tcl is missing or its hash changed')
    if report.get('sta_log_sha256') != sha(CDC_LOG):
        raise SystemExit('Payload signoff STA transcript hash differs from the recorded transcript')
    build_epoch = datetime.fromisoformat(start.get('signoff_started', start['started'])).timestamp()
    if CDC_REPORT.stat().st_mtime < build_epoch or CDC_LOG.stat().st_mtime < build_epoch:
        raise SystemExit('Payload signoff report predates this build')
    return {
        'status': report['status'],
        'report_path': str(CDC_REPORT.relative_to(ROOT)).replace('\\', '/'),
        'report_sha256': sha(CDC_REPORT),
        'sta_log_sha256': report['sta_log_sha256'],
        'map_sha256': report['map_sha256'],
        'sdc_sha256': report['sdc_sha256'],
        'checker_sha256': report['python_sha256'],
        'generated_tcl_sha256': report['generated_tcl_sha256'],
        'dynamic_bits': report['dynamic_bits'],
        'dynamic_sta_blocks': report['dynamic_sta_blocks'],
        'static_capture_bits': report['static_capture_bits'],
        'static_capture_sta_blocks': report['static_capture_sta_blocks'],
        'required_path_bits': report['required_path_bits'],
        'required_path_sta_blocks': report['required_path_sta_blocks'],
        'static_bits': report['static_bits'],
        'coverage_csv_sha256': report['coverage_csv_sha256'],
        'coverage_json_sha256': report['coverage_json_sha256'],
        'coverage_rows': report['coverage_rows'],
        'classification_counts': report['classification_counts'],
        'static_bits_by_bank': report['static_bits_by_bank'],
    }

def gray_signoff(start):
    if not GRAY_REPORT.is_file() or not CDC_LOG.is_file():
        raise SystemExit('Per-bit DDR Gray CDC signoff is missing; bit not accepted')
    report = json.loads(GRAY_REPORT.read_text(encoding='utf-8'))
    if report.get('status') != 'PASS' or report.get('errors'):
        raise SystemExit('DDR Gray CDC signoff did not PASS; bit not accepted')
    if report.get('validated_sta_bits') != 36 or report.get('dynamic_bits') != 36:
        raise SystemExit('DDR Gray CDC signoff does not cover all 36 mapped paths')
    csv_path = Path(report.get('coverage_csv', ''))
    json_path = Path(report.get('coverage_json', ''))
    tcl_path = Path(report.get('generated_tcl', ''))
    if (not csv_path.is_file() or report.get('coverage_csv_sha256') != sha(csv_path)
            or not json_path.is_file() or report.get('coverage_json_sha256') != sha(json_path)
            or not tcl_path.is_file() or report.get('generated_tcl_sha256') != sha(tcl_path)):
        raise SystemExit('DDR Gray per-bit coverage or generated Tcl is missing/changed')
    meta = json.loads(json_path.read_text(encoding='utf-8'))
    for key in ('map_sha256', 'sdc_sha256', 'checker_sha256', 'dynamic_bits', 'errors'):
        if meta.get(key) != report.get(key):
            raise SystemExit(f'DDR Gray coverage JSON and report disagree on {key}')
    if meta.get('errors'):
        raise SystemExit('DDR Gray coverage JSON records unresolved mappings')
    rows = list(csv.DictReader(csv_path.open(encoding='utf-8', newline='')))
    if len(rows) != 36 or any(r.get('sta_status') != 'pass' or r.get('sdc_status') != 'pass' for r in rows):
        raise SystemExit('DDR Gray coverage does not show 36 per-bit STA/SDC PASS rows')
    groups = {}
    for row in rows:
        groups[row['group']] = groups.get(row['group'], 0) + 1
    if len(groups) != 4 or any(n != 9 for n in groups.values()):
        raise SystemExit('DDR Gray coverage does not contain 9 bits in each of four FIFO directions')
    if report.get('map_sha256') != sha(ROOT / 'outflow/ti60f225_oob.map.v'):
        raise SystemExit('DDR Gray signoff map hash differs from current mapped design')
    if report.get('sdc_sha256') != sha(ROOT / 'ti60f225_oob.sdc'):
        raise SystemExit('DDR Gray signoff SDC hash differs from current constraints')
    if report.get('checker_sha256') != sha(GRAY_CHECKER):
        raise SystemExit('DDR Gray checker hash differs from signoff report')
    if report.get('sta_log_sha256') != sha(CDC_LOG):
        raise SystemExit('DDR Gray STA transcript hash differs from recorded log')
    build_epoch = datetime.fromisoformat(start.get('signoff_started', start['started'])).timestamp()
    if GRAY_REPORT.stat().st_mtime < build_epoch or CDC_LOG.stat().st_mtime < build_epoch:
        raise SystemExit('DDR Gray signoff predates this build')
    return {
        'status': report['status'],
        'report_path': str(GRAY_REPORT.relative_to(ROOT)).replace('\\', '/'),
        'report_sha256': sha(GRAY_REPORT),
        'sta_log_sha256': report['sta_log_sha256'],
        'map_sha256': report['map_sha256'],
        'sdc_sha256': report['sdc_sha256'],
        'checker_sha256': report['checker_sha256'],
        'generated_tcl_sha256': report['generated_tcl_sha256'],
        'coverage_csv_sha256': report['coverage_csv_sha256'],
        'coverage_json_sha256': report['coverage_json_sha256'],
        'validated_sta_bits': report['validated_sta_bits'],
        'groups': {name: count for name, count in sorted(groups.items())},
    }

def resta():
    """Re-sign the same routed hardware after audited SDC-only corrections."""
    start = json.loads(PENDING.read_text(encoding='utf-8'))
    current = inputs()
    # These files only generate/check the SDC-only signoff evidence. They do
    # not change the routed hardware. Every RTL, ROM, pin, PLL, model, and
    # firmware input remains outside this allowlist and must match exactly.
    signoff_only = {
        'ti60f225_oob.sdc', 'compile.bat', 'tools/build_record.py',
        'tools/verify_cdc_payloads.py', 'tools/verify_ddr_gray_cdc.py',
        'tools/verify_cdc_payloads.tcl', 'tools/run_payload_sta.bat',
    }
    old_hardware = {k:v for k,v in start['inputs'].items() if k not in signoff_only}
    new_hardware = {k:v for k,v in current.items() if k not in signoff_only}
    if old_hardware != new_hardware:
        raise SystemExit('Hardware/PLL inputs changed; a new compile is required')
    start.update(inputs=current, signoff_started=datetime.now().isoformat(),
                 constraints_only_signoff=True,
                 routed_bit_sha256=sha(ROOT/'outflow/ti60f225_oob.bit'),
                 routed_map_sha256=sha(ROOT/'outflow/ti60f225_oob.map.v'))
    PENDING.write_text(json.dumps(start, indent=2), encoding='utf-8')

def accept():
    start = json.loads(PENDING.read_text(encoding='utf-8'))
    project = ROOT / 'ti60f225_oob.xml'
    original = (OUT / 'build_project_input.xml').read_bytes()
    # Efinity rewrites the XML and can remove its final newline or normalize
    # line endings. Restore only when the entire content matches after that
    # known serialization change; any substantive edit still rejects the bit.
    current = project.read_bytes()
    normalized = lambda data: data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    frozen_normalized = normalized(original)
    current_normalized = normalized(current)
    if frozen_normalized.rstrip(b'\n') == current_normalized.rstrip(b'\n'):
        project.write_bytes(original)
        print('Audited Efinity XML line-ending rewrite; restored exact frozen project bytes')
    if inputs() != start['inputs']:
        raise SystemExit('Build inputs changed during compilation; bit not accepted')
    if start.get('constraints_only_signoff'):
        if start['routed_bit_sha256'] != sha(ROOT/'outflow/ti60f225_oob.bit') or start['routed_map_sha256'] != sha(ROOT/'outflow/ti60f225_oob.map.v'):
            raise SystemExit('Routed hardware changed during SDC-only signoff')
    timing = SIGNOFF_TIMING
    build_epoch = datetime.fromisoformat(start.get('signoff_started', start['started'])).timestamp()
    if timing.stat().st_mtime < build_epoch:
        raise SystemExit('Timing report predates this build; bit not accepted')
    if not start.get('constraints_only_signoff'):
        bit_path = ROOT / 'outflow/ti60f225_oob.bit'
        route_path = ROOT / 'outflow/ti60f225_oob.route.out'
        if not bit_path.exists() or bit_path.stat().st_mtime < build_epoch or route_path.stat().st_mtime < build_epoch:
            raise SystemExit('Bit/routing evidence predates this build; bit not accepted')
        overlaps = re.findall(r'Iter\s+\d+: overlap=(\d+)', route_path.read_text(encoding='utf-8', errors='replace'))
        if not overlaps or int(overlaps[-1]) != 0:
            raise SystemExit('Routing has not reached zero conflicts; bit not accepted')
    cdc_record = payload_signoff(start)
    gray_record = gray_signoff(start)
    text = timing.read_text(encoding='utf-8')
    summary = text.split('---------- 2. Clock Relationship Summary (begin) ----------')[1].split('---------- Clock Relationship Summary (end)')[0]
    rows = re.findall(r'^\S+\s+\S+\s+[-\d.]+\s+([-\d.]+)\s+\(R-[RF]\)', summary, flags=re.M)
    if not rows or min(map(float, rows)) < 0:
        raise SystemExit(f'Timing failed, minimum setup/hold slack={min(map(float, rows)) if rows else "missing"}; bit not accepted')
    if start.get('constraints_only_signoff'):
        log = CDC_LOG.read_text(encoding='utf-8', errors='replace')
        reject_invalid_sdc(log, 'Constraints-only signoff')
        if re.search(r'\bERROR\b', log, flags=re.I):
            raise SystemExit('New signoff constraints were rejected or STA reported errors')
    pnr_log = (ROOT / 'outflow/ti60f225_oob.log').read_text(encoding='utf-8', errors='replace')
    # Build's final outflow log may be the bit-generator log. Inspect the separate
    # PNR transcript when available; caller also retains normal compile logs.
    candidates = [ROOT / 'build_pnr.log', ROOT / 'build_compile.log']
    for p in candidates:
        if p.exists():
            pnr_log += p.read_text(encoding='utf-8', errors='replace')
    reject_invalid_sdc(pnr_log, 'Compile/PNR transcript')
    if re.search(r'\bERROR\b', pnr_log, flags=re.I):
        raise SystemExit('Compile/PNR transcript contains errors; bit not accepted')
    place = (ROOT / 'outflow/ti60f225_oob.place.rpt').read_text(encoding='utf-8')
    resources = {k: int(re.search(pattern, place).group(1)) for k, pattern in {
        'xlr': r'XLRs:\s+(\d+) /', 'ram10': r'Memory Blocks:\s+(\d+) /', 'dsp': r'DSP Blocks:\s+(\d+) /'}.items()}
    bit = ROOT / 'outflow/ti60f225_oob.bit'
    period = float(re.search(r'create_clock -period ([\d.]+) core_clk', (ROOT / 'ti60f225_oob.sdc').read_text(encoding='utf-8')).group(1))
    record = dict(start, accepted=datetime.now().isoformat(), resources=resources,
                  core_mhz=1000/period, min_slack_ns=min(map(float, rows)),
                  timing_sha256=sha(timing), bit_sha256=sha(bit),
                  cdc_payload_signoff=cdc_record, ddr_gray_cdc_signoff=gray_record)
    ACCEPT.write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(f'ACCEPT: core={record["core_mhz"]:.3f}MHz, min_slack={record["min_slack_ns"]:.3f}ns, {resources}')

def verify():
    record = json.loads(ACCEPT.read_text(encoding='utf-8'))
    if record['inputs'] != inputs() or record['bit_sha256'] != sha(ROOT/'outflow/ti60f225_oob.bit'):
        raise SystemExit('Inputs/bit differ from accepted build; JTAG stopped')
    cdc = record.get('cdc_payload_signoff')
    if not cdc or cdc.get('status') != 'PASS':
        raise SystemExit('Accepted build lacks required per-bit bundled CDC payload signoff; JTAG stopped')
    if payload_signoff(record) != cdc:
        raise SystemExit('Payload signoff provenance no longer matches accepted build; JTAG stopped')
    gray = record.get('ddr_gray_cdc_signoff')
    if not gray or gray.get('status') != 'PASS' or gray_signoff(record) != gray:
        raise SystemExit('DDR Gray CDC signoff provenance no longer matches accepted build; JTAG stopped')
    if record.get('timing_sha256') != sha(SIGNOFF_TIMING):
        raise SystemExit('Fresh routed timing summary no longer matches accepted build; JTAG stopped')
    print('PASS: current inputs and bit match accepted timing build')

if __name__ == '__main__':
    {'begin': begin, 'resta': resta, 'accept': accept, 'verify': verify}[sys.argv[1]]()
