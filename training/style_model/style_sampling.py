"""Target-domain-only augmentation. Content and test preprocessing stay unchanged."""
import random
import numpy as np
from PIL import Image
import torch

POLICY={'full_resize_probability':0.5,'crop_probability':0.5,'output_size':[256,256],
        'crop_short_side':'uniform integer 256..min(512,native short side); if native<256 resize to 256',
        'interpolation':'PIL BILINEAR','aspect_ratio':'preserved in crop branch',
        'alignment':'top-left trim to multiples of 16 before either branch',
        'sampling':'independent unpaired target image; random per visit; no flips or color augmentation'}

def sample_style(image,rng=random,branch=None):
    image=image.convert('RGB');w,h=image.size
    if min(w,h)<16:raise ValueError('Style-domain sample smaller than 16 pixels')
    image=image.crop((0,0,w-w%16,h-h%16));w,h=image.size
    branch=('resize' if rng.random()<.5 else 'crop') if branch is None else branch
    if branch=='resize':
        out=image.resize((256,256),Image.Resampling.BILINEAR)
        sw,sh=256,256;left,top=0,0
    elif branch=='crop':
        side=rng.randint(256,max(256,min(512,w,h)))
        scale=side/min(w,h)
        sw,sh=max(256,round(w*scale)),max(256,round(h*scale))
        scaled=image.resize((sw,sh),Image.Resampling.BILINEAR)
        left,top=rng.randint(0,sw-256),rng.randint(0,sh-256)
        out=scaled.crop((left,top,left+256,top+256))
    else:raise ValueError(branch)
    meta={'branch':branch,'native_short':min(w,h),'resized_width':sw,'resized_height':sh,
          'crop_left':left,'crop_top':top,'upsampled':min(w,h)<256}
    array=np.array(out,dtype=np.float32)/255.
    tensor=torch.from_numpy(array).permute(2,0,1).contiguous()
    return tensor,meta
