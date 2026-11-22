#!/usr/bin/env bash
# Install an already-built firmware ROM into the Efinity project after saving originals.
set -euo pipefail
FW_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$FW_ROOT/../.." && pwd)"
SOURCE_DIR="${1:-$FW_ROOT/build/linux/rom}"
BACKUP_DIR="${2:-$PROJECT_ROOT/build/rom_backup_$(date +%Y%m%d_%H%M%S)}"
FIRMWARE_BIN="$(cd "$SOURCE_DIR/.." && pwd)/gesture_demo.bin"
mkdir -p "$BACKUP_DIR" "$PROJECT_ROOT/build"

for lane in 0 1 2 3; do
  source="$SOURCE_DIR/gesture_demo_ram_symbol${lane}.bin"
  target="$PROJECT_ROOT/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol${lane}.bin"
  test -s "$source"
  test ! -e "$BACKUP_DIR/$(basename "$target")"
  cp -p "$target" "$BACKUP_DIR/$(basename "$target")"
  cp "$source" "$target.tmp"
  mv "$target.tmp" "$target"
done

python3 -I -B - "$PROJECT_ROOT" "$BACKUP_DIR" "$FIRMWARE_BIN" <<'PY'
from pathlib import Path
import hashlib, json, sys
root, backup, firmware_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
lanes = []
for i in range(4):
    path = root / f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin"
    words = path.read_text("ascii").splitlines()
    assert len(words) == 4096 and all(len(w) == 8 and set(w) <= set("01") for w in words)
    lanes.append(bytes(int(w, 2) for w in words))
image = bytes(lanes[i][j] for j in range(4096) for i in range(4))
firmware = firmware_path.read_bytes()
assert image[:len(firmware)] == firmware and image[len(firmware):] == bytes(16384-len(firmware))
record = {
    "status": "firmware_rom_integrated",
    "firmware_bin_sha256": hashlib.sha256(firmware).hexdigest(),
    "padded_image_sha256": hashlib.sha256(image).hexdigest(),
    "firmware_bytes": len(firmware), "padded_bytes": len(image),
    "backup_dir": str(backup.relative_to(root)),
    "lanes": {f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin":
              hashlib.sha256((root / f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin").read_bytes()).hexdigest()
              for i in range(4)},
}
(root / "build/firmware_rom_integration.json").write_text(json.dumps(record, indent=2)+"\n")
print(json.dumps(record, indent=2))
PY
