"""Bind the integrated bitstream to portable source and validation hashes."""
from pathlib import Path
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
record_path = root / 'build/artifact_manifest.json'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inputs():
    ns = {'e': 'http://www.efinixinc.com/enf_proj'}
    project = ET.parse(root / 'ti60f225_oob.xml').getroot()
    names = {n.get('name') for n in project.findall('.//e:design_file', ns)}
    names.update(['ti60f225_oob.xml', 'ti60f225_oob.peri.xml', 'ti60f225_oob.sdc',
                  'sources.f', 'network_io.isf', 'build.sh', 'tools/integration_timing.tcl',
                  'tools/freeze_artifact.py',
                  'tools/check_integration_timing.py', 'tools/verify_cdc_payloads.tcl',
                  'tools/verify_cdc_payloads.py', 'tools/verify_ddr_gray_cdc.py',
                  'README.md', 'HARDWARE_VALIDATION.md', 'build/VALIDATION.md'])
    names.update(str(p.relative_to(root)) for folder in ['software/gesture_firmware/src',
                  'software/gesture_firmware/include', 'software/gesture_firmware/tools',
                  'software/gesture_firmware/tests', 'software/gesture_firmware/docs']
                  for p in (root / folder).glob('*')
                  if p.is_file() and p.suffix not in {'.bat', '.exe'})
    names.update(['rtl/video_profile.vh', 'tools/perf_accept.py', 'tools/start_perf_web.sh',
                  '../net_web/streamd.py', '../net_web/netproto.py', '../net_web/test_web_perf.py',
                  '../net_web/test_control_protocol.py', '../net_web/static/perf_probe.html',
                  '../net_web/static/index.html', '../net_web/static/app.js',
                  '../PERFORMANCE_UPGRADE_PLAN.md'])
    names.update(['software/gesture_firmware/software/link.ld',
                  'software/gesture_firmware/README.md'])
    names.update(str(p.relative_to(root)) for p in (root / 'sim').glob('*') if p.is_file())
    names.update(p.name for pattern in ['EfxSapphireSoc*.bin', '*.hex', '*.inithex'] for p in root.glob(pattern))
    names.update(str(p.relative_to(root)) for p in (root / 'software/gesture_firmware/model').glob('*') if p.is_file())
    # The EDID is loaded through a parameterized RAM, not an XML design_file.
    names.add('rtl/vendor_hdmi/source/hdmi_src/dvi_rx/EDID/edid_1080p.inithex')
    pending = list(names)
    while pending:
        name = pending.pop()
        source = root / name
        if source.suffix not in {'.v', '.sv', '.vh'}:
            continue
        for include in re.findall(r'^\s*`include\s+"([^"]+)"', source.read_text(errors='replace'), re.M):
            candidates = [source.parent / include, root / include, root / 'rtl' / include, root / 'rtl/soc' / include]
            resolved = next((p for p in candidates if p.is_file()), None)
            if resolved is None:
                raise SystemExit(f'Missing include {include} in {name}')
            relative = str(resolved.resolve().relative_to(root))
            if relative not in names:
                names.add(relative); pending.append(relative)
    return {name: sha(root / name) for name in sorted(names)}

if '--verify' in sys.argv:
    saved = json.loads(record_path.read_text())
    if saved['inputs'] != inputs() or any(sha(root / name) != value for name, value in saved['outputs'].items()):
        raise SystemExit('FAIL: sources/bit/evidence differ from frozen integration build')
    print('PASS: integrated sources, bitstream and verification evidence match')
