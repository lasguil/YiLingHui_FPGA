"""Frozen standard ImageNet VGG19; explicit Gram means, paired RGB crops."""
import hashlib
from pathlib import Path
import torch
from torch import nn
from torch.nn import functional as F
from torchvision.models.vgg import make_layers,cfgs

class Perceptual(nn.Module):
    indices=(1,6,11,20)  # relu1_1, relu2_1, relu3_1, relu4_1
    def __init__(self,path):
        super().__init__()
        self.file_sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest()
        payload=torch.load(path,map_location='cpu',weights_only=True)
        assert payload['source_sha256'].startswith('dcbb9e9d')
        self.source_sha256=payload['source_sha256']
        # Loss construction must not perturb G/D/F initialization or patch RNG.
        with torch.random.fork_rng(devices=[]):
            self.features=make_layers(cfgs['E'])[:21]
        self.features.load_state_dict(payload['state_dict'],strict=True)
        for layer in self.features:
            if isinstance(layer,nn.ReLU):layer.inplace=False
        self.features.requires_grad_(False).eval()
        self.register_buffer('mean',torch.tensor([.485,.456,.406])[None,:,None,None])
        self.register_buffer('std',torch.tensor([.229,.224,.225])[None,:,None,None])
        self.config={'source':'torchvision VGG19 IMAGENET1K_V1','source_sha256':self.source_sha256,
          'file_sha256':self.file_sha256,'global_layers':['relu1_1','relu2_1','relu3_1','relu4_1'],
          'patch_layers':['relu2_1','relu3_1'],'gram':'F F^T / (C H W); MSE mean; layer mean',
          'patch_sizes':[64,128],'patches_per_size_per_image':2,'patches':'same coordinates y/paired teacher; RGB crop before VGG; no resize',
          'normalization':'RGB01 -> (x-ImageNet_mean)/ImageNet_std once; no clamp',
          'content_loss':0,'pixel_l1':0,'tv':0,'trainable':False}
    def extract(self,x,last=20):
        if x.device.type!='cuda':raise RuntimeError('CUDA-only VGG forward')
        x=(x-self.mean)/self.std
        result=[]
        for i,layer in enumerate(self.features):
            x=layer(x)
            if i in self.indices:result.append(x)
            if i==last:break
        return result
    @staticmethod
    def gram(x):
        b,c,h,w=x.shape;f=x.flatten(2)
        return torch.bmm(f,f.transpose(1,2))/(c*h*w)
    def global_loss(self,y,s,return_features=False):
        yp=self.extract(y)
        with torch.no_grad():sp=self.extract(s)
        loss=torch.stack([F.mse_loss(self.gram(a),self.gram(b)) for a,b in zip(yp,sp)]).mean()
        # The caller may also be a VGG judgement that needs these features, in which
        # case one forward serves both instead of two.
        return (loss, yp) if return_features else loss
    @staticmethod
    def paired_patches(y,t,size,rng):
        assert y.shape==t.shape
        b,_,h,w=y.shape;left=torch.randint(w-size+1,(b,2),generator=rng)
        top=torch.randint(h-size+1,(b,2),generator=rng)
        def cut(x):
            return torch.stack([x[i,:,int(top[i,j]):int(top[i,j])+size,int(left[i,j]):int(left[i,j])+size]
                                for i in range(b) for j in range(2)])
        return cut(y),cut(t)
    def patch_loss(self,y,t,rng):
        terms=[]
        for size in (64,128):
            a,b=self.paired_patches(y,t,size,rng)
            ap=self.extract(a,last=11)[1:]
            with torch.no_grad():bp=self.extract(b,last=11)[1:]
            terms.extend(F.mse_loss(self.gram(p),self.gram(q)) for p,q in zip(ap,bp))
        return torch.stack(terms).mean()

def gradient_rms(loss,parameters):
    grads=torch.autograd.grad(loss,parameters,retain_graph=True,allow_unused=True)
    total=sum(g.square().sum() for g in grads if g is not None)
    n=sum(p.numel() for p in parameters)
    result=(total/n).sqrt()
    assert torch.isfinite(result) and result>1e-16,('Missing/near-zero gradient',result)
    return result.detach()
