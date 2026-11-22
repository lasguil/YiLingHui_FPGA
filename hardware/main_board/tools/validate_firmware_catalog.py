"""Build-time validation for the immutable, boot-only firmware name catalog."""
from pathlib import Path
import ast,re

p=Path(__file__).resolve().parents[1]
source=(p/'software/style_model_assets_generated.h').read_text()
limits=(p/'software/style_ui_catalog.h').read_text()
allowed=set('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -/.')
for kind,limit_name in [('MODEL','MODEL'),('TABLE','TABLE')]:
 marker='#define STYLE_'+kind+'_ASSET_ROWS'
 body=source.split(marker,1)[1].split('#define',1)[0].split('#endif',1)[0]
 names=[ast.literal_eval(s) for s in re.findall(r'\{\s*("(?:[^"\\]|\\.)*")\s*,',body)]
 assert names,kind+' catalog empty'
 limit=int(re.search('STYLE_UI_CATALOG_'+limit_name+r'_MAX_CHARS\s*=\s*(\d+)',limits).group(1))
 for name in names:
  if not name or len(name)>limit or not set(name)<=allowed:
   raise SystemExit(f'Invalid {kind} catalog name {name!r}; limit={limit}, uppercase UI alphabet required')
 print(f'{kind}: {len(names)} names, valid uppercase glyphs and <= {limit} characters')
