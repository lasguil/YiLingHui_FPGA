"""Training-only refinement policy. Deployment topology is unchanged."""
import json
import os
from types import MethodType

import torch
import torch.nn.functional as F

from distill_texture import blur


def anchored_halo_loss(student, content, teacher, target=0.048,
                       sigma_ring=4.0, sigma_back=12.0,
                       bright_fraction=0.01):
    """A one-sided warm-contrast floor at detached content highlights.

    The teacher sets a per-image target capped by target. Broad bright skies
    have no supervision unless they also contain a local highlight. This is
    warm local contrast, not a constraint on circular stroke orientation.
    """
    def warm(image):
        return (image[:, 0:1] + image[:, 1:2]) / 2 - image[:, 2:3]

    with torch.no_grad():
        content = content.detach()
        teacher = teacher.detach()
        luma = (content * content.new_tensor([0.299, 0.587, 0.114])
                .view(1, 3, 1, 1)).sum(1, keepdim=True)
        threshold = torch.quantile(luma.flatten(1), 1-bright_fraction, dim=1)
        local_contrast = blur(luma, 1.0) - blur(luma, sigma_back)
        mask = (torch.sigmoid((luma-threshold[:, None, None, None])/0.005)
                * (local_contrast > 0.03).to(luma.dtype))
        denominator = mask.sum((1, 2, 3))
        valid = (denominator >= 1).to(luma.dtype)
        teacher_ring = blur(warm(teacher), sigma_ring) - blur(warm(teacher), sigma_back)
        floor = ((teacher_ring*mask).sum((1, 2, 3)) /
                 denominator.clamp_min(1)).clamp(min=0, max=target)
    ring = blur(warm(student), sigma_ring) - blur(warm(student), sigma_back)
    score = (ring*mask).sum((1, 2, 3)) / denominator.clamp_min(1)
    return (F.relu(floor-score)*valid).sum() / valid.sum().clamp_min(1)


def gradient_rms_or_zero(loss, parameters):
    """Satisfied one-sided constraints legitimately have zero gradient."""
    grads = torch.autograd.grad(loss, parameters, retain_graph=True, allow_unused=True)
    total = loss.new_zeros(())
    for grad in grads:
        if grad is not None:
            total = total + grad.square().sum()
    rms = (total/sum(p.numel() for p in parameters)).sqrt().detach()
    if not torch.isfinite(rms):
        raise ValueError("Non-finite halo gradient")
    return rms


def configure_refinement(trainer, args):
    policy = json.loads(args.refine_policy.read_text(encoding="utf-8"))
    if args.nce_a_scale != policy["nce_a_scale"] or args.nce_y_scale != policy["nce_y_scale"]:
        raise ValueError("Content preservation weights must match the policy")
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required")
    expected = "GPU-6eda14b8-7601-184f-9229-462a26a548b7"
    if os.environ.get("CUDA_VISIBLE_DEVICES") != expected:
        raise RuntimeError("This experiment must use the verified physical GPU1 UUID")
    trainer.refine_gan_weight = float(policy["gan_weight"])
    trainer.weights = tuple(policy["fixed_vgg_weights"])
    trainer._balance_vgg = MethodType(lambda self, *unused: self.weights, trainer)
    original_set_lr = trainer.set_lr

    def set_lr(self, lr):
        original_set_lr(lr)
        for group in self.optimizers["D"].param_groups:
            group["lr"] = float(lr)*policy["discriminator_lr_scale"]
    trainer.set_lr = MethodType(set_lr, trainer)
    trainer.dreamsim_global_scale, trainer.dreamsim_patch_scale = policy["fixed_dreamsim_weights"]
    trainer._dreamsim_calibration_count = trainer.dreamsim_calibration_steps
    trainer.dreamsim_rescale_step = 0
    trainer.config.update(refinement=policy,
                          perceptual_weights="fixed_baseline_6000_7000_median",
                          teacher_images_used=True,
                          global_reference="paired_AesPA_output",
                          paired_local_target="paired_AesPA_output",
                          colour_calibration_reference="fixed_perceptual_plus_NCE_excluding_GAN",
                          halo_reference="detached_content_highlights_with_capped_AesPA_floor")
    print(json.dumps({"refinement": policy, "physical_gpu": expected,
                      "logical_cuda_device": torch.cuda.current_device()}), flush=True)
