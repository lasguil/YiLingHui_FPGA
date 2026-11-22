"""Formal runs reuse the verified trainer; save all G checkpoints, latest full state."""
import argparse,fcntl,json,os,random,shutil,sys,time,uuid
from collections import Counter
from pathlib import Path
import numpy as np
import torch
from settings import HERE,PREP,STUDENTS,METHOD,EXPERIMENTS,SAMPLE_BUDGET,batch_size,learning_rate,readiness,digest
sys.path.insert(0,str(PREP))
import common as base
from eval_images import save_both

def atomic_json(path,value):
    temporary=path.with_name(path.name+'.partial')
    temporary.write_text(json.dumps(value,indent=2),encoding='utf-8');temporary.replace(path)

def main(args):
    readiness();out=args.run_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    lock=(out/'.run.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    config_path=out/'config.json'
    if not args.resume and any(p.name!='.run.lock' for p in out.iterdir()):raise FileExistsError(out)
    coeff=base.weights()
    trainer,initial=base.create(args.experiment,coeff);samples=base.Samples(args.experiment)
    batch=batch_size(args.experiment)
    assert args.sample_budget>0 and args.sample_budget%batch==0
    assert args.save_every>0 and args.diagnose_every>0
    steps=args.sample_budget//batch
    deps={str(p):digest(p) for p in list(HERE.glob('*.py'))+list(PREP.glob('*.py'))}
    config={'experiment':args.experiment,'generator':type(trainer.generator).__name__,'parameters':sum(p.numel() for p in trainer.generator.parameters()),
            'initial_state_sha256':initial,'batch_size':batch,'gradient_accumulation':False,'sample_budget':args.sample_budget,'iterations':steps,
            'save_every':args.save_every,'keep_checkpoints':'all','test_images_per_checkpoint':8,'full_state':'latest only',
            'lr':.0002,'lr_schedule':'first 40000 of 80000 samples constant, remaining half linear decay; no warmup',
            'schedule_formula':'2e-4 * (1 - max(0,samples_before-budget/2)/(budget/2))',
            'precision':'FP32 CUDA; no AMP/TF32','seed':base.SEED,'weights':coeff,'cut_loss_config':trainer.config,
            'train_count':len(samples.schedule),'index_sha256':digest(base.INDEX),'dependencies':deps,'preflight_dir':str(PREP),
            'excluded_ids':[],
            'bn_caveat':'batch4, NativeGroupMixNet BN; one canonical forward updates running buffers, auxiliary CUT passes disable tracking without modifying buffers',
            'image_size':[256,256],
            'preprocessing':'content from main_256; local VGG target is an independent augmentation of single vangogh_00.jpg',
            'style_input_B':'single fixed vangogh_00.jpg source; independent augmentation from global S and local VGG target',
            'teacher_images_used':False,
            'smoke_test':args.smoke_test}
    config=json.loads(json.dumps(config))  # JSON round-trip normalizes tuple/list fields for resume.
    start=0;seen=Counter()
    if args.resume:
        old=json.loads(config_path.read_text());assert old==config,'Resume config/dependency mismatch'
        state=torch.load(out/'training_state_latest.pt',map_location='cpu',weights_only=False)
        assert state['config']==config
        trainer.load_state_dict(state['trainer']);start=trainer.steps
        samples.style_rng.setstate(state['style_rng']);samples.teacher_rng.setstate(state['teacher_rng'])
        random.setstate(state['python_rng']);np.random.set_state(state['numpy_rng']);seen.update(state['dataset_visits'])
        del state
    else:atomic_json(config_path,config)
    print(json.dumps(config),flush=True)
    began=time.monotonic();totals=Counter();count=0
    log=(out/'train.jsonl').open('a',buffering=1)
    def save(step):
        assert shutil.disk_usage(out).free>512*1024**2,'Less than 512MiB save headroom'
        trainer.validate_state(step)
        cpdir=out/'checkpoints';cpdir.mkdir(exist_ok=True)
        cp=cpdir/f'step_{step:06d}.pt'
        if not cp.exists():
            partial=cp.with_suffix('.pt.partial')
            torch.save({'model':trainer.generator.state_dict(),'step':step,'config':config},partial);partial.replace(cp)
        full={'config':config,'trainer':trainer.state_dict(),'style_rng':samples.style_rng.getstate(),
              'teacher_rng':samples.teacher_rng.getstate(),'python_rng':random.getstate(),'numpy_rng':np.random.get_state(),'dataset_visits':dict(seen)}
        partial=out/'training_state_latest.pt.partial';torch.save(full,partial);partial.replace(out/'training_state_latest.pt');del full
        images=out/'test_images';images.mkdir(exist_ok=True)
        final=images/f'step_{step:06d}'
        if not final.exists():
            staging=images/f'.step_{step:06d}_{uuid.uuid4().hex}.partial'
            save_both(trainer.generator,METHOD/'assets/eval_content.png',base.PROJECT/'tmp/IMG_20250712_073503.jpg',staging)
            staging.rename(final)
        trainer.validate_state(step)
        row={'checkpoint_step':step,'samples_seen':step*batch,'checkpoint':str(cp),'test_images':str(final)}
        log.write(json.dumps(row)+'\n');print(json.dumps(row),flush=True)
    try:
        # Repair only the last committed checkpoint's missing test-image set on resume.
        if args.resume and start:save(start)
        for step in range(start+1,steps+1):
            lr=learning_rate((step-1)*batch,args.sample_budget);trainer.set_lr(lr)
            a,b,t,s,records=samples.batch(step,batch)
            diagnose=step%args.diagnose_every==0
            parts=trainer.step(a,b,t,diagnose=diagnose,global_reference=s)
            assert all(np.isfinite(v) for v in parts.values())
            assert all(p.grad is None and not p.requires_grad for p in trainer.perceptual.parameters())
            seen.update(r['dataset'] for r in records)
            for key,value in parts.items():
                if not key.startswith('grad_'):totals[key]+=value
            count+=1
            if diagnose:
                row={'gradient_probe':step,**{k:v for k,v in parts.items() if k.startswith('grad_')}}
                log.write(json.dumps(row)+'\n');print(json.dumps(row),flush=True)
            del a,b,t,s
            if step%25==0 or step==steps:
                row={'step':step,'samples_seen':step*batch,'epoch_equivalent':step*batch/len(samples.schedule),
                     'lr':lr,'mean':{k:v/count for k,v in totals.items()},'dataset_visits':dict(seen),'seconds':time.monotonic()-began}
                log.write(json.dumps(row)+'\n');print(json.dumps(row),flush=True);totals.clear();count=0
                atomic_json(out/'progress.json',row)
            if step%args.save_every==0 or step==steps:save(step)
        expected=(steps+args.save_every-1)//args.save_every
        assert len(list((out/'checkpoints').glob('step_*.pt')))==expected
        assert len(list((out/'test_images').glob('step_*/*.png')))==expected*8
        atomic_json(out/'COMPLETE.json',{'step':steps,'samples_seen':steps*batch,'checkpoints':expected,'test_images':expected*8})
    finally:log.close()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--experiment',choices=EXPERIMENTS,required=True)
    p.add_argument('--run-dir',type=Path,required=True);p.add_argument('--sample-budget',type=int,default=SAMPLE_BUDGET)
    p.add_argument('--save-every',type=int,default=1000);p.add_argument('--diagnose-every',type=int,default=500)
    p.add_argument('--resume',action='store_true');p.add_argument('--smoke-test',action='store_true')
    main(p.parse_args())
