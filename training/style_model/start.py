"""Start launch.py detached from SSH."""
import subprocess,sys,time
from settings import HERE

with (HERE/'launcher.log').open('x') as log:
    child=subprocess.Popen([sys.executable,'-u',str(HERE/'launch.py')],stdin=subprocess.DEVNULL,
                           stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
time.sleep(2)
if child.poll() is not None:raise RuntimeError('Launcher exited; inspect launcher.log')
print(f'pid={child.pid} log={HERE/"launcher.log"}')

