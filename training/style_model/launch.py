"""Detached preflight then fresh 20k NativeGroupMixNet FP32 training."""
import fcntl,json,os,shutil,subprocess,sys,time
from pathlib import Path
from settings import HERE,METHOD,RUN_ROOT,readiness

def atomic(path,value):
    tmp=path.with_name(path.name+'.partial');tmp.write_text(json.dumps(value,indent=2));tmp.replace(path)

def run(command,log):
    with log.open('x') as stream:
        result=subprocess.run(list(map(str,command)),stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT)
    if result.returncode:raise RuntimeError(f'Failed ({result.returncode}): {log}')

def main():
    readiness()
    lock=(METHOD/'job.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    state_path=HERE/'state.json'
    if state_path.exists():raise FileExistsError('This experiment was already launched')
    if RUN_ROOT.exists():raise FileExistsError(RUN_ROOT)
    if shutil.disk_usage(HERE).free<2*1024**3:raise RuntimeError('Need at least 2 GiB free')
    gpu_index=os.environ.get('TRAIN_GPU_INDEX','1')
    occupied=subprocess.check_output(['nvidia-smi','-i',gpu_index,'--query-compute-apps=pid',
                                      '--format=csv,noheader']).decode().strip()
    allow_occupied=os.environ.get('ALLOW_OCCUPIED_GPU')=='1'
    if occupied and not allow_occupied:raise RuntimeError('GPU already occupied: '+occupied)
    state={'pid':os.getpid(),'run_dir':str(RUN_ROOT),'started':time.time(),
           'physical_gpu':gpu_index,'shared_gpu':bool(occupied),'occupied_pids_at_start':occupied.splitlines()}
    atomic(state_path,{**state,'phase':'PREFLIGHT'})
    preflight=HERE/'preflight_run'
    run([sys.executable,'-u',HERE/'train.py','--experiment','native_groupmix_v1','--run-dir',preflight,
         '--sample-budget','800','--save-every','200','--diagnose-every','25','--smoke-test'],HERE/'preflight.log')
    report=json.loads((preflight/'COMPLETE.json').read_text())
    if report['samples_seen']!=800:raise RuntimeError('Incomplete preflight')
    progress=json.loads((preflight/'progress.json').read_text())
    means=progress['mean']
    for key in ('VGG_global_gradient_ratio','VGG_patch_gradient_ratio'):
        if not .10<=means[key]<=.60:raise RuntimeError(f'VGG balance gate failed: {key}={means[key]}')
    atomic(state_path,{**state,'phase':'TRAINING','preflight_gradient_ratios':{
        k:means[k] for k in ('VGG_global_gradient_ratio','VGG_patch_gradient_ratio')}})
    run([sys.executable,'-u',HERE/'train.py','--experiment','native_groupmix_v1','--run-dir',RUN_ROOT,
         '--sample-budget','80000','--save-every','1000','--diagnose-every','100'],HERE/'train.log')
    complete=json.loads((RUN_ROOT/'COMPLETE.json').read_text())
    atomic(state_path,{**state,'phase':'COMPLETE','finished':time.time(),'result':complete})

if __name__=='__main__':main()
