#!/usr/bin/env bash
# Build only. Deliberately has no programming or flash operation.
set -euo pipefail
cd "$(dirname "$0")"
unset EFINITY_HOME PYTHONHOME PYTHONPATH
export PATH="${EFINITY_BIN:-/home/grant/efinity/2026.1/bin}:$PATH"
mkdir -p build
python3 -I -B tools/generate_sources_f.py
case "${1:-quick}" in
  map|interface|pnr)
    efx_run ti60f225_oob --prj --flow "$1" 2>&1 | tee "build/$1.log" ;;
  timing)
    python3 -I -B tools/verify_cdc_payloads.py generate --map outflow/ti60f225_oob.map.v --sdc ti60f225_oob.sdc --out build/cdc_payload_signoff > build/cdc_payload_generation.log
    python3 -I -B tools/verify_ddr_gray_cdc.py generate --map outflow/ti60f225_oob.map.v --sdc ti60f225_oob.sdc --out build/cdc_payload_signoff > build/cdc_gray_generation.log
    efx_run ti60f225_oob --prj --flow sta_tclsh -t "$PWD/tools/integration_timing.tcl" 2>&1 | tee build/timing.log
    # Efinity resolves report -file names relative to its output directory.
    # Keep the legacy validator/archive input in sync with the actual report.
    cp outflow/final_timing.rpt build/final_timing.rpt
    python3 -I -B tools/verify_cdc_payloads.py validate --log build/timing.log --out build/cdc_payload_signoff > build/cdc_payload_validation.log
    python3 -I -B tools/verify_ddr_gray_cdc.py validate --log build/timing.log --out build/cdc_payload_signoff > build/cdc_gray_validation.log
    python3 -I -B tools/check_integration_timing.py ;;
  bitstream)
    # pgm generates programming files. No 'program' option or flow is invoked.
    efx_run ti60f225_oob --prj --flow pgm 2>&1 | tee build/bitstream.log ;;
  quick)
    efx_run ti60f225_oob --prj --flow map 2>&1 | tee build/map.log
    efx_run ti60f225_oob --prj --flow interface 2>&1 | tee build/interface.log ;;
  all)
    software/gesture_firmware/tools/build_linux.sh
    software/gesture_firmware/tools/test_host.sh | tee build/host_firmware_regression.log
    software/gesture_firmware/tools/integrate_rom_linux.sh
    for flow in map interface pnr; do
      efx_run ti60f225_oob --prj --flow "$flow" 2>&1 | tee "build/$flow.log"
    done
    bash build.sh timing
    bash build.sh bitstream
    python3 -I -B tools/freeze_artifact.py ;;
  *) echo "Usage: bash build.sh [quick|map|interface|pnr|timing|bitstream|all]" >&2; exit 2 ;;
esac
