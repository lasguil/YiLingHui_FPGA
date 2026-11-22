"""Bit-level LUT connectivity of the generated Efinity netlist, not timing STA."""
from pathlib import Path
import re,json,collections,functools
P=Path(__file__).resolve().parents[1]/'build/ab_write_specialize_20261013/coupled_context'
def analyze(tag):
    text=(P/tag/'outflow/ab_write_probe.map.v').read_text()
    widths={}
    for m in re.finditer(r'\bwire\s+(?:\[(\d+):(\d+)\]\s*)?(\\\S+|\w+)\s*;',text):
        widths[m[3].lstrip('\\')]=(int(m[1]),int(m[2])) if m[1] else None
    def nets(expr):
        out=[]
        # Escaped identifiers can contain their own unpacked [indices]; a
        # packed bit select follows the mandatory whitespace terminator.
        pat=r"(?:\d+'[bhd][0-9a-fxz]+)|((?:\\[^\s]+\s+|[A-Za-z_]\w*)(?:\[\d+(?::\d+)?\])?)"
        for m in re.finditer(pat,expr):
            if not m[1]:continue
            s=m[1].strip()
            if s.startswith('\\'):
                parts=s[1:].split();name=parts[0];sel=''.join(parts[1:])
            else:
                mm=re.match(r'(\w+)(.*)',s);name,sel=mm.groups()
            if sel:
                ns=list(map(int,re.findall(r'\d+',sel)))
                a,b=(ns[0],ns[-1]);out.extend(f'{name}<{i}>' for i in range(min(a,b),max(a,b)+1))
            elif widths.get(name):
                a,b=widths[name];out.extend(f'{name}<{i}>' for i in range(min(a,b),max(a,b)+1))
            else:out.append(name)
        return out
    cells=[]
    for m in re.finditer(r'\b(EFX_\w+)\s+(\\\S+|\w+)\s+\((.*?)\)\s*/\*',text,re.S):
        kind,name,body=m.groups();ports={}
        for pp in re.finditer(r'\.(\w+)\(([^()]*)\)',body):ports[pp[1]]=nets(pp[2])
        cells.append((kind,name,ports))
    count=collections.Counter(k for k,n,p in cells)
    rpt=(P/tag/'outflow/ab_write_probe.map.rpt').read_text()
    for typ in ['EFX_LUT4','EFX_FF','EFX_RAM10','EFX_ADD']:
        expected=int(re.search(r'^'+typ+r'\s*:\s*(\d+)',rpt,re.M)[1])
        assert count[typ]==expected,(tag,typ,count[typ],expected)
    driver={};roots=set();ram_data=[]
    for kind,name,p in cells:
        if kind=='EFX_LUT4':
            assert len(p['O'])==1
            driver[p['O'][0]]=(name,sum((p.get('I'+str(i),[]) for i in range(4)),[]))
        if kind=='EFX_FF' and ('code_lanes[' in name or 'saved_lanes_q[' in name or
                any(q in {f'results<{i}>' for i in range(1315,1443)} for q in p['Q'])):roots.update(p['Q'])
        if kind=='EFX_RAM10':ram_data.extend(p['WDATA'])
    assert len(roots)==256,(tag,len(roots))
    @functools.lru_cache(None)
    def cone(net):
        if net not in driver:return frozenset()
        name,ins=driver[net]
        return frozenset({name}).union(*(cone(i) for i in ins))
    @functools.lru_cache(None)
    def data_depth(net):
        if net in roots:return 0
        if net not in driver:return -1
        dep=max((data_depth(i) for i in driver[net][1]),default=-1)
        return dep+1 if dep>=0 else -1
    union=set().union(*(cone(n) for n in ram_data))
    rf_cone=set().union(*(cone(f'results<{i}>') for i in range(1059,1315)))
    depth=collections.Counter(data_depth(n) for n in ram_data)
    data_luts={name for net,(name,ins) in driver.items() if name in union and data_depth(net)>=0}
    return {'cells':dict(count),'ram_wdata_lut_cone':len(union),
            'generic_format_lut_cone':len(rf_cone),'shared_format_and_ram_luts':len(rf_cone & union),
            'joint_format_and_ram_luts':len(rf_cone | union),
            'ram_wdata_data_dependent_luts':len(data_luts),
            'ram_wdata_depth_from_code_or_saved_ff':dict(sorted(depth.items())),
            'data_lut_names':sorted(data_luts)}
result={t:analyze(t) for t in ['legacy','legacy_reverse','special','special_reverse']}
(P/'mapped_cones.json').write_text(json.dumps(result,indent=2))
for tag,v in result.items():print(tag,json.dumps({k:x for k,x in v.items() if k!='data_lut_names'}))
