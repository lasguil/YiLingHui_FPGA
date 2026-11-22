#!/usr/bin/env python3
"""Package source + evidence without build caches, SDK, private keys or recursive archives."""
from pathlib import Path
import hashlib, zipfile
root=Path(__file__).resolve().parent.parent
out=root/'deliverables';out.mkdir(exist_ok=True)
archive=out/'Ti60Mobile-1.0.0-source.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(root.rglob('*')):
  relative=p.relative_to(root)
  if not p.is_file() or any(x in ('build','.gradle','.git','deliverables','__pycache__') for x in relative.parts) or p.name in ('local.properties',) or p.suffix in ('.jks','.keystore','.pyc'):continue
  z.write(p,Path('Ti60Mobile')/relative)
files=sorted(p for p in out.iterdir() if p.suffix in ('.apk','.zip'))
(out/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
print((out/'SHA256SUMS').read_text())
