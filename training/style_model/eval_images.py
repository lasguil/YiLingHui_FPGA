"""Both fixed test inputs, four sizes each; never update trained BN buffers."""
import numpy as np
import torch
from PIL import Image,ImageOps

@torch.inference_mode()
def save_both(model,original_source,extra_source,directory):
    was_training=model.training;model.eval()
    before={k:v.clone() for k,v in model.named_buffers()}
    directory.mkdir(parents=True,exist_ok=True)
    expected=[]
    try:
        for source,prefix in ((original_source,'output'),(extra_source,'IMG_20250712_073503_output')):
            with Image.open(source) as im:image=ImageOps.exif_transpose(im).convert('RGB')
            for w,h in ((256,256),(854,480),(1280,720),(1920,1080)):
                content=ImageOps.fit(image,(w,h),method=Image.Resampling.BILINEAR)
                x=torch.from_numpy(np.array(content,dtype=np.float32)/255.).permute(2,0,1).unsqueeze(0).cuda()
                y=model(x)
                assert y.shape==x.shape and torch.isfinite(y).all() and y.min()>=0 and y.max()<=1
                result=Image.fromarray((y[0].permute(1,2,0).cpu().numpy()*255+.5).astype(np.uint8))
                path=directory/f'{prefix}_{w}x{h}.png'
                with path.open('xb') as f:result.save(f,format='PNG')
                with Image.open(path) as check:assert check.size==(w,h);check.verify()
                expected.append(path.name)
                del x,y
        assert len(expected)==8
        assert all(torch.equal(v,dict(model.named_buffers())[k]) for k,v in before.items())
    finally:model.train(was_training)
