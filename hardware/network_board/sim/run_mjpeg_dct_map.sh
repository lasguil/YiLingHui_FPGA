#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
efinity_install="${EFINITY_INSTALL:-/home/grant/efinity/2026.1}"
efinity_user_ini="${EFINITY_USER_DIR_INI:-/tmp/efinity_mjpeg_user/user_dir.ini}"
unset EFINITY_HOME PYTHONHOME PYTHONPATH
set +eu
source "$efinity_install/bin/setup.sh" >/dev/null 2>&1
set -eu
export EFINITY_USER_DIR_INI="$efinity_user_ini"
export CCACHE_DIR="${CCACHE_DIR:-/tmp/efinity_mjpeg_ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-/tmp}"
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
root = Path.cwd()
out = root / 'build/dct_map_regression'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'rtl/mjpegzero/dct_1d.v').read_text()
(out / 'dct_probe.v').write_text(source.replace('module dct_1d (', 'module dct_probe ('))
ns = 'http://www.efinixinc.com/enf_proj'
ET.register_namespace('efx', ns)
ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
tree = ET.parse(root / 'ti60f225_oob.xml')
project = tree.getroot()
project.set('name', 'dct_probe')
design = project.find(f'{{{ns}}}design_info')
for child in list(design):
    design.remove(child)
ET.SubElement(design, f'{{{ns}}}top_module', name='dct_probe')
ET.SubElement(design, f'{{{ns}}}design_file', name=str(out / 'dct_probe.v'),
              version='default', library='default')
for tag in ('constraint_info', 'interface_info', 'ip_info'):
    section = project.find(f'{{{ns}}}{tag}')
    if section is not None:
        section.clear()
tree.write(out / 'dct_probe.xml')
PY
(
  cd build/dct_map_regression
  python3 "$efinity_install/scripts/efx_run.py" dct_probe.xml --flow map >map.log 2>&1
)
verilator --binary --timing --assert -Wno-fatal -j 4 --top-module tb_dct_mapped \
  --Mdir build/dct_map_regression/sim rtl/mjpegzero/dct_1d.v \
  build/dct_map_regression/outflow/dct_probe.map.v \
  "$efinity_install"/sim_models/verilog/*.v sim/tb_dct_mapped.sv \
  >build/dct_map_regression/compile.log 2>&1
build/dct_map_regression/sim/Vtb_dct_mapped >build/dct_map_regression/run.log 2>&1
cat build/dct_map_regression/run.log
