#!/usr/bin/env bash
# Reproducible Linux build for the standalone RV32 firmware. Build-only: no JTAG.
set -euo pipefail
FW_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EFINITY_RISCV="${EFINITY_RISCV:-/home/grant/efinity/efinity-riscv-ide-2026.1}"
TOOLBIN="${EFINITY_RISCV}/toolchain/bin"
OUT="${1:-${FW_ROOT}/build/linux}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
export PATH="${TOOLBIN}:${PATH}"

python3 -I -B "$FW_ROOT/tools/package_model.py"
riscv-none-elf-gcc \
  -march=rv32im_zicsr -mabi=ilp32 -Os -ffreestanding -fno-builtin \
  -ffunction-sections -fdata-sections -nostartfiles -I"$FW_ROOT/include" \
  -Wl,--gc-sections -Wl,-Map,"$OUT/gesture_demo.map" \
  -Wl,-T,"$FW_ROOT/software/link.ld" \
  "$FW_ROOT/src/startup.S" "$FW_ROOT/src/main.c" \
  "$FW_ROOT/src/gesture_fw.c" "$FW_ROOT/src/gesture_return.c" \
  "$FW_ROOT/src/gesture_flash_loader.c" \
  -lgcc -o "$OUT/gesture_demo.elf"
riscv-none-elf-objcopy -O binary "$OUT/gesture_demo.elf" "$OUT/gesture_demo.bin"
riscv-none-elf-objdump -h "$OUT/gesture_demo.elf" > "$OUT/gesture_demo_sections.txt"
riscv-none-elf-size "$OUT/gesture_demo.elf" | tee "$OUT/gesture_demo_size.txt"
python3 -I -B "$FW_ROOT/tools/pack_ocr_rom.py" \
  --output-dir "$OUT/rom" "$OUT/gesture_demo.bin"
sha256sum "$OUT/gesture_demo.elf" "$OUT/gesture_demo.bin" \
  "$OUT"/rom/gesture_demo_ram_symbol*.bin | tee "$OUT/SHA256SUMS"
echo "Firmware build PASS: $OUT"
