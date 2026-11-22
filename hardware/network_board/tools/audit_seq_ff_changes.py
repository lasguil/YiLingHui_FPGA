"""Locate named mapped FF removals for the seq_opt single-option experiment."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
base = root / 'build/x0_prefetch_barrier_20261013/work/project'
candidate = root / 'build/x0_prefetch_seq_opt_20261013/work/project'

def cells(project):
    source = (project / 'outflow/ti60f225_oob.map.v').read_text(encoding='utf-8-sig')
    result = {}
    for match in re.finditer(r'\bEFX_FF\s+(\S+)\s+\((.*?)\)\s*/\*.*?;', source, re.S):
        name = match[1].lstrip('\\')
        normalized = re.sub(r'^i\d+/', '', name)
        result[normalized] = {key: (re.search(r'\.' + key + r'\((.*?)\)', match[2], re.S)[1].strip()
                                   if re.search(r'\.' + key + r'\((.*?)\)', match[2], re.S) else None)
                              for key in ('D', 'CE', 'SR', 'Q', 'CLK')}
    return result

old, new = cells(base), cells(candidate)
removed = {name: old[name] for name in sorted(old.keys() - new.keys())}
added = {name: new[name] for name in sorted(new.keys() - old.keys())}
regions = ('u_ddr3_top/u_memory_bus_ctl/', 'checker0/', 'u_display/', 'inst_efx_csi2_rx/')
summary = {region: {'removed': {name: ports for name, ports in removed.items() if region in name},
                    'added': {name: ports for name, ports in added.items() if region in name}}
           for region in regions}
report = {'note': 'Named cells may be merged or renamed; absence alone does not prove a lost state bit.',
          'base_named_ff': len(old), 'candidate_named_ff': len(new),
          'removed': removed, 'added': added, 'selected_regions': summary}
(candidate / 'build/seq_ff_changes.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
for region, data in summary.items():
    names = list(data['removed'])
    print(json.dumps({'region': region, 'removed': len(names), 'added': len(data['added']),
                      'first_removed': {name: data['removed'][name] for name in names[:6]}}, ensure_ascii=False))
