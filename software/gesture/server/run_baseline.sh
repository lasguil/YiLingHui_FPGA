#!/usr/bin/env bash
# Launch a G4Net run on the shared training server, pinned to GPU1.
#
# Guards, in order:
#   1. GPU1 must have enough FREE memory. GPU1 is legitimately shared with this
#      project's other jobs, so occupancy alone is not a refusal condition.
#   2. The run directory must not already exist.
#   3. The index, summary and training config must all exist.
#
# The launch always pins CUDA_VISIBLE_DEVICES=1 and drops LD_LIBRARY_PATH, which
# conda's activation scripts poison.
#
# Usage:
#   bash run_baseline.sh preflight [tag]   # few hundred steps, foreground
#   bash run_baseline.sh full      [tag]   # full budget, detached
set -euo pipefail

WORKSPACE=/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015
ML="$WORKSPACE/ml"
DATA="$WORKSPACE/datasets"
RUNS="$WORKSPACE/runs"
LOGS="$WORKSPACE/logs"
PYTHON=/data1/fpga_style_transfer_2026_tmp/envs/starry/bin/python

STAGE="${1:-preflight}"
TAG="${2:-v4_baseline_$(date +%Y%m%d)}"
STAMP="$(date +%Y%m%d_%H%M%S)"

# Every temporary file this project produces must live under the workspace:
# /tmp and the home directory are outside the permitted write boundary.
export TMPDIR="$WORKSPACE/tmp"
mkdir -p "$TMPDIR"

INDEX="$DATA/index.jsonl"
SUMMARY="$DATA/index_summary.json"
TRAIN_CONFIG="$ML/configs/g4net_v4_train.json"
MIN_FREE_MB="${MIN_FREE_MB:-4000}"

echo "stage    : $STAGE"
echo "tag      : $TAG"
echo "host     : $(hostname)"
echo "python   : $PYTHON"

# --- guard 1: GPU1 free memory -------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi not found; refusing to launch blind" >&2
    exit 1
fi
free_mb=$(nvidia-smi -i 1 --query-gpu=memory.free --format=csv,noheader,nounits)
used_mb=$(nvidia-smi -i 1 --query-gpu=memory.used --format=csv,noheader,nounits)
echo "gpu1     : ${used_mb} MiB used, ${free_mb} MiB free"
nvidia-smi -i 1 --query-compute-apps=pid,used_memory --format=csv,noheader || true
if [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
    echo "GPU1 free memory ${free_mb} MiB is below MIN_FREE_MB=${MIN_FREE_MB}; refusing." >&2
    exit 1
fi

# --- guard 2: run directory -----------------------------------------------------
# Only this stage's own directory is checked. A preflight is meant to be a cheap
# rehearsal for the same tag, so its directory must not block the full run.
if [ "$STAGE" = "preflight" ]; then
    TARGET="$RUNS/${TAG}_preflight"
else
    TARGET="$RUNS/$TAG"
fi
if [ -e "$TARGET" ]; then
    echo "run directory already exists: $TARGET" >&2
    exit 1
fi

# --- guard 3: inputs ------------------------------------------------------------
for required in "$INDEX" "$SUMMARY" "$TRAIN_CONFIG"; do
    if [ ! -f "$required" ]; then
        echo "missing input: $required" >&2
        exit 1
    fi
done
echo "index    : $(wc -l <"$INDEX") rows"

mkdir -p "$LOGS"

if [ "$STAGE" = "preflight" ]; then
    RUN="$RUNS/${TAG}_preflight"
    LOG="$LOGS/train_${TAG}_preflight_${STAMP}.log"
    echo "run dir  : $RUN"
    echo "log      : $LOG"
    echo
    env -u LD_LIBRARY_PATH CUDA_VISIBLE_DEVICES=1 "$PYTHON" -u \
        "$ML/tools/train_g4net.py" \
        --index "$INDEX" \
        --data-root "$DATA" \
        --config "$TRAIN_CONFIG" \
        --run-dir "$RUN" \
        --device cuda:0 \
        --max-steps 300 \
        --eval-every 300 \
        --eval-limit 2000 \
        2>&1 | tee "$LOG"
    echo
    echo "preflight finished; log at $LOG"
else
    RUN="$RUNS/$TAG"
    LOG="$LOGS/train_${TAG}_${STAMP}.log"
    echo "run dir  : $RUN"
    echo "log      : $LOG"
    command=(env -u LD_LIBRARY_PATH CUDA_VISIBLE_DEVICES=1 "$PYTHON" -u
             "$ML/tools/train_g4net.py"
             --index "$INDEX"
             --data-root "$DATA"
             --config "$TRAIN_CONFIG"
             --run-dir "$RUN"
             --device cuda:0)
    nohup "${command[@]}" >"$LOG" 2>&1 &
    pid=$!
    echo
    echo "launched pid $pid"
    echo "verify the card before walking away:"
    echo "  nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv"
    echo "  ps -ww -p $pid -o user=,cmd="
    echo "follow the log with:"
    echo "  tail -f $LOG"
fi
