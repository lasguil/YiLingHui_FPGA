"""Detached preflight then fresh 20k-iteration training for the three v2 models.

All three runs use the identical recipe of runs/native_groupmix_main256_20260910_20k
(batch 4, 20k iterations / 80k samples, lr 2e-4 with the half-budget linear
decay, the same CUT loss configuration), so the only difference between them is
the generator topology - which is what the comparison needs.

GPU policy (project rule): always GPU1, selected explicitly with
CUDA_VISIBLE_DEVICES, and the run refuses to start if that GPU already has a
compute process unless ALLOW_OCCUPIED_GPU=1.
"""
import json, os, shutil, subprocess, sys, time
from pathlib import Path

from settings import HERE, SAMPLE_BUDGET, run_root

V2 = ("v2a_depthcut", "v2b_groupcut", "v2c_spatialshift")
GATE_KEYS = ("VGG_global_gradient_ratio", "VGG_patch_gradient_ratio")


def run(command, log):
    # Append rather than create: a three-run campaign is expected to be retried
    # after a failure, and the previous attempt's log is evidence worth keeping.
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


def gpu_processes(index):
    return subprocess.check_output(["nvidia-smi", "-i", str(index),
                                    "--query-compute-apps=pid",
                                    "--format=csv,noheader"]).decode().strip()


def main():
    gpu_index = os.environ.get("TRAIN_GPU_INDEX", "1")
    occupied = gpu_processes(gpu_index)
    if occupied and os.environ.get("ALLOW_OCCUPIED_GPU") != "1":
        raise RuntimeError(f"GPU {gpu_index} already occupied: {occupied}")
    os.environ["CUDA_VISIBLE_DEVICES"] = str(gpu_index)
    state_path = HERE / "state_v2.json"
    state = {"physical_gpu": gpu_index, "occupied_pids_at_start": occupied.splitlines(),
             "started": time.time(), "phase": "PREFLIGHT", "models": {}}
    write_state(state_path, state)

    for name in V2:
        root = run_root(name)
        if (root / "COMPLETE.json").is_file():
            # Already trained in an earlier attempt: keep it, do not redo it.
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

        # Stage 2: the full 80k-sample run, identical recipe to the reference.
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
