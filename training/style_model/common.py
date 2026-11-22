"""Explicit experiment policies; no writes to the baseline or source dataset."""
import hashlib,json,random,sys
from pathlib import Path
import numpy as np
from PIL import Image
import torch

HERE=Path(__file__).resolve().parent
METHOD=HERE.parent;STUDENTS=METHOD.parent;PROJECT=STUDENTS.parents[1]
BASE=METHOD/'quarter_vgg_local_20260904'
sys.path.insert(0,str(METHOD));sys.path.insert(0,str(STUDENTS))
from pair_style_sweep.experiment import image_rgb,transform_pair,setup_gpu,PairedJohnsonLoss
from edgestyle_v6_sweep.train import load_style
from style_sampling import sample_style
from model import NativeGroupMixNet
from model_v2 import MODEL_CONFIGS, MODEL_FINGERPRINTS, build_v2
from model_v2de import EXPERIMENTS as V2DE_EXPERIMENTS
from model_v2de import MODEL_FINGERPRINTS as V2DE_FINGERPRINTS
from model_v2de import STAGE_CHANNELS as V2DE_STAGE_CHANNELS
from model_v2de import build_v2de
from perceptual import Perceptual
from adversarial import NCE_CHANNELS, CUTTrainer, V1_FINGERPRINT
from adversarial import CUTTrainer

DATASET=Path('/data1/fpga_style_transfer_2026_tmp/datasets/main_256')
INDEX=DATASET/'manifest.jsonl'
VGG19=BASE/'vgg19_imagenet_features.pt'
STYLE=DATASET.parent/'vangogh_styles/vangogh_00.jpg'
SEED=20260903

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x',encoding='utf-8') as f:json.dump(value,f,indent=2,ensure_ascii=False)
def seed():
    setup_gpu();random.seed(SEED);np.random.seed(SEED)
    torch.backends.cudnn.benchmark=False
def weights():return [140.14121616822274,84.82961500342705]
def create(experiment,coeff,**trainer_kwargs):
    seed()
    nce_channels=None
    if experiment=='native_groupmix_v1':
        model=NativeGroupMixNet().cuda()
    elif experiment in MODEL_CONFIGS:
        # Same trainer, same loss, same everything else: only the generator
        # topology changes, so the three v2 runs stay comparable.  Re-seeding
        # right after the model is built keeps the auxiliary networks (D and
        # the five projection heads) on an identical initialisation for all
        # three, which the different layer counts would otherwise derail.
        model=build_v2(experiment).cuda()
        seed()
    elif experiment in V2DE_EXPERIMENTS:
        # V2-D/V2-E: same recipe again, only the topology differs.  V2-D's H/4
        # trunk is C16, so its PatchNCE projection input follows the generator;
        # V2-E keeps the v1.1 layout and therefore passes None (unchanged path).
        key=V2DE_EXPERIMENTS[experiment]
        model=build_v2de(key).cuda()
        if tuple(V2DE_STAGE_CHANNELS[key])!=NCE_CHANNELS:
            nce_channels=V2DE_STAGE_CHANNELS[key]
        seed()
    else:
        raise ValueError(experiment)
    initial=hashlib.sha256(b''.join(v.detach().cpu().numpy().tobytes() for v in model.state_dict().values())).hexdigest()
    # Preserve the baseline auxiliary-network initialization RNG sequence.
    legacy=PairedJohnsonLoss(METHOD/'assets/vgg16_author_features.pt',load_style(STYLE,256)).cuda()
    del legacy
    perceptual=Perceptual(VGG19).cuda().eval()
    if experiment=='native_groupmix_v1':
        expected=V1_FINGERPRINT
    elif experiment in V2DE_EXPERIMENTS:
        expected=V2DE_FINGERPRINTS[V2DE_EXPERIMENTS[experiment]]
    else:
        expected=MODEL_FINGERPRINTS[experiment]
    trainer=CUTTrainer(model,perceptual=perceptual,weights=coeff,expected=expected,
                       nce_channels=nce_channels,**trainer_kwargs)
    trainer.config.update(experiment=experiment,global_reference='single_vangogh_00_resize_crop',
                          source_resolution='main_256',
                          native_small_policy='not applicable; dataset is preprocessed 256x256',
                          paired_local_target='single_vangogh_00_resize_crop',
                          teacher_images_used=False,
                          vgg_balance_reason='old starry run decayed to about 0.2 percent of GAN gradient per VGG term late in training')
    return trainer,initial

class Samples:
    def __init__(self,experiment):
        self.experiment=experiment
        self.rows=[json.loads(line) for line in INDEX.read_text(encoding='utf-8').splitlines() if line.strip()]
        self.style_rng=random.Random(SEED+777)
        self.teacher_rng=random.Random(SEED+888)
        self.star=image_rgb(STYLE)
        self.schedule=list(range(len(self.rows)))
    def batch(self,step,batch_size):
        records=[];aa=[];bb=[];tt=[];ss=[]
        for j in range(batch_size):
            i=self.schedule[((step-1)*batch_size+j)%len(self.schedule)];r=self.rows[i]
            a=image_rgb(DATASET/r['file'])
            assert a.size==(256,256),r
            x=torch.from_numpy(np.array(a,dtype=np.float32)/255.).permute(2,0,1).contiguous()
            b,meta=sample_style(self.star,rng=self.teacher_rng)
            p,_=sample_style(self.star,rng=self.teacher_rng)
            s,_=sample_style(self.star,rng=self.style_rng)
            aa.append(x);tt.append(p);bb.append(b);ss.append(s)
            records.append({'id':r['id'],'dataset':'main_256','source':r['source'],'native_size':r.get('original_size',[256,256]),
                            'input_size':[256,256],'style_source':'vangogh_00.jpg',
                            'style_branch':meta['branch'],'teacher_image_used':False})
        tensors=[torch.stack(v).cuda() for v in (aa,bb,tt)]
        return (*tensors,torch.stack(ss).cuda(),records)
