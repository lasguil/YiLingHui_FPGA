"""Reject a missing/negative routed timing summary or invalid constraints."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
text = (root / 'build/final_timing.rpt').read_text()
summary = text.split('---------- 2. Clock Relationship Summary (begin) ----------')[1].split('---------- Clock Relationship Summary (end)')[0]
slacks = [float(x) for x in re.findall(r'^\S+\s+\S+\s+[-\d.]+\s+([-\d.]+)\s+\(R-[RF]\)', summary, re.M)]
log = (root / 'build/timing.log').read_text(errors='replace')
sdc = (root / 'ti60f225_oob.sdc').read_text(errors='replace')
if not slacks or min(slacks) < 0:
    raise SystemExit(f'FAIL: routed timing minimum slack {min(slacks) if slacks else "missing"}')
if re.search(r'^\s*ERROR\s*:|invalid command name|No cells matched|No pins matched|no vaild endpoints|Fail to open', log, re.I | re.M):
    raise SystemExit('FAIL: STA/SDC errors or unmapped constraints; inspect build/timing.log')
blocks = re.findall(r'MJPEG_PATH_BEGIN bank=(\w+) bit=(\d+) source=(\S+) sink=(\S+)\n(.*?)MJPEG_PATH_END bank=\1 bit=\2', log, re.S)
bank_widths = {'write': 14, 'read': 14, 'hdmi_write': 12, 'hdmi_read': 12,
               'hdmi_capture_write': 10, 'hdmi_capture_read': 10}
expected = {(bank, str(i)) for bank, width in bank_widths.items() for i in range(width)}
if len(blocks) != 72 or {(bank, bit) for bank, bit, *_ in blocks} != expected:
    raise SystemExit('FAIL: expected exactly 72 HDMI/MJPEG FIFO Gray paths')
for bank, bit, source, sink, body in blocks:
    exception = re.search(r'Timing Exception\s*:\s*Max Delay Path\s+([0-9.]+)\s+ns', body)
    slack = re.search(r'Slack\s*:\s*([-+0-9.]+)\s+ns', body)
    endpoint = re.search(r'Path End\s*:\s*(\S+)', body)
    if ('No timing path is found' in body or not exception or abs(float(exception[1]) - 5) > 0.001
            or not slack or float(slack[1]) <= 0 or not endpoint or endpoint[1] != sink):
        raise SystemExit(f'FAIL: MJPEG FIFO {bank}[{bit}] is missing, cut, unconstrained or failing')
print(f'PASS: {len(slacks)} clock relationships, minimum slack {min(slacks):.3f} ns')
print('PASS: 72/72 HDMI/MJPEG FIFO Gray paths meet their 5 ns bounds')
for name in ('mjpeg_start_first', 'mjpeg_busy_first', 'mjpeg_error_first',
             'mjpeg_source_overflow_first', 'mjpeg_source_error_first',
             'mjpeg_output_overflow_first',
             'hdmi_mjpeg_bad_first', 'mjpeg_source_frame_first',
             'hdmi_capture_bad_first'):
    if f'MJPEG_CDC_CONTROL {name} 1' not in log:
        raise SystemExit(f'FAIL: {name} synchronizer endpoint is missing')
    stem = {'mjpeg_start_first': 'mjpeg_start_sync',
            'mjpeg_busy_first': 'mjpeg_busy_sync',
            'mjpeg_error_first': 'mjpeg_error_sync',
            'mjpeg_source_overflow_first': 'mjpeg_source_overflow_sync',
            'mjpeg_source_error_first': 'mjpeg_source_error_sync',
            'mjpeg_output_overflow_first': 'mjpeg_output_overflow_sync',
            'hdmi_mjpeg_bad_first': 'u_mjpeg_source/u_capture/bad_sync1',
            'mjpeg_source_frame_first': 'mjpeg_source_frame_sync',
            'hdmi_capture_bad_first': 'u_capture/bad_sync1'}[name]
    target = (r'^u_mjpeg_source/u_capture/bad_sync1~FF\|D$'
              if name == 'hdmi_mjpeg_bad_first'
              else r'^mjpeg_source_frame_sync\[0\]~FF\|D$'
              if name == 'mjpeg_source_frame_first'
              else r'^u_capture/bad_sync1~FF\|D$'
              if name == 'hdmi_capture_bad_first'
              else f'^{stem}\\[0\\]~FF\\|D$')
    constraint = f'set_false_path -to [get_pins -regexp {{{target}}}]'
    if constraint not in sdc:
        raise SystemExit(f'FAIL: first-stage {name} false path is missing')
if ('MJPEG_CDC_CONTROL capture_valid_meta 1' not in log
        or r'^net_status_meta\[[0-9]+\]~FF\|D$' not in sdc):
    raise SystemExit('FAIL: HDMI frame-valid status synchronizer constraint is missing')
if ('HDMI_PCLK_RESET capture_pclk_reset 2' not in log
        or 'HDMI_PCLK_RESET mjpeg_pclk_reset 2' not in log
        or r'^u_capture/pclk_reset_pipe\[[01]\]~FF\|SR$' not in sdc
        or r'^u_mjpeg_source/u_capture/pclk_reset_pipe\[[01]\]~FF\|SR$' not in sdc):
    raise SystemExit('FAIL: recovered HDMI pixel-clock reset synchronizer constraints are missing')
if (sdc.count('set_max_delay -from $mjpeg_') < 2
        or sdc.count('set_max_delay -from $hdmi_mjpeg_') < 2
        or sdc.count('set_max_delay -from $hdmi_capture_') < 2
        or 'u_mjpeg_fifo/.*~FF\\|SR' not in sdc
        or 'u_mjpeg_source/u_capture/u_pixel_fifo/.*~FF\\|SR' not in sdc
        or 'u_capture/u_pixel_fifo/.*~FF\\|SR' not in sdc):
    raise SystemExit('FAIL: MJPEG FIFO Gray or async-reset constraints are missing')
if 'MJPEG_CDC_RESET head=9 empty=1' not in log:
    raise SystemExit('FAIL: MJPEG FIFO FWFT reset endpoints are missing')
if ('mjpeg_fifo_data\\[[0-8]\\]~FF\\|SR' not in sdc
        or '^net_pixel_valid~FF\\|SR$' not in sdc):
    raise SystemExit('FAIL: MJPEG FIFO FWFT reset constraints are missing')
print('PASS: MJPEG control/diagnostic synchronizers and FIFO reset paths are constrained')
if ('STREAM_RECOVERY_RESET stream_up_reset 2' not in log
        or 'STREAM_RECOVERY_RESET stream_abort_reset 1' not in log
        or r'^mjpeg_stream_up\[[01]\]~FF\|SR$' not in sdc
        or r'^mjpeg_link_abort~FF\|SR$' not in sdc):
    raise SystemExit('FAIL: stream recovery reset endpoints or constraints are missing')
print('PASS: stream recovery reset release synchronizers are constrained')
web_groups = ('web_cmd_wgray', 'web_cmd_rgray', 'web_status_wgray', 'web_status_rgray')
missing_web = [name for name in web_groups if name + '_src' not in sdc or name + '_dst' not in sdc]
if missing_web or sdc.count('set_max_delay -from $web_') < 4:
    raise SystemExit('FAIL: web/J7 mailbox Gray CDC bounds missing from SDC')
print('PASS: web/J7 mailbox Gray CDC constraints are present (map/STA validation still required)')

mapped = (root / 'outflow/ti60f225_oob.map.v').read_text(errors='replace')
if ('HDMI_INPUT_MODE_CDC fixed_1080p' not in log
        or 'mjpeg_input_meta' in sdc
        or 'mjpeg_input_meta' in mapped or 'mjpeg_input_sync' in mapped):
    raise SystemExit('FAIL: fixed HDMI geometry has stale adaptive CDC logic/constraints')
print('PASS: fixed 1080p geometry; no stale adaptive mode CDC endpoints')
