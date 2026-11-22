"""Reuse a frozen map only after proving all synthesis/firmware inputs match."""
from pathlib import Path
import argparse,json,re,runpy
root=Path(__file__).resolve().parents[1]
record=runpy.run_path(str(root/'tools/build_record.py'))
sha,inputs=record['sha'],record['inputs']
p=argparse.ArgumentParser()
p.add_argument('action',choices=['prepare','verify'])
p.add_argument('previous',nargs='?')
p.add_argument('--profile',choices=['CONGESTION_1','CONGESTION_2','CONGESTION_3','TIMING_1','TIMING_2','TIMING_3'],default='CONGESTION_1')
p.add_argument('--seed',type=int,default=4)
args=p.parse_args()
audit=root/'build/pnr_reuse.json'
if args.action=='verify':
    data=json.loads(audit.read_text(encoding='utf-8'))
    if inputs()!=data['inputs']:raise SystemExit('PNR-only inputs changed')
    for name,digest in data['mapped_files'].items():
        if sha(root/'outflow'/name)!=digest:raise SystemExit('Mapped/interface artifact changed: '+name)
    print('PASS: PNR-only map/interface and synthesis/firmware fingerprints match')
else:
    if not args.previous or not re.fullmatch('[a-z0-9_]+',args.previous):raise SystemExit('invalid previous tag')
    previous=root/'build/render_takeover_20261011'/args.previous
    old=json.loads((previous/'build_inputs.json').read_text(encoding='utf-8'))
    if inputs()!=old['inputs']:raise SystemExit('Inputs differ from frozen prior map; remap required')
    names=['ti60f225_oob.vdb','ti60f225_oob.map.v','ti60f225_oob.interface.csv']
    mapped={name:sha(root/'outflow'/name) for name in names}
    times=json.loads((previous/'artifact_times.json').read_text(encoding='utf-8'))
    reuse_path=previous/'pnr_reuse.json'
    prior_reuse=json.loads(reuse_path.read_text(encoding='utf-8')) if reuse_path.exists() else None
    for name,digest in mapped.items():
        # A PNR-only round intentionally preserves the map timestamps. Its
        # audited reuse record must bind both the prior inputs and exact bytes.
        inherited=(prior_reuse is not None and prior_reuse['inputs']==old['inputs']
                   and prior_reuse['mapped_files'].get(name)==digest)
        if sha(previous/'outflow'/name)!=digest or not (times[name]['from_this_round'] or inherited):
            raise SystemExit('Prior map/interface is stale or changed: '+name)
    project=root/'ti60f225_oob.xml'
    text=project.read_text(encoding='utf-8')
    for name,value in [('optimization_level',args.profile),('seed',str(args.seed))]:
        pattern=r'(<efx:param name="'+name+r'" value=")[^"]+(" value_type=)'
        text,count=re.subn(pattern,lambda m:m[1]+value+m[2],text)
        if count!=1:raise SystemExit('Unexpected project option count: '+name)
    project.write_text(text,encoding='utf-8')
    data={'previous_tag':args.previous,'profile':args.profile,'seed':args.seed,
          'mapped_files':mapped,'inputs':inputs()}
    audit.write_text(json.dumps(data,indent=2),encoding='utf-8')
    print(f'Prepared PNR-only retry: {args.profile}, seed={args.seed}; RTL/firmware/map unchanged')
