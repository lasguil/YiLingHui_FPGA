"""Detached preflight then fresh 20k-iteration training for V2-D and V2-E.

Source of truth: docs/NativeGroupMixNet_v2_no_depth_cut_two_models_D_E_guide.md
(sections 10 and 17).  Both runs use the identical recipe of every earlier
native_groupmix run - same teacher, data, augmentation, loss, optimizer, LR
schedule, batch size 4, 20k iterations / 80k samples - so that only the
generator topology differs, which is what the capacity comparison needs.

Ordering: the a/b/c campaign owns GPU1 until it is done, so this launcher first
waits for runs/v2c_spatialshift_20260921/COMPLETE.json and for every one of our
own train.py processes to exit, and only then starts V2-D and then V2-E.

GPU policy (project rule): always GPU1, selected explicitly with
CUDA_VISIBLE_DEVICES.  A non-project process on that GPU is expected and
allowed - the project rules permit sharing GPU1 - but another one of *our*
train.py processes is treated as an error, because that would slow both runs
and break comparability.  D and E run sequentially rather than in parallel for
the same reason: a single allowed GPU shared with a foreign job.
"""
import getpass
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from settings import HERE, SAMPLE_BUDGET, run_root

EXPERIMENTS = (
    "native_groupmix_v2d_narrowdeep_c16_fp32",
    "native_groupmix_v2e_factorizedshuffle_c32_fp32",
)
# The a/b/c campaign must finish first; it is the current owner of GPU1.
GATE_EXPERIMENT = "v2c_spatialshift"
GATE_KEYS = ("VGG_global_gradient_ratio", "VGG_patch_gradient_ratio")


def run(command, log):
    # Append rather than create: a campaign is expected to be retried after a
    # failure, and the previous attempt's log is evidence worth keeping.
    with Path(log).open("a") as stream:
        stream.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} "
                     f"{' '.join(map(str, command))}\n")
        result = subprocess.run(list(map(str, command)), stdin=subprocess.DEVNULL,
                                stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Failed ({result.returncode}): {log}")


def write_state(path, value):
    tmp = Path(path).with_name(Path(path).name + ".partial")
    tmp.write_text(json.dumps(value, indent=2), encoding="utf-8")
    tmp.replace(path)


def gpu_occupants(index):
    out = subprocess.check_output(
        ["nvidia-smi", "-i", str(index), "--query-compute-apps=pid,used_memory",
         "--format=csv,noheader"]).decode().strip()
    return [tuple(v.strip() for v in line.split(",")) for line in out.splitlines() if line]


def our_training_process():
    """Our own train.py command line, if one is running.  Other users' jobs are
    invisible here (they run in containers) and must never gate or be touched."""
    out = subprocess.run(["ps", "-u", getpass.getuser(), "-o", "args="],
                         capture_output=True).stdout.decode()
    for line in out.splitlines():
        line = line.strip()
        if "train.py" in line and "launch_v2" not in line:
            return line
    return None


def wait_for_gpu(log):
    """Wait until the a/b/c campaign has finished and released GPU1."""
    gate = run_root(GATE_EXPERIMENT) / "COMPLETE.json"
    reported = None
    while True:
        done = gate.is_file()
        mine = our_training_process()
        state = (done, bool(mine))
        if state != reported:
            with Path(log).open("a") as stream:
                stream.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} "
                             f"waiting: {GATE_EXPERIMENT} complete={done} "
                             f"own_train_running={mine or 'none'}\n")
            reported = state
        if done and not mine:
            return
        time.sleep(60)


def main():
    gpu_index = os.environ.get("TRAIN_GPU_INDEX", "1")
    os.environ["CUDA_VISIBLE_DEVICES"] = str(gpu_index)
    log = HERE / "launcher_v2de.log"
    state_path = HERE / "state_v2de.json"
    state = {"physical_gpu": gpu_index, "started": time.time(), "phase": "WAITING",
             "blocked_by": GATE_EXPERIMENT, "models": {}}
    write_state(state_path, state)

    wait_for_gpu(log)

    mine = our_training_process()
    if mine:
        raise RuntimeError(f"another of our trainings is running: {mine}")
    occupants = gpu_occupants(gpu_index)
    state.update(occupied_pids_at_start=occupants,
                 sharing_note=("GPU1 may host a non-project process; project rules "
                               "allow sharing that GPU. pid 0 entries are foreign "
                               "container processes we must not touch."))
    state["phase"] = "PREFLIGHT"
    write_state(state_path, state)

    for name in EXPERIMENTS:
        root = run_root(name)
        if (root / "COMPLETE.json").is_file():
            print(f"{name}: already complete at {root}, skipping", flush=True)
            state["models"][name] = {"run_dir": str(root), "skipped": True,
                                     "complete": json.loads((root / "COMPLETE.json").read_text())}
            write_state(state_path, state)
            continue
        if root.exists():
            raise FileExistsError(f"{name}: partial run dir exists, decide manually: {root}")
        preflight = HERE / f"preflight_{name}"
        if preflight.exists():
            shutil.rmtree(preflight)

        # Stage 1: 800-sample preflight with the VGG balance gate.
        run([sys.executable, "-u", HERE / "train.py", "--experiment", name,
             "--run-dir", preflight, "--sample-budget", "800", "--save-every", "200",
             "--diagnose-every", "25", "--smoke-test"], HERE / f"preflight_{name}.log")
        report = json.loads((preflight / "COMPLETE.json").read_text())
        if report["samples_seen"] != 800:
            raise RuntimeError(f"{name}: incomplete preflight")
        means = json.loads((preflight / "progress.json").read_text())["mean"]
        for key in GATE_KEYS:
            if not 0.10 <= means[key] <= 0.60:
                raise RuntimeError(f"{name}: VGG balance gate failed: {key}={means[key]}")
        state["models"][name] = {"preflight": {k: means[k] for k in GATE_KEYS},
                                 "run_dir": str(root)}
        state["phase"] = f"TRAINING:{name}"
        write_state(state_path, state)

        # Stage 2: the full 80k-sample run, identical recipe to every earlier run.
        run([sys.executable, "-u", HERE / "train.py", "--experiment", name,
             "--run-dir", root, "--sample-budget", str(SAMPLE_BUDGET),
             "--save-every", "1000", "--diagnose-every", "100"],
            HERE / f"train_{name}.log")
        state["models"][name]["complete"] = json.loads((root / "COMPLETE.json").read_text())
        write_state(state_path, state)

    state["phase"] = "COMPLETE"
    state["finished"] = time.time()
    write_state(state_path, state)


if __name__ == "__main__":
    main()
