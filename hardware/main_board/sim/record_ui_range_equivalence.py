"""Archive the completed old/new RTL comparison and mark the pending RTL change."""
import hashlib
import json
import re
from pathlib import Path

p = Path(__file__).resolve().parents[1]
run = p / 'tmp/ui_range_equivalence'
old = p / 'support/before_ui_range_20261112/display_renderer.sv'
new = p / 'rtl/display/display_renderer.sv'
log = (run / 'run.log').read_text(errors='replace')
match = re.search(r'PASS UI RANGE EQUIVALENCE samples=(\d+) font=(\d+) reads=(\d+) ink=(\d+) message_mask=(\w+)', log)
assert match and not re.search(r'\*\* (Error|Fatal)', log), 'RTL comparison must pass first'
before = old.read_text(encoding='utf-8-sig')
after = new.read_text(encoding='utf-8-sig')
old_fragment = 'if((x>=font_origin)&&(x<font_origin+font_len*16)&&(y>=font_y_origin)&&(y<font_y_origin+21))begin'
new_fragment = '''// Compare the existing relative character index with the length;
            // avoid placing a right-edge adder after the message-length decode.
            // High bits must be zero to prevent a 512-pixel coordinate alias.
            if((x>=font_origin)&&(font_x[11:9]==0)&&(font_x[8:4]<font_len)&&
               (y>=font_y_origin)&&(y<font_y_origin+21))begin'''
assert before.count(old_fragment) == 1
assert before.replace(old_fragment, new_fragment) == after, 'unexpected extra RTL changes'
digest = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
record = {
    'status': 'RTL_DIFFERENTIAL_PASS_SYNTHESIS_AND_PNR_NOT_RUN',
    'changed_rtl': str(new.relative_to(p)),
    'before_sha256': digest(old), 'after_sha256': digest(new),
    'changes': 'Use the existing relative glyph-cell index instead of adding the right edge after message-length decode; retain high-bit guard.',
    'latency_added': 0, 'new_registers': 0, 'new_ram': 0, 'new_dsp': 0,
    'comparison': dict(zip(('samples', 'font_samples', 'text_reads', 'ink_samples'), map(int, match.groups()[:4]))),
    'message_mask': match.group(5),
    'scenarios': 24,
    'compared': ['all renderer output ports', 'font active/index/x', 'text ROM read enable/address', 'glyph ROM address', 'font pixel'],
    'synthesis_benefit': 'Not yet measured; targets the historical font_msg -> font_len -> boundary adder critical path.',
    'full_fpga_build_started': False, 'programmed': False,
}
(run / 'RESULT.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
manifest = p / 'TRIAL_BUILD_RESULT.json'
data = json.loads(manifest.read_text(encoding='utf-8'))
data['ui_range_optimization_20261112'] = record
entry = '2026-11-12 UI text range equivalent simplification; RTL differential PASS; synthesis pending'
if entry not in data['pending_changes']:
    data['pending_changes'].append(entry)
data['current_build_available'] = False
manifest.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(record, ensure_ascii=False))
