"""Start launch_v2.py detached from the SSH session."""
import os, subprocess, sys, time
from pathlib import Path

from settings import HERE

# Explicit device selection: the three v2 runs train on GPU1 only.
os.environ.setdefault("TRAIN_GPU_INDEX", "1")
os.environ["CUDA_VISIBLE_DEVICES"] = os.environ["TRAIN_GPU_INDEX"]

# Append rather than create: a retried launch must not lose the earlier log.
with (HERE / "launcher_v2.log").open("a") as log:
    log.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} start_v2 "
              f"gpu={os.environ['TRAIN_GPU_INDEX']} cwd={HERE}\n")
    log.flush()
    child = subprocess.Popen([sys.executable, "-u", str(HERE / "launch_v2.py")],
                             stdin=subprocess.DEVNULL, stdout=log,
                             stderr=subprocess.STDOUT, start_new_session=True,
                             cwd=str(HERE), env=os.environ.copy())
time.sleep(2)
if child.poll() is not None:
    raise RuntimeError("Launcher exited; inspect launcher_v2.log")
print(f"pid={child.pid} gpu={os.environ['TRAIN_GPU_INDEX']} log={HERE/'launcher_v2.log'}")