else:
    # The caller must run the strict STA checker before freezing.
    import runpy
    runpy.run_path(str(root / 'tools/check_integration_timing.py'))
    reports = ['build/cdc_payload_signoff/signoff_report.json', 'build/cdc_payload_signoff/gray_signoff_report.json']
    for name in reports:
        evidence = json.loads((root / name).read_text())
        if (evidence['status'] != 'PASS' or evidence['map_sha256'] != sha(root / 'outflow/ti60f225_oob.map.v')
                or evidence['sdc_sha256'] != sha(root / 'ti60f225_oob.sdc')):
            raise SystemExit('FAIL: CPU/APB or DDR signoff is failed or stale')
    outputs = ['outflow/ti60f225_oob.bit', 'outflow/ti60f225_oob.map.v',
               'outflow/ti60f225_oob.place.rpt', 'outflow/ti60f225_oob.route.rpt',
               'build/final_timing.rpt', 'build/timing.log', *reports,
               'build/firmware_rom_integration.json',
               'software/gesture_firmware/build/linux/gesture_demo.elf',
               'software/gesture_firmware/build/linux/gesture_demo.bin',
               'software/gesture_firmware/build/linux/gesture_demo_size.txt',
               'software/gesture_firmware/build/linux/SHA256SUMS',
               'build/net_packet_run.log', 'build/net_status_run.log', 'build/pc_protocol_run.log',
               'build/tb_net_reader_run.log', 'build/tb_gesture_net_integration_run.log',
               'build/capture_recovery_run.log', 'build/host_firmware_regression.log',
               'build/cdc_payload_signoff/coverage.csv', 'build/cdc_payload_signoff/gray_coverage.csv']
    outputs.extend(['build/PERFORMANCE_UPGRADE_REPORT.md',
                    'build/pnr_seed6.log', 'build/timing_seed6.log', 'build/bitstream_seed6.log',
                    'build/network_regression_highres.log', 'build/board_linux_regression_highres.log',
                    'build/web_perf_640x36020_final.log'])
    candidate_hw = ['build/hardware/jtag_candidate_20261021.log',
                    'build/hardware/candidate_20261021_acceptance.jsonl',
                    'build/hardware/candidate_20261021_acceptance_summary.json',
                    'build/hardware/candidate_20261021_uart_query.json']
    outputs.extend(name for name in candidate_hw if (root / name).is_file())
    for pattern in ['build/tx_*_summary.json','build/tx_*_check.log','build/tx_*_run.log',
                    'build/reader_*_run.log','build/hardware/perf_*.json*','build/hardware/jtag_perf*.log',
                    'build/web_perf_summary.json','build/pc_control_regression.log',
                    'build/board_linux_regression.log','build/performance_regression.log',
                    'build/performance_modes_highres.log']:
        outputs.extend(str(p.relative_to(root)) for p in root.glob(pattern) if p.is_file())
    outputs = list(dict.fromkeys(outputs))
    hardware_tested = False
    status = 'engineering_build_passed_hardware_not_tested'
    acceptance = root / 'build/hardware/candidate_20261021_acceptance_summary.json'
    jtag = root / 'build/hardware/jtag_candidate_20261021.log'
    uart = root / 'build/hardware/candidate_20261021_uart_query.json'
    if acceptance.is_file() and jtag.is_file() and uart.is_file():
        hw = json.loads(acceptance.read_text())
        tx = json.loads(uart.read_text())
        programming_log = jtag.read_text(errors='replace').upper()
        bit_hash = sha(root / 'outflow/ti60f225_oob.bit')
        if (hw.get('pass') and hw.get('bitstream_sha256') == bit_hash
                and 'DEVICE ID READ FROM JTAG: 0X10660A79' in programming_log
                and 'FINISHED WITH JTAG PROGRAMMING' in programming_log
                and tx.get('bitstream_sha256') == bit_hash and tx.get('tx_count_delta', 0) >= 1
                and tx.get('after', {}).get('state') == 4):
            hardware_tested = True
            status = 'board_video_and_b_uart_smoke_passed_a_ack_unverified'
    perf = root / 'build/hardware/perf_20261021_acceptance_summary.json'
    perf_jtag = root / 'build/hardware/jtag_perf_20261021.log'
    if perf.is_file() and perf_jtag.is_file():
        hw = json.loads(perf.read_text())
        jl = perf_jtag.read_text(errors='replace').upper()
        if (hw.get('bitstream_sha256') == sha(root / 'outflow/ti60f225_oob.bit')
                and 'DEVICE ID READ FROM JTAG: 0X10660A79' in jl
                and 'FINISHED WITH JTAG PROGRAMMING' in jl):
            hardware_tested = True
            status = ('board_video_perf_passed_npu_and_optical_fps_unverified' if hw.get('pass')
                      else 'board_video_perf_measured_acceptance_limits_not_met')
    record = {'status': status, 'hardware_tested': hardware_tested,
              'inputs': inputs(), 'outputs': {name: sha(root / name) for name in outputs}}
    record_path.write_text(json.dumps(record, indent=2) + '\n')
    print('Frozen build/artifact_manifest.json')
