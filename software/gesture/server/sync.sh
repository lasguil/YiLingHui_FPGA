#!/usr/bin/env bash
# Deploy the gesture training code to the shared training server.
#
# The repository is the source of truth; the server workspace only runs code.
# The whole file set travels as one small tar so the transfer needs a single
# connection. Credentials live in tmp/gssh.py, which is gitignored, so nothing
# secret is reachable from the tracked tree.
#
# Usage: bash gesture/server/sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Two forms of the same directory are needed: MSYS tools (tar, rm) want /e/...,
# while the native Windows interpreter wants E:/.... A Windows path handed to
# tar is read as a remote host because of the colon.
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_WIN="$(cd "$SCRIPT_DIR/../.." && pwd -W 2>/dev/null || echo "$REPO")"

SSH_HELPER="$REPO_WIN/tmp/gssh.py"
PY="${PY:-C:/Users/29966/AppData/Local/Programs/Python/Python312/python.exe}"
WORKSPACE=/data1/fpga_style_transfer_2026_tmp/gesture_four_class_20261015
REMOTE="$WORKSPACE/ml"
ARCHIVE="$REPO/tmp/gesture_code.tar"
ARCHIVE_WIN="$REPO_WIN/tmp/gesture_code.tar"

if [ ! -f "$REPO/tmp/gssh.py" ]; then
    echo "missing $REPO/tmp/gssh.py" >&2
    exit 1
fi

FILES=(
    src/__init__.py
    src/spec.py
    src/model.py
    src/preprocess.py
    src/index.py
    src/losses.py
    src/metrics.py
    src/data.py
    src/sampler.py
    src/train.py
    src/evaluate.py
    src/decision.py
    tools/build_index.py
    tools/build_hand_size_table.py
    tools/build_small_hand_overrides.py
    tools/render_hand_size_sheet.py
    tools/ingest_external_negatives.py
    tools/train_g4net.py
    tools/eval_g4net.py
    tools/sweep_target_threshold.py
    tools/analyze_confusion_by_subclass.py
    tools/selfcheck_pipeline.py
    tools/training_progress.py
    tools/smoke_train_g4net.py
    configs/g4net_v1.json
    configs/g4net_v1_train.json
    configs/g4net_v2.json
    configs/g4net_v2_train.json
    configs/g4net_v3.json
    configs/g4net_v3_train.json
    configs/g4net_v1_decision.json
    configs/g4net_v2_decision.json
    configs/g4net_v3_decision.json
    configs/g4net_v4.json
    configs/g4net_v4_train.json
    configs/g4net_v4_decision.json
    server/run_baseline.sh
)


# A CR in a shell script survives `bash -n` and only fails at run time, as
# "pipefail<CR>: invalid option name". Refuse to ship one rather than discover
# it on the server after a long build. The pattern is spelled \x0d so that no
# part of this file can itself carry a raw CR.
for name in "${FILES[@]}"; do
    case "$name" in
        *.sh)
            if [ -f "$REPO/gesture/$name" ] && grep -q $'\x0d' "$REPO/gesture/$name"; then
                echo "$name has CR line endings; convert it to LF before shipping" >&2
                exit 1
            fi
            ;;
    esac
done


present=()
for name in "${FILES[@]}"; do
    if [ -e "$REPO/gesture/$name" ]; then
        present+=("$name")
    else
        echo "skip (not present): $name"
    fi
done

rm -f "$ARCHIVE"
tar -cf "$ARCHIVE" -C "$REPO/gesture" "${present[@]}"
echo "packed ${#present[@]} files -> $(wc -c <"$ARCHIVE") bytes"

MSYS_NO_PATHCONV=1 "$PY" "$SSH_HELPER" --put "$ARCHIVE_WIN" "$REMOTE/code.tar"
MSYS_NO_PATHCONV=1 "$PY" "$SSH_HELPER" -q \
    "cd $REMOTE && tar -xf code.tar && rm -f code.tar && chmod +x server/run_baseline.sh && echo '--- deployed ---' && find . -type f | sort && echo '--- host ---' && hostname"

rm -f "$ARCHIVE"
echo
echo "next:"
echo "  MSYS_NO_PATHCONV=1 \"$PY\" \"$SSH_HELPER\" -q 'bash $REMOTE/server/run_baseline.sh preflight'"
