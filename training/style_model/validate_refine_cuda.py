"""Check halo reference detachment and satisfied-constraint gradients on CUDA."""
import json
import os
import torch
from refine_policy import anchored_halo_loss

assert os.environ['CUDA_VISIBLE_DEVICES'] == 'GPU-6eda14b8-7601-184f-9229-462a26a548b7'
assert torch.cuda.is_available()
torch.set_num_threads(4)
axis = torch.arange(64, device='cuda', dtype=torch.float32)
y, x = torch.meshgrid(axis, axis, indexing='ij')
spot = torch.exp(-((x-32)**2+(y-32)**2)/8)[None, None]
content = (0.1+0.8*spot).expand(1, 3, 64, 64).clone().requires_grad_()
teacher = content.detach().clone()
warm = torch.exp(-((x-32)**2+(y-32)**2)/100)[None, None]*0.2
teacher[:, 0:1] += warm
teacher[:, 1:2] += warm
teacher = teacher.clamp(0, 1).requires_grad_()
student = content.detach().clone().requires_grad_()
loss = anchored_halo_loss(student, content, teacher)
loss.backward()
assert loss.item() > 0 and torch.isfinite(student.grad).all() and student.grad.abs().sum() > 0
assert content.grad is None and teacher.grad is None
matched = teacher.detach().clone().requires_grad_()
matched_loss = anchored_halo_loss(matched, content, teacher)
matched_loss.backward()
assert matched_loss.item() < 1e-7 and matched.grad.abs().sum().item() == 0
flat = torch.full_like(content, 0.5).requires_grad_()
flat_loss = anchored_halo_loss(flat, flat.detach(), flat.detach())
flat_loss.backward()
assert flat_loss.item() == 0 and torch.isfinite(flat.grad).all()
print(json.dumps({'cuda_device': torch.cuda.get_device_name(),
                  'missing_warmth_loss': loss.item(), 'matched_loss': matched_loss.item(),
                  'flat_loss': flat_loss.item(), 'reference_gradients': 'none', 'passed': True}))
