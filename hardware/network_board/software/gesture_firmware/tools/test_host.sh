#!/usr/bin/env bash
set -euo pipefail
FW_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-cc}"
OUT="${FW_ROOT}/build/host"
mkdir -p "$OUT"
"$CC" -std=c11 -Wall -Wextra -Werror -I"$FW_ROOT/include" \
  "$FW_ROOT/src/gesture_fw.c" "$FW_ROOT/tests/test_gesture_fw.c" \
  -o "$OUT/test_gesture_fw"
"$OUT/test_gesture_fw"
"$CC" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST -DFLASH_WORD_TIMEOUT_SPINS=1024 \
  -DGESTURE_APP_NO_MAIN -DNPU_WAIT_SPINS=2 -DROI_WAIT_SPINS=4 \
  -I"$FW_ROOT/include" "$FW_ROOT/src/gesture_fw.c" \
  "$FW_ROOT/src/main.c" "$FW_ROOT/src/gesture_flash_loader.c" \
  "$FW_ROOT/tests/test_gesture_app.c" \
  -o "$OUT/test_gesture_app"
"$OUT/test_gesture_app"
"$CC" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST \
  -I"$FW_ROOT/include" "$FW_ROOT/src/gesture_flash_loader.c" \
  "$FW_ROOT/tests/test_gesture_flash_loader.c" -o "$OUT/test_gesture_flash_loader"
"$OUT/test_gesture_flash_loader" \
  "$FW_ROOT/model/weights_hw.bin" "$FW_ROOT/model/param_hw.bin"
"$CC" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST \
  -I"$FW_ROOT/include" "$FW_ROOT/src/gesture_return.c" \
  "$FW_ROOT/tests/test_gesture_return.c" -o "$OUT/test_gesture_return"
"$OUT/test_gesture_return"
"$CC" -std=c11 -Wall -Wextra -Werror -I"$FW_ROOT/include" \
  "$FW_ROOT/tests/test_gesture_geometry.c" -o "$OUT/test_gesture_geometry"
"$OUT/test_gesture_geometry"
echo "Firmware host regressions PASS"
