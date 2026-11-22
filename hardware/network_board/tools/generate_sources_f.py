"""Keep the Questa source list identical to the board project's Efinity manifest."""
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project = ET.parse(root / "ti60f225_oob.xml").getroot()
ns = {"efx": "http://www.efinixinc.com/enf_proj"}
names = [node.get("name") for node in project.findall(".//efx:design_file", ns)]
if not names:
    raise SystemExit("No design_file entries found in ti60f225_oob.xml")
top_name = project.find(".//efx:top_module", ns).get("name")
if top_name != "ti60f225_oob_top" or "rtl/gesture_board_top.v" not in names:
    raise SystemExit(f"Unexpected top/source pairing: {top_name}, rtl/gesture_board_top.v present={ 'rtl/gesture_board_top.v' in names }")
missing = [name for name in names if not (root / name).is_file()]
if missing:
    raise SystemExit("Manifest sources missing: " + ", ".join(missing))
lines = ["+incdir+rtl", *names]
(root / "sources.f").write_text("\n".join(lines) + "\n", encoding="ascii")
print(f"Wrote {len(names)} manifest sources; top = {top_name}")
