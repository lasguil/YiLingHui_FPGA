#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# Separate HTTP port; never kills the user's existing receiver or browser.
exec python3 -u "$root/../net_web/streamd.py" --board 192.168.0.2 --w 640 --h 360 \
  --http-port "${PERF_HTTP_PORT:-8081}" --quality 80
