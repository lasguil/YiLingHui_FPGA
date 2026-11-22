"""Freeze a one-variable PHY payload timing experiment; never overwrite a build."""
from pathlib import Path
import hashlib
import json
import shutil

root = Path(__file__).resolve().parents[1]
tag = 'ddr_committed_payload_20261014'
source = root / 'build/x0_prefetch_seq_opt_20261013/work/project'
target = root / f'build/{tag}/work/project'
assert not target.exists(), target
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
inputs = json.loads((source / 'build/build_inputs.json').read_text(encoding='utf-8-sig'))['inputs']
for name, digest in inputs.items():
    assert sha(source / name) == digest, name
    if name.startswith('../'):
        continue
    dest = target / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / name, dest)

name = 'rtl/ddr_rewrite/slim/memory_bus_ctl_slim.sv'
path = target / name
data = path.read_bytes()
before = b'assign mc_wrdata_en=data_valid&&!phy_mc_data_full;'
assert data.count(before) == 1
after = (b'// PHY contract experiment: full constrains NEW WR CAS admission above.\r\n'
         b'// A committed CAS retains its registered payload delivery cadence,\r\n'
         b'// matching the vendor MC public-port trace; no late payload cancellation.\r\n'
         b'assign mc_wrdata_en=data_valid;')
path.write_bytes(data.replace(before, after))
assert [n for n, d in inputs.items() if not n.startswith('../') and sha(target / n) != d] == [name]
for n in ('build_record.py', 'program_today_capture.ps1'):
    shutil.copy2(source / 'tools' / n, target / 'tools' / n)
runner = (source / 'tools/run_barrier_full.ps1').read_text(encoding='utf-8-sig')
runner = runner.replace('x0_prefetch_seq_opt_20261013', tag)
(target / 'tools/run_barrier_full.ps1').write_text(runner, encoding='utf-8')
(target / 'build').mkdir(exist_ok=True)
manifest = {
    'candidate': tag, 'source': str(source), 'base_inputs': inputs,
    'changed_inputs': [name], 'xml_sdc_firmware_unchanged': True,
    'hypothesis': 'WR CAS admission reserves delivery; data_full must not postpone committed payload',
    'change': 'mc_wrdata_en=data_valid; keep payload FF, full-gated new WR CAS and all other logic',
    'status': 'experimental_unverified',
}
(target / 'build/committed_payload_manifest.json').write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
print(target)
