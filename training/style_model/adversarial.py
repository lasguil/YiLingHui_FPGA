"""NativeGroupMixNet FP32 CUT trainer; G/D/data/BN policy follows the baseline."""
from __future__ import annotations

from contextlib import contextmanager
from copy import deepcopy
import json
import math
from pathlib import Path
import random
import sys

import torch
from torch import nn
from torch.nn import functional as F

_STUDENTS = str(Path(__file__).resolve().parents[2])
_METHOD = str(Path(__file__).resolve().parents[1])
if _METHOD not in sys.path:
    sys.path.insert(0, _METHOD)
if _STUDENTS not in sys.path:
    sys.path.insert(0, _STUDENTS)
_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from model import NativeGroupMixNet
from model_v2 import model_fingerprint
from edgestyle_v5 import assert_bn_state
from distill_texture import (FLAT_SHRINK, FLAT_SIGMA, LOCAL_GRAM_LAYER, SWD_LAYERS,
                             TextureDescriptor,
                             broadbandness_loss,
                             chroma_loss, coherence_loss,
                             colour_distribution_loss, energy_scale_loss,
                             band_contrast_loss, flat_content_loss, flat_probe,
                             spectral_shape_loss,
                             low_frequency_loss, halo_loss,
                             orientation_flow_loss,
                             repetition_loss, sliced_wasserstein_style_loss,
                             stroke_contrast_loss, style_directions,
                             judge_loss, local_gram_descriptors,
                             local_gram_distance,
                             local_gram_teacher_loss,
                             texture_stat_loss, to_luma_image)

# Distillation objectives.  "tex" is the phase-tolerant texture family described
# in distill_texture.py; the other three are kept so earlier runs stay exactly
# reproducible.
DISTILL_MODES = ("rgb", "haar_hf", "hf_rel", "tex")
# Stage pairing for the Body relation term, by (student, teacher) body counts.
BODY_PAIRINGS = {(2, 4): ((0, 1), (1, 3)), (4, 4): ((0, 0), (1, 1), (2, 2), (3, 3))}


# (BatchNorm2d count, reflect-padded conv count, parameter count) of the v1.1
# reference generator; the architecture gate below defaults to it.
V1_FINGERPRINT = (14, 7, 19255)


NCE_STAGES = ("stem", "enc", "down", "body", "reduce")
NCE_CHANNELS = (16, 16, 32, 32, 16)
NCE_GLOBAL_WEIGHT = 0.5
NCE_LAYER_WEIGHTS = (1., 1., 1., 1., 1.)


def aggregate_nce(losses):
    """Keep denominator five: never renormalize away the reduced weights."""
    values = torch.stack(losses)
    if values.shape != (5,):
        raise ValueError("Expected five scalar PatchNCE losses")
    return (values * values.new_tensor(NCE_LAYER_WEIGHTS)).sum() / 5



@contextmanager
def running_stats(generator):
    """Forward with the running BN statistics, without touching any buffer.

    The flat probe exists to fix what the *deployed* generator does on
    near-constant content, and the deployed generator uses running statistics.
    Running it in training mode instead normalises by the flat batch's own tiny
    variance, which amplifies faint structure inside that pass and satisfies the
    contrast floor for free: measuring a batch of wall crops in training mode
    inflated their stroke contrast 4.6x, so the term would look met without the
    model having changed at inference.
    """
    norms = [m for m in generator.modules() if isinstance(m, nn.BatchNorm2d)]
    if not generator.training or any(not m.training for m in norms):
        raise RuntimeError("The running-stats pass requires training-mode BN")
    try:
        for m in norms:
            m.eval()
        yield
    finally:
        for m in norms:
            m.train(True)


@contextmanager
def auxiliary_batch_stats(generator):
    """Use current batch statistics, without touching ANY persistent BN buffer."""
    norms = [m for m in generator.modules() if isinstance(m, nn.BatchNorm2d)]
    if not generator.training or any(not m.training for m in norms):
        raise RuntimeError("Auxiliary passes require training-mode BN")
    previous = [m.track_running_stats for m in norms]
    try:
        for m in norms:
            m.track_running_stats = False
        yield
    finally:
        for m, tracking in zip(norms, previous):
            m.track_running_stats = tracking


def encoder_features(generator, image):
    """Model-specific encoder, with alignment and stages defined by the model."""
    return generator.cut_features(image)


def _normal_init(module):
    if isinstance(module, (nn.Conv2d, nn.Linear)):
        nn.init.normal_(module.weight, 0.0, 0.02)
        if module.bias is not None:
            nn.init.zeros_(module.bias)
    elif isinstance(module, nn.BatchNorm2d):
        nn.init.normal_(module.weight, 1.0, 0.02)
        nn.init.zeros_(module.bias)


class _BlurDownsample(nn.Module):
    """Official CUT default: reflected 3x3 binomial blur and stride two."""
    def __init__(self, channels):
        super().__init__()
        coeff = torch.tensor([1., 2., 1.])
        kernel = (coeff[:, None] * coeff[None, :]) / 16.
        self.register_buffer("kernel", kernel[None, None].repeat(channels, 1, 1, 1))

    def forward(self, x):
        return F.conv2d(F.pad(x, (1, 1, 1, 1), mode="reflect"),
                        self.kernel, stride=2, groups=x.shape[1])


class _PatchDiscriminator(nn.Module):
    def __init__(self, antialias=False):
        super().__init__()
        layers = []
        previous = 3
        for i, channels in enumerate((64, 128, 256)):
            layers.append(nn.Conv2d(previous, channels, 4,
                                    stride=1 if antialias else 2, padding=1))
            if i:
                layers.append(nn.InstanceNorm2d(channels, affine=False,
                                               track_running_stats=False))
            layers.append(nn.LeakyReLU(0.2, inplace=False))
            if antialias:
                layers.append(_BlurDownsample(channels))
            previous = channels
        layers.extend([nn.Conv2d(256, 512, 4, padding=1),
                       nn.InstanceNorm2d(512, affine=False, track_running_stats=False),
                       nn.LeakyReLU(0.2, inplace=False), nn.Conv2d(512, 1, 4, padding=1)])
        self.model = nn.Sequential(*layers)
        self.apply(_normal_init)

    def forward(self, rgb01):
        return self.model(rgb01 * 2.0 - 1.0)


class _PatchProjection(nn.Module):
    def __init__(self, channels=NCE_CHANNELS):
        super().__init__()
        self.channels = tuple(int(c) for c in channels)
        if len(self.channels) != len(NCE_STAGES):
            raise ValueError(f"expected {len(NCE_STAGES)} stages, got {self.channels}")
        self.mlps = nn.ModuleList(nn.Sequential(nn.Linear(c, 256), nn.ReLU(),
                                               nn.Linear(256, 256)) for c in self.channels)
        self.apply(_normal_init)

    def forward(self, features, ids=None):
        if len(features) != len(self.mlps):
            raise ValueError("Expected all five v6 feature stages")
        projected, selected = [], []
        for i, (feature, mlp) in enumerate(zip(features, self.mlps)):
            batch, channels, height, width = feature.shape
            if channels != self.channels[i]:
                raise ValueError(f"Wrong channel count for {NCE_STAGES[i]}")
            index = (torch.randperm(height * width, device=feature.device)[:256]
                     if ids is None else ids[i])
            patches = feature.flatten(2).transpose(1, 2)[:, index, :]
            z = mlp(patches.reshape(-1, channels))
            z = z / (z.norm(p=2, dim=1, keepdim=True) + 1e-7)
            projected.append(z.reshape(batch, index.numel(), 256))
            selected.append(index)
        return projected, selected


def patch_nce(query, key, temperature=0.07):
    """BxPxC features: one positive, P-1 valid negatives, no cross-image pairs."""
    if query.shape != key.shape or query.ndim != 3:
        raise ValueError("PatchNCE expects matching BxPxC tensors")
    key = key.detach()  # stop gradient through encoder AND key-side projection
    positive = (query * key).sum(dim=-1, keepdim=True)
    negative = torch.bmm(query, key.transpose(1, 2))
    mask = torch.eye(query.shape[1], device=query.device, dtype=torch.bool)[None]
    negative = negative.masked_fill(mask, -10.0)  # official diagonal sentinel
    logits = torch.cat((positive, negative), dim=-1) / temperature
    return F.cross_entropy(logits.flatten(0, 1),
                           torch.zeros(query.shape[0] * query.shape[1],
                                       device=query.device, dtype=torch.long))


class _ReplayPool:
    def __init__(self, size=50):
        self.size = size
        self.images = []
        self.rng = random.Random(random.getrandbits(64))

    def query(self, images):
        chosen = []
        for image in images.detach().split(1):
            # Clone each image; never retain a whole batch allocation or a graph.
            if len(self.images) < self.size:
                self.images.append(image.clone())
                chosen.append(image)
            elif self.rng.random() > 0.5:
                index = self.rng.randrange(self.size)
                chosen.append(self.images[index])
                self.images[index] = image.clone()
            else:
                chosen.append(image)
        return torch.cat(chosen, dim=0)

    def state_dict(self):
        return {"size": self.size, "images": self.images, "rng": self.rng.getstate()}

    def load_state_dict(self, state, device):
        if state["size"] != self.size or len(state["images"]) > self.size:
            raise ValueError("Incompatible replay pool")
        self.images = [x.detach().to(device).clone() for x in state["images"]]
        self.rng.setstate(state["rng"])


def _cpu_snapshot(value):
    if isinstance(value, torch.Tensor):
        return value.detach().cpu().clone()
    if isinstance(value, dict):
        return {key: _cpu_snapshot(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return type(value)(_cpu_snapshot(item) for item in value)
    return deepcopy(value)


def _finite(tensors, label):
    flags = [torch.isfinite(t.detach()).all() for t in tensors]
    # Optimizer scalar steps can live on CPU while its moments live on CUDA.
    by_device = {}
    for flag in flags:
        by_device.setdefault(flag.device, []).append(flag)
    if any(not bool(torch.stack(group).all()) for group in by_device.values()):
        raise FloatingPointError(f"Non-finite {label}")


def _median(values):
    values = sorted(float(v) for v in values)
    n = len(values)
    if not n:
        return 0.0
    return values[n // 2] if n % 2 else 0.5 * (values[n // 2 - 1] + values[n // 2])


def _backward(loss):
    _finite([loss], "loss")
    loss.backward()


def _optimizer_step(optimizer):
    params = [p for group in optimizer.param_groups for p in group["params"]]
    if any(p.grad is None for p in params):
        raise RuntimeError("Missing gradient in an active optimizer")
    _finite([p.grad for p in params], "gradient")
    optimizer.step()


def _numbers(parts):
    names = list(parts)
    values = [float(value.detach()) if torch.is_tensor(value)
              else float(value) for value in parts.values()]
    if not all(math.isfinite(value) for value in values):
        raise FloatingPointError("Non-finite metric")
    return dict(zip(names, values))


def _haar2d(x):
    """Return one-level orthonormal-ish 2-D Haar low/high components.

    The training images are multiples of four, so two successive levels are
    well-defined.  Keeping this as tensor slicing, instead of a convolution,
    makes the loss deterministic and introduces no trainable parameters.
    """
    height, width = x.shape[-2:]
    if height % 2 or width % 2:
        raise ValueError(f"Haar loss expects even spatial sizes, got {height}x{width}")
    a = x[..., 0::2, 0::2]
    b = x[..., 0::2, 1::2]
    c = x[..., 1::2, 0::2]
    d = x[..., 1::2, 1::2]
    scale = 0.5
    ll = (a + b + c + d) * scale
    lh = (a - b + c - d) * scale
    hl = (a + b - c - d) * scale
    hh = (a - b - c + d) * scale
    return ll, (lh, hl, hh)


def haar_high_frequency_loss(student, teacher):
    """Match two levels of output high-frequency structure only.

    This deliberately excludes the LL bands and therefore does not become a
    second full-RGB teacher loss.  Charbonnier is used because a tiny student
    cannot reproduce every individual teacher edge exactly.
    """
    student_ll1, student_hf1 = _haar2d(student)
    teacher_ll1, teacher_hf1 = _haar2d(teacher)
    student_ll2, student_hf2 = _haar2d(student_ll1)
    teacher_ll2, teacher_hf2 = _haar2d(teacher_ll1)

    def band_distance(student_bands, teacher_bands):
        distances = [torch.sqrt((s - t).square() + 1e-6).mean()
                     for s, t in zip(student_bands, teacher_bands)]
        return torch.stack(distances).mean()

    return band_distance(student_hf1, teacher_hf1) + 0.5 * band_distance(
        student_hf2, teacher_hf2)


def _channel_relation(feature):
    """Return a spatially normalized C x C channel-relation matrix."""
    batch, channels, height, width = feature.shape
    values = feature.reshape(batch, channels, height * width)
    values = values - values.mean(dim=2, keepdim=True)
    values = torch.nn.functional.normalize(values, dim=2, eps=1e-6)
    return torch.bmm(values, values.transpose(1, 2))


def body_relation_loss(student_stages, teacher_stages, pairing=None):
    """Distill Body channel relations, aligned to the documented stage pairs.

    V2B exposes two Body outputs while the V1 teacher exposes four, so that
    pairing maps V2B Body0 <- V1 Body1 and V2B Body1 <- V1 Body3.  V2-D and V2-E
    keep four bodies, which line up with the teacher's four directly.
    Only the CxC channel-relation matrices are compared; no direct feature L2 is
    used here.
    """
    if pairing is None:
        pairing = BODY_PAIRINGS.get((len(student_stages), len(teacher_stages)))
    if pairing is None:
        raise ValueError(
            f"No documented Body pairing for "
            f"{len(student_stages)}/{len(teacher_stages)} stages")
    losses = []
    for student_index, teacher_index in pairing:
        student_relation = _channel_relation(student_stages[student_index])
        teacher_relation = _channel_relation(teacher_stages[teacher_index])
        if student_relation.shape != teacher_relation.shape:
            raise ValueError(
                f"Mismatched Body relation shapes: "
                f"{tuple(student_relation.shape)} vs {tuple(teacher_relation.shape)}")
        losses.append(torch.sqrt(
            (student_relation - teacher_relation).square() + 1e-6).mean())
    return torch.stack(losses).mean()


class _Trainer:
    def __init__(self, generator, lr, expected=None):
        # Architecture gate: the generator must match the fingerprint expected
        # for this experiment.  The fingerprint is measured from the live
        # module, so a topology edit cannot pass silently the way a
        # self-declared attribute could.
        expected = V1_FINGERPRINT if expected is None else tuple(expected)
        actual = model_fingerprint(generator)
        if actual != expected:
            raise ValueError(
                f"Unexpected {type(generator).__name__} architecture: "
                f"fingerprint {actual} != expected {expected}")
        self.generator = generator
        self.device = next(generator.parameters()).device
        if any(p.device != self.device or p.dtype != torch.float32
               or not p.requires_grad for p in generator.parameters()):
            raise ValueError("Expected trainable FP32 G on one device")
        assert_bn_state(generator, 0)  # caller constructs fresh; restore via load_state_dict
        self.steps = 0
        self._failed = False
        self._in_step = False
        self.networks = {"generator": generator}
        self.optimizers = {}
        self.pools = {}
        self.config = {"method": type(self).__name__, "gan_mode": "lsgan",
                       "generator": type(generator).__name__, "rgb_range": [0, 1],
                       "bn_policy": "canonical_once_aux_batch_no_tracking",
                       "adam_betas": [0.5, 0.999], "aux_init": "normal_0.02"}
        self._check_lr(lr)

    @staticmethod
    def _check_lr(lr):
        if not math.isfinite(lr) or lr < 0:
            raise ValueError("Learning rate must be finite and nonnegative")

    def set_lr(self, lr):
        self._check_lr(lr)
        for optimizer in self.optimizers.values():
            for group in optimizer.param_groups:
                group["lr"] = float(lr)

    def _inputs(self, a, b):
        if self._failed or self._in_step:
            raise RuntimeError("Trainer incomplete/failed; restore the last good checkpoint")
        if not torch.is_grad_enabled():
            raise RuntimeError("step() requires autograd enabled")
        for x in (a, b):
            if (x.ndim != 4 or not 1 <= x.shape[0] <= 4 or x.shape[1] != 3
                    or min(x.shape[-2:]) < 32 or x.dtype != torch.float32
                    or x.device != self.device or x.requires_grad):
                raise ValueError("Expected batch 1..4 NCHW RGB01 FP32, H/W>=32, on G's device")
        if a.shape[0] != b.shape[0]:
            raise ValueError("A and B must have the same batch count (spatial sizes may differ)")
        valid = torch.stack([torch.isfinite(x).all() & (x >= 0).all() & (x <= 1).all()
                             for x in (a, b)])
        if not bool(valid.all()):
            raise ValueError("Input images must be finite RGB in [0,1]")

    def _discriminator_grad(self, enabled):
        for name, network in self.networks.items():
            if name.startswith("D"):
                network.requires_grad_(enabled)

    @contextmanager
    def _iteration(self, a, b):
        self._inputs(a, b)
        self._in_step = True
        try:
            for network in self.networks.values():
                network.train()
            for optimizer in self.optimizers.values():
                optimizer.zero_grad(set_to_none=True)
            yield
            self.steps += 1
        except BaseException:
            self._failed = True
            raise
        finally:
            for optimizer in self.optimizers.values():
                optimizer.zero_grad(set_to_none=True)
            self._discriminator_grad(True)
            self._in_step = False

    def validate_state(self, step):
        if self._failed or self._in_step or step != self.steps:
            raise RuntimeError(f"Not a complete step: requested={step}, actual={self.steps}")
        report = {"step": int(step)}
        for name, network in self.networks.items():
            _finite(list(network.parameters()) + list(network.buffers()), name)
            if any(p.grad is not None for p in network.parameters()):
                raise RuntimeError(f"Unreleased gradients in {name}")
            if isinstance(network, NativeGroupMixNet):
                report[name] = assert_bn_state(network, step)
        for name, optimizer in self.optimizers.items():
            _finite([v for state in optimizer.state.values() for v in state.values()
                     if isinstance(v, torch.Tensor)], name + " Adam state")
        for name, pool in self.pools.items():
            if len(pool.images) > pool.size or any(x.grad_fn is not None for x in pool.images):
                raise RuntimeError(f"Invalid replay pool {name}")
            _finite(pool.images, name + " replay")
        return report

    def state_dict(self):
        self.validate_state(self.steps)
        state = {"version": 1, "config": self.config, "step": self.steps,
                 "networks": {k: v.state_dict() for k, v in self.networks.items()},
                 "optimizers": {k: v.state_dict() for k, v in self.optimizers.items()},
                 "pools": {k: v.state_dict() for k, v in self.pools.items()},
                 "torch_rng": torch.get_rng_state(),
                 "cuda_rng": (torch.cuda.get_rng_state(self.device)
                              if self.device.type == "cuda" else None)}
        return _cpu_snapshot(state)

    def load_state_dict(self, state):
        if self._in_step:
            raise RuntimeError("Cannot restore during a step")
        if state["version"] != 1 or state["config"] != self.config:
            raise ValueError("Incompatible adversarial checkpoint configuration")
        for category, current in (("networks", self.networks),
                                  ("optimizers", self.optimizers), ("pools", self.pools)):
            if set(state[category]) != set(current):
                raise ValueError(f"Mismatched checkpoint {category}")
        self._failed = True
        for name, network in self.networks.items():
            network.load_state_dict(state["networks"][name], strict=True)
        for name, optimizer in self.optimizers.items():
            optimizer.load_state_dict(deepcopy(state["optimizers"][name]))
            optimizer.zero_grad(set_to_none=True)
        for name, pool in self.pools.items():
            pool.load_state_dict(state["pools"][name], self.device)
        self.steps = int(state["step"])
        self._discriminator_grad(True)
        self._failed = False
        try:
            self.validate_state(self.steps)
            torch.set_rng_state(state["torch_rng"].cpu())
            if self.device.type == "cuda":
                if state["cuda_rng"] is None:
                    raise ValueError("Missing CUDA RNG for CUDA resume")
                torch.cuda.set_rng_state(state["cuda_rng"].cpu(), self.device)
        except BaseException:
            self._failed = True
            raise


class CUTTrainer(_Trainer):
    """One D, five per-layer projection heads; D update then joint G/MLP update."""
    def __init__(self, generator, lr=0.0002, perceptual=None, weights=(0.,0.),
                 expected=None, nce_channels=None, nce_a_scale=0.25,
                 nce_y_scale=0.25, teacher=None, distill_weight=0.0,
                 distill_mode="rgb", distill_gradient_target=0.0,
                 balance_target=0.25, balance_target_patch=None, texture_weight=1.0,
                 relation_weight=0.35, low_weight=0.15, chroma_weight=0.0,
                 broadband_weight=0.0, contrast_weight=0.0, contrast_gain=1.0,
                 repetition_weight=0.0, colour_weight=0.0,
                 colour_reference=None, flow_weight=0.0, swd_weight=0.0,
                 swd_luma=True, localgram_weight=0.0, judge=None,
                 judge_weight=0.0, score=None, score_gradient_target=0.0,
                 score_target=0.95, aespa_feature_gradient_target=0.0,
                 aespa_feature_gram_weight=1.0,
                 aespa_feature_localgram_weight=1.0,
                 aespa_l2_gradient_target=0.0,
                 dreamsim=None, dreamsim_global_gradient_target=0.0,
                 dreamsim_patch_gradient_target=0.0,
                 dreamsim_patch_count=2, dreamsim_patch_size=96,
                 dreamsim_patch_worst_weight=0.0,
                 dreamsim_calibration_steps=20,
                 dreamsim_rescale_step=0, dreamsim_rescale_window=20,
                 dreamsim_rescale_cap=2.0,
                 aespa_low_gradient_target=0.0,
                 painting_colour_gradient_target=0.0,
                 aespa_chroma_gradient_target=0.0,
                 halo_gradient_target=0.0, halo_target=0.048,
                 halo_sigma_ring=4.0, halo_sigma_back=12.0,
                 halo_bright_fraction=0.01,
                 aespa_low_sigma=6.0, aespa_colour_calibration_steps=20,
                 coarse_band_weight=0.0, shape_weight=0.0,
                 flat_weight=0.0, flat_sigma=FLAT_SIGMA,
                 flat_shrink=FLAT_SHRINK, flat_contrast_weight=1.0,
                 flat_texture_weight=1.0, flat_flow_weight=1.0, flat_low_weight=1.0):
        super().__init__(generator, lr, expected=expected)
        # nce_channels is None for every model whose five loss stages keep the
        # v1.1 channel layout, so those runs construct the projection heads
        # exactly as before.  V2-D needs C16 at the H/4 stage; that is the only
        # place where the projection input width has to follow the generator.
        self.nce_channels = (tuple(NCE_CHANNELS) if nce_channels is None
                             else tuple(int(c) for c in nce_channels))
        self.D = _PatchDiscriminator(antialias=True).to(self.device)
        self.F = _PatchProjection(self.nce_channels).to(self.device)
        self.networks.update(D=self.D, F=self.F)
        self.optimizers = {name: torch.optim.Adam(module.parameters(), lr=lr,
                                                 betas=(0.5, 0.999))
                           for name, module in (("G", generator), ("D", self.D), ("F", self.F))}
        self.config.update(nce_stages=NCE_STAGES, nce_channels=self.nce_channels,
                           num_patches=256, nce_T=0.07,
                           nce_idt=True, nce_weight=NCE_GLOBAL_WEIGHT, nce_domain_average=True,
                           nce_layer_weights=NCE_LAYER_WEIGHTS, nce_layer_denominator=5,
                           mlp_width=256, cross_image_negatives=False,
                           discriminator_antialias=True, pool_size=0)

        if perceptual is None:
            raise ValueError("Balanced VGG training requires the frozen VGG19 loss")
        self.perceptual=perceptual
        self.weights=tuple(float(w) for w in weights)
        self.nce_a_scale=float(nce_a_scale)
        self.nce_y_scale=float(nce_y_scale)
        if self.nce_a_scale < 0 or self.nce_y_scale < 0:
            raise ValueError("NCE scales must be nonnegative")
        if teacher is not None:
            if any(p.requires_grad for p in teacher.parameters()):
                raise ValueError("Distillation teacher must be frozen")
            teacher.eval()
            if next(teacher.parameters()).device != self.device:
                raise ValueError("Distillation teacher must share the generator device")
        self.teacher=teacher
        self.distill_weight=float(distill_weight)
        if self.distill_weight < 0:
            raise ValueError("Distillation weight must be nonnegative")
        if self.teacher is None and self.distill_weight:
            raise ValueError("Distillation weight requires a teacher")
        self.distill_mode = str(distill_mode)
        if self.distill_mode not in DISTILL_MODES:
            raise ValueError(f"Unknown distillation mode: {self.distill_mode}")
        # Weights of the three terms inside the "tex" objective.  They are fixed
        # ratios calibrated by measure_texture_terms(); the overall strength is
        # still set by distill_gradient_target against the original objective.
        self.texture_weight = float(texture_weight)
        self.relation_weight = float(relation_weight)
        self.low_weight = float(low_weight)
        self.chroma_weight = float(chroma_weight)
        self.broadband_weight = float(broadband_weight)
        self.contrast_weight = float(contrast_weight)
        self.contrast_gain = float(contrast_gain)
        self.repetition_weight = float(repetition_weight)
        self.colour_weight = float(colour_weight)
        self.flow_weight = float(flow_weight)
        self.swd_weight = float(swd_weight)
        # Scoring the texture on luminance only stops a colour gain from paying for
        # the style distance; the colour terms handle colour.
        self.swd_luma = bool(swd_luma)
        self.localgram_weight = float(localgram_weight)
        self.judge_weight = float(judge_weight)
        # The flat probe: the same targets asked again on a shallow 8-bit staircase,
        # which is the only content class in the activity range where the eye found
        # the student going flat while the reference kept its strokes.
        # The band the radial decomposition found short (12-16 px): one-sided,
        # band-selective, so it asks for coarse strokes without touching the fine
        # bands that the flat-probe round already pushed above the reference.
        self.coarse_band_weight = float(coarse_band_weight)
        # How the texture energy is distributed across scales, two-sided: the
        # per-band floors above can only add energy, and the student adds it in
        # the bands that are cheapest (the fine ones), which is the measured
        # misallocation behind "the strokes are not as strong as the reference's".
        self.shape_weight = float(shape_weight)
        self.flat_weight = float(flat_weight)
        self.flat_sigma = float(flat_sigma)
        self.flat_shrink = float(flat_shrink)
        self.flat_contrast_weight = float(flat_contrast_weight)
        self.flat_texture_weight = float(flat_texture_weight)
        self.flat_flow_weight = float(flat_flow_weight)
        self.flat_low_weight = float(flat_low_weight)
        if self.flat_weight and self.teacher is None:
            raise ValueError("flat_weight requires the reference generator")
        if self.flat_weight and self.distill_mode != "tex":
            raise ValueError("flat_weight requires the tex distillation mode")
        for name, value in (("coarse_band_weight", self.coarse_band_weight),
                            ("shape_weight", self.shape_weight),
                            ("flat_weight", self.flat_weight),
                            ("flat_contrast_weight", self.flat_contrast_weight),
                            ("flat_texture_weight", self.flat_texture_weight),
                            ("flat_flow_weight", self.flat_flow_weight),
                            ("flat_low_weight", self.flat_low_weight)):
            if value < 0:
                raise ValueError(f"{name} must be nonnegative")
        # The frozen discriminator from the reference generator's own run: the one
        # judge found whose ordering matches the eye and holds across sizes.
        self.judge = judge
        if self.judge is not None:
            self.judge.eval()
            for parameter in self.judge.parameters():
                parameter.requires_grad_(False)
        if self.judge_weight and self.judge is None:
            raise ValueError("judge_weight requires the reference discriminator")
        # The AesPA-likeness scorer: a frozen patch discriminator trained on
        # AesPA outputs (high) vs raw content (low).  V2E was never a training
        # label for it, so this rewards moving towards AesPA rather than
        # matching a stale checkpoint.  It is normalised separately from the
        # distilled texture block: putting it inside that block would dilute
        # every existing term, the failure the r19 third-level probe hit.
        self.score = score
        if self.score is not None:
            self.score.eval()
            for parameter in self.score.parameters():
                parameter.requires_grad_(False)
        self.score_gradient_target = float(score_gradient_target)
        self.score_target = float(score_target)
        if self.score_gradient_target < 0:
            raise ValueError("score_gradient_target must be nonnegative")
        if self.score_gradient_target and self.score is None:
            raise ValueError("score_gradient_target requires the scorer")
        if not math.isfinite(self.score_target):
            raise ValueError("score_target must be finite")
        self.config.update(score_gradient_target=self.score_gradient_target,
                           score_target=self.score_target)
        # AesPA feature distillation: phase-invariant Gram statistics against
        # the AesPA output, independent of the (removed) loss-2 block.
        self.aespa_feature_gradient_target = float(aespa_feature_gradient_target)
        self.aespa_feature_gram_weight = float(aespa_feature_gram_weight)
        self.aespa_feature_localgram_weight = float(
            aespa_feature_localgram_weight)
        self.aespa_l2_gradient_target = float(aespa_l2_gradient_target)
        if self.aespa_feature_gradient_target < 0:
            raise ValueError("aespa_feature_gradient_target must be nonnegative")
        if self.aespa_feature_gram_weight < 0 or \
                self.aespa_feature_localgram_weight < 0:
            raise ValueError("AesPA feature weights must be nonnegative")
        if self.aespa_l2_gradient_target < 0:
            raise ValueError("aespa_l2_gradient_target must be nonnegative")
        self.config.update(
            aespa_feature_gradient_target=self.aespa_feature_gradient_target,
            aespa_feature_gram_weight=self.aespa_feature_gram_weight,
            aespa_feature_localgram_weight=self.aespa_feature_localgram_weight,
            aespa_l2_gradient_target=self.aespa_l2_gradient_target)
        # Frozen DreamSim (patch variant): global and sampled-patch perceptual
        # distances between the student output and the AesPA target.  Both are
        # content-aligned, which is what makes DreamSim a valid distillation
        # signal here.
        self.dreamsim = dreamsim
        if self.dreamsim is not None:
            self.dreamsim.eval()
            for parameter in self.dreamsim.parameters():
                parameter.requires_grad_(False)
        self.dreamsim_global_gradient_target = float(
            dreamsim_global_gradient_target)
        self.dreamsim_patch_gradient_target = float(
            dreamsim_patch_gradient_target)
        self.dreamsim_patch_count = int(dreamsim_patch_count)
        self.dreamsim_patch_size = int(dreamsim_patch_size)
        # The weight is calibrated once from the first batch states and then
        # frozen.  Per-step normalisation makes the effective objective
        # non-stationary and, worse, raises the weight exactly when DreamSim's
        # gradient shrinks near a local optimum, which amplifies noise.
        self.dreamsim_patch_worst_weight = float(dreamsim_patch_worst_weight)
        self.dreamsim_calibration_steps = int(dreamsim_calibration_steps)
        self.dreamsim_rescale_step = int(dreamsim_rescale_step)
        self.dreamsim_rescale_window = int(dreamsim_rescale_window)
        self.dreamsim_rescale_cap = float(dreamsim_rescale_cap)
        if self.dreamsim_global_gradient_target < 0 or \
                self.dreamsim_patch_gradient_target < 0:
            raise ValueError("DreamSim gradient targets must be nonnegative")
        if self.dreamsim_patch_worst_weight < 0:
            raise ValueError("dreamsim_patch_worst_weight must be nonnegative")
        if self.dreamsim_rescale_step < 0 or self.dreamsim_rescale_window < 1:
            raise ValueError("DreamSim rescale step/window must be nonnegative")
        if not math.isfinite(self.dreamsim_rescale_cap) or \
                self.dreamsim_rescale_cap < 1.0:
            raise ValueError("DreamSim rescale cap must be >= 1")
        if (self.dreamsim_global_gradient_target or
                self.dreamsim_patch_gradient_target):
            if self.dreamsim is None:
                raise ValueError("DreamSim gradient targets require the model")
            if self.dreamsim_calibration_steps < 1:
                raise ValueError("DreamSim calibration needs at least one step")
        self.dreamsim_global_scale = None
        self.dreamsim_patch_scale = None
        self._dreamsim_calibration_count = 0
        self._dreamsim_calibration_global = []
        self._dreamsim_calibration_patch = []
        self._dreamsim_rescale_done = False
        self._dreamsim_rescale_global = []
        self._dreamsim_rescale_patch = []
        self.config.update(
            dreamsim_global_gradient_target=self.dreamsim_global_gradient_target,
            dreamsim_patch_gradient_target=self.dreamsim_patch_gradient_target,
            dreamsim_patch_count=self.dreamsim_patch_count,
            dreamsim_patch_size=self.dreamsim_patch_size,
            dreamsim_patch_worst_weight=self.dreamsim_patch_worst_weight,
            dreamsim_calibration_steps=self.dreamsim_calibration_steps,
            dreamsim_rescale_step=self.dreamsim_rescale_step,
            dreamsim_rescale_window=self.dreamsim_rescale_window,
            dreamsim_rescale_cap=self.dreamsim_rescale_cap)
        # Descriptors of the painting's own local Grams, precomputed once.
        self.painting_localgram = None
        self.style_features = None
        self.style_directions = None
        if self.colour_weight and colour_reference is None:
            raise ValueError("colour_weight requires a colour reference histogram")
        self.colour_reference = (None if colour_reference is None
                                 else colour_reference.float())
        # P0 colour terms for the DreamSim continuation.  The low-frequency
        # field follows the AesPA target's spatial colour layout (warm halos,
        # blue body, dark green shadows); the histogram term matches the
        # painting's own colour proportions.  Both are calibrated once over
        # the first steps, like DreamSim, and then frozen.
        self.aespa_low_gradient_target = float(aespa_low_gradient_target)
        self.painting_colour_gradient_target = float(
            painting_colour_gradient_target)
        self.aespa_chroma_gradient_target = float(
            aespa_chroma_gradient_target)
        self.halo_gradient_target = float(halo_gradient_target)
        self.halo_target = float(halo_target)
        self.halo_sigma_ring = float(halo_sigma_ring)
        self.halo_sigma_back = float(halo_sigma_back)
        self.halo_bright_fraction = float(halo_bright_fraction)
        self.aespa_low_sigma = float(aespa_low_sigma)
        self.aespa_colour_calibration_steps = int(
            aespa_colour_calibration_steps)
        if (self.aespa_low_gradient_target < 0
                or self.painting_colour_gradient_target < 0
                or self.aespa_chroma_gradient_target < 0
                or self.halo_gradient_target < 0):
            raise ValueError("AesPA colour gradient targets must be nonnegative")
        if self.halo_target < 0:
            raise ValueError("halo target must be nonnegative")
        if not 0 < self.halo_sigma_ring < self.halo_sigma_back:
            raise ValueError("halo sigmas must satisfy 0 < ring < back")
        if not 0 < self.halo_bright_fraction < 1:
            raise ValueError("halo bright fraction must be in (0, 1)")
        if self.aespa_colour_calibration_steps < 1:
            raise ValueError("AesPA colour calibration needs at least one step")
        if (self.painting_colour_gradient_target
                and self.colour_reference is None):
            raise ValueError("painting colour target requires a colour reference")
        if self.aespa_low_sigma <= 0:
            raise ValueError("aespa_low_sigma must be positive")
        self.aespa_low_scale = None
        self.painting_colour_scale = None
        self.aespa_chroma_scale = None
        self.halo_scale = None
        self._aespa_colour_calibration_count = 0
        self._aespa_colour_calibration_low = []
        self._aespa_colour_calibration_painting = []
        self._aespa_colour_calibration_chroma = []
        self._aespa_colour_calibration_halo = []
        self.config.update(
            aespa_low_gradient_target=self.aespa_low_gradient_target,
            painting_colour_gradient_target=self.painting_colour_gradient_target,
            aespa_chroma_gradient_target=self.aespa_chroma_gradient_target,
            halo_gradient_target=self.halo_gradient_target,
            halo_target=self.halo_target,
            halo_sigma_ring=self.halo_sigma_ring,
            halo_sigma_back=self.halo_sigma_back,
            halo_bright_fraction=self.halo_bright_fraction,
            aespa_low_sigma=self.aespa_low_sigma,
            aespa_colour_calibration_steps=self.aespa_colour_calibration_steps)
        if self.contrast_gain <= 0:
            raise ValueError("contrast_gain must be positive")
        for name, value in (("texture_weight", self.texture_weight),
                            ("relation_weight", self.relation_weight),
                            ("low_weight", self.low_weight),
                            ("chroma_weight", self.chroma_weight),
                            ("broadband_weight", self.broadband_weight),
                            ("contrast_weight", self.contrast_weight),
                            ("repetition_weight", self.repetition_weight),
                            ("colour_weight", self.colour_weight),
                            ("flow_weight", self.flow_weight),
                            ("swd_weight", self.swd_weight),
                            ("localgram_weight", self.localgram_weight),
                            ("judge_weight", self.judge_weight)):
            if value < 0:
                raise ValueError(f"{name} must be nonnegative")
        if self.distill_mode == "tex" and self.low_weight + self.relation_weight <= 0:
            raise ValueError("tex distillation needs at least one of the low/relation terms")
        self.texture = (TextureDescriptor().to(self.device)
                        if self.distill_mode == "tex" else None)
        self.distill_gradient_target = float(distill_gradient_target)
        if not math.isfinite(self.distill_gradient_target) or self.distill_gradient_target < 0:
            raise ValueError("Distillation gradient target must be finite and nonnegative")
        if self.distill_gradient_target and self.teacher is None:
            raise ValueError("Distillation gradient target requires a teacher")
        if self.distill_gradient_target and not self.distill_weight:
            raise ValueError("Distillation gradient target requires a positive distill weight")
        self.balance_target = float(balance_target)
        # The patch Gram term keeps its own target so the global Gram style distance
        # -- the metric that shows the reference beating every small model -- can be
        # pushed without dragging the local term up with it.
        self.balance_target_patch = (self.balance_target
                                     if balance_target_patch is None
                                     else float(balance_target_patch))
        for name, value in (("VGG gradient target", self.balance_target),
                            ("VGG patch gradient target", self.balance_target_patch)):
            if value <= 0:
                raise ValueError(f"{name} must be positive")
        # The upper cap only exists to keep the weight finite; at 25000 it clamped
        # the global Gram ratio near 1.4 while the target was 3.0, so the style push
        # was silently limited.
        self.balance_bounds = (1.0, 5.0e6)
        self.patch_rng=torch.Generator().manual_seed(20260904)
        self.config.update(perceptual=perceptual.config,
                           nce_a_scale=self.nce_a_scale,
                           nce_y_scale=self.nce_y_scale,
                           distillation=(self.teacher is not None),
                           distill_weight=self.distill_weight,
                           distill_mode=self.distill_mode,
                           distill_gradient_target=self.distill_gradient_target,
                           texture_weights={"texture": self.texture_weight,
                                            "relation": self.relation_weight,
                                            "low": self.low_weight,
                                            "chroma": self.chroma_weight,
                                            "broadband": self.broadband_weight,
                                            "contrast": self.contrast_weight,
                                            "contrast_gain": self.contrast_gain,
                                            "repetition": self.repetition_weight,
                                            "colour": self.colour_weight,
                                            "flow": self.flow_weight,
                                            "swd": self.swd_weight,
                                            "swd_luma_only": self.swd_luma,
                                            "localgram": self.localgram_weight,
                                            "coarse_band": self.coarse_band_weight,
                                            "shape": self.shape_weight,
                                            "judge": self.judge_weight,
                                            "flat": self.flat_weight,
                                            "flat_sigma": self.flat_sigma,
                                            "flat_shrink": self.flat_shrink,
                                            "flat_contrast": self.flat_contrast_weight,
                                            "flat_texture": self.flat_texture_weight,
                                            "flat_flow": self.flat_flow_weight,
                                            "flat_low": self.flat_low_weight},
                           texture_descriptor=(None if self.texture is None
                                               else self.texture.config),
                           perceptual_weights="direct_per_batch_gradient_rms",
                           perceptual_initial_weights=self.weights,
                           perceptual_gradient_target_each=self.balance_target,
                           perceptual_gradient_target_patch=self.balance_target_patch,
                           perceptual_gradient_reference="G_GAN",
                           perceptual_weight_bounds=list(self.balance_bounds),
                           paired_local_target=True)

    def prepare_style_reference(self, image):
        """Precompute the painting's features (luma only when the SWD term asks)."""
        if self.swd_luma:
            image = to_luma_image(image)
        """Precompute the painting's features and the fixed projection directions.

        Called once before training: the reference is a constant, so its features are
        extracted once instead of every step.
        """
        with torch.no_grad():
            features = self.perceptual.extract(image)
        self.style_features = [f.detach() for f in features]
        channels = [self.style_features[index].shape[1] for index in SWD_LAYERS]
        self.style_directions = style_directions(channels)
        self.painting_localgram = local_gram_descriptors(
            self.style_features[LOCAL_GRAM_LAYER])
        return [int(c) for c in channels]

    def state_dict(self):
        result=super().state_dict();result["patch_rng"]=self.patch_rng.get_state()
        result["vgg_balance"]={"weights":self.weights}
        return result

    def load_state_dict(self,state):
        super().load_state_dict(state);self.patch_rng.set_state(state["patch_rng"].cpu())
        balance=state["vgg_balance"]
        self.weights=tuple(float(v) for v in balance["weights"])

    def _balance_vgg(self, gan_grad, global_grad, patch_grad):
        gan_current,global_current,patch_current=tuple(float(v) for v in (gan_grad,global_grad,patch_grad))
        low,high=self.balance_bounds
        def coefficient(raw, target):
            return min(high,max(low,target*gan_current/max(raw,1e-16)))
        self.weights=(coefficient(global_current, self.balance_target),
                      coefficient(patch_current, self.balance_target_patch))
        return self.weights

    def _nce(self, source, translated):
        with auxiliary_batch_stats(self.generator):
            # Postprojection stop-grad makes the entire key branch gradient-free.
            # no_grad avoids building the otherwise discarded graph; it does NOT
            # suppress BN updates, which is why the context above is necessary.
            with torch.no_grad():
                keys, indices = self.F(encoder_features(self.generator, source))
                keys = [key.detach() for key in keys]
            queries, _ = self.F(encoder_features(self.generator, translated), indices)
        losses = [patch_nce(q, k) for q, k in zip(queries, keys)]
        self._last_nce_raw = torch.stack([value.detach() for value in losses]).mean()
        return aggregate_nce(losses)

    def step(self, a, b, paired, diagnose=False, global_reference=None,
             aespa_target=None):
        assert paired.shape==a.shape and paired.device==a.device and not paired.requires_grad
        assert torch.isfinite(paired).all() and paired.min()>=0 and paired.max()<=1
        with self._iteration(a, b):
            student_body_stages = None
            if self.teacher is not None and self.distill_mode in ("hf_rel", "tex"):
                fake, student_body_stages = self.generator.forward_with_body_stages(a)
            else:
                fake = self.generator(a)  # sole persistent BN update
            self._discriminator_grad(True)
            d_real = (self.D(b) - 1).square().mean()
            d_fake = self.D(fake.detach()).square().mean()
            d_loss = (d_real + d_fake) * 0.5
            _backward(d_loss)
            _optimizer_step(self.optimizers["D"])
            self.optimizers["D"].zero_grad(set_to_none=True)
            self._discriminator_grad(False)
            gan_raw = (self.D(fake) - 1).square().mean()
            gan = self.refine_gan_weight * gan_raw
            nce_a = self._nce(a, fake)
            want_features = bool(self.swd_weight)
            style_features_of_fake = None
            if want_features:
                global_style, style_features_of_fake = self.perceptual.global_loss(
                    fake, b if global_reference is None else global_reference,
                    return_features=True)
            else:
                global_style=self.perceptual.global_loss(fake,b if global_reference is None else global_reference)
            local_style=self.perceptual.patch_loss(fake,paired,self.patch_rng)
            from perceptual import gradient_rms
            params=tuple(self.generator.parameters())
            gan_grad=gradient_rms(gan,params)
            global_grad=gradient_rms(global_style,params)
            patch_grad=gradient_rms(local_style,params)
            self._balance_vgg(gan_grad,global_grad,patch_grad)
            realized_global=self.weights[0]*float(global_grad)/float(gan_grad)
            realized_patch=self.weights[1]*float(patch_grad)/float(gan_grad)
            realized_global_tensor=gan.new_tensor(realized_global)
            realized_patch_tensor=gan.new_tensor(realized_patch)
            global_weight_tensor=gan.new_tensor(self.weights[0])
            patch_weight_tensor=gan.new_tensor(self.weights[1])
            diagnostics={}
            if diagnose:
                diagnostics={"grad_GAN":gan_grad,"grad_global":global_grad,"grad_patch":patch_grad,
                             "grad_NCE_A_weighted":gradient_rms(self.nce_a_scale*nce_a,params),
                             "grad_ratio_global":realized_global_tensor,"grad_ratio_patch":realized_patch_tensor,
                             "grad_weight_global":global_weight_tensor,"grad_weight_patch":patch_weight_tensor}
            weighted_global=self.weights[0]*global_style
            weighted_patch=self.weights[1]*local_style
            base_a = gan + self.nce_a_scale*nce_a + weighted_global + weighted_patch
            distill_loss=None
            distill_hf=None
            distill_coh=None
            distill_rel=None
            distill_low=None
            distill_chroma=None
            distill_energy=None
            distill_broadband=None
            distill_contrast=None
            distill_repetition=None
            distill_colour=None
            distill_flow=None
            distill_swd=None
            distill_localgram=None
            distill_judge=None
            distill_band=None
            distill_shape=None
            distill_flat=None
            flat_contrast=None
            flat_flow=None
            weighted_distill=gan.new_zeros(())
            distill_effective_weight=gan.new_zeros(())
            base_a_grad=None
            distill_score=None
            score_mean=gan.new_zeros(())
            weighted_score=gan.new_zeros(())
            score_effective_weight=gan.new_zeros(())
            # AesPA-likeness reward: a one-sided hinge at score_target.  The
            # scorer saturates around +1.0 on AesPA outputs, so 0.95 asks the
            # student to enter that band without rewarding over-stylisation;
            # leaky_relu keeps a tiny backward pressure above the target and,
            # unlike relu, never leaves a batch with an exactly-zero gradient
            # for gradient_rms (which asserts on that).
            if self.score is not None:
                score_value = self.score(fake).mean(dim=(1, 2, 3))
                score_mean = score_value.mean().detach()
                distill_score = F.leaky_relu(self.score_target - score_value,
                                             0.01).mean()
            teacher_fake=None
            teacher_body_stages=None
            if self.teacher is not None:
                with torch.no_grad():
                    if self.distill_mode in ("hf_rel", "tex"):
                        teacher_fake, teacher_body_stages = self.teacher.forward_with_body_stages(a)
                    else:
                        teacher_fake=self.teacher(a)
                if self.distill_mode == "haar_hf":
                    distill_loss=haar_high_frequency_loss(fake, teacher_fake)
                elif self.distill_mode == "hf_rel":
                    distill_hf=haar_high_frequency_loss(fake, teacher_fake)
                    distill_rel=body_relation_loss(student_body_stages, teacher_body_stages)
                    distill_loss=distill_hf + distill_rel
                elif self.distill_mode == "tex":
                    # Phase-tolerant texture statistics, the term this mode
                    # exists for; the other two only protect structure and
                    # colour so the texture term cannot buy its gain by
                    # drifting the colours or the layout.
                    distill_hf = texture_stat_loss(self.texture, fake, teacher_fake)
                    distill_coh = coherence_loss(self.texture, fake, teacher_fake)
                    distill_rel = body_relation_loss(student_body_stages, teacher_body_stages)
                    distill_low = low_frequency_loss(fake, teacher_fake)
                    distill_energy = energy_scale_loss(self.texture, fake, teacher_fake,
                                                      self.contrast_gain)
                    # The anti-repetition term: a periodic texture has the same
                    # energy and orientation as an irregular one, so only the
                    # concentration of its spectrum separates them.
                    distill_broadband = (broadbandness_loss(fake, teacher_fake)
                                         if self.broadband_weight else None)
                    # The style-level knob: 1.0 is the teacher's stroke contrast,
                    # ~1.25 is AESPA's, ~1.9 is the painting's.
                    distill_contrast = (
                        stroke_contrast_loss(fake, teacher_fake, a, self.contrast_gain)
                        if self.contrast_weight else None)
                    # The repetition term: the statistic that orders the
                    # candidates the way the eye does (near-duplicate patch
                    # fraction: painting 0.002, reference 0.021, v2e 0.061).
                    distill_repetition = (repetition_loss(fake, teacher_fake)
                                          if self.repetition_weight else None)
                    # The colour-proportion term: distance from the *painting's*
                    # colour distribution, not the reference generator's.
                    distill_colour = (
                        colour_distribution_loss(fake, self.colour_reference)
                        if self.colour_weight else None)
                    # Orientation continuity: the term for "the strokes should read
                    # as drawn with a brush, not as an unorganised texture".
                    distill_flow = (orientation_flow_loss(fake, teacher_fake)
                                    if self.flow_weight else None)
                    # The VGG judgement that orders the candidates the way the eye
                    # does: sliced Wasserstein against the painting's features.
                    if self.swd_weight and self.swd_luma:
                        # A second forward, on the luma: the features taken for the
                        # colour style loss carry colour and would let a colour
                        # change pay for the texture distance.
                        swd_features = self.perceptual.extract(to_luma_image(fake))
                    else:
                        swd_features = style_features_of_fake
                    distill_swd = (sliced_wasserstein_style_loss(
                        swd_features, self.style_features,
                        self.style_directions) if self.swd_weight else None)
                    # The local-Gram hinge: the metric the eye agrees with, scored
                    # against the reference generator's own value on the same batch.
                    if self.localgram_weight and self.painting_localgram is not None:
                        with torch.no_grad():
                            teacher_features = self.perceptual.extract(teacher_fake)
                        distill_localgram = local_gram_teacher_loss(
                            self.perceptual.extract(fake)[LOCAL_GRAM_LAYER],
                            teacher_features[LOCAL_GRAM_LAYER],
                            self.painting_localgram)
                    else:
                        distill_localgram = None
                    # Adversarial distillation: the frozen judge, not the one the
                    # student trains its own discriminator against.
                    distill_judge = (judge_loss(self.judge, fake)
                                     if self.judge_weight else None)
                    distill_band = (band_contrast_loss(fake, teacher_fake, a,
                                                       gain=self.contrast_gain)
                                    if self.coarse_band_weight else None)
                    distill_shape = (spectral_shape_loss(fake, teacher_fake, a)
                                     if self.shape_weight else None)
                    distill_chroma = (chroma_loss(fake, teacher_fake, a)
                                      if self.chroma_weight else None)
                    # The flat probe: the same targets asked again on a shallow
                    # 8-bit staircase.  The corridor wall the eye rejected lives
                    # at an activity of 1e-5..1e-4 while the training crops' own
                    # flattest 30 percent sits at 0.0097, so nothing above ever
                    # constrained that regime; on 48 crops the student holds the
                    # teacher's stroke contrast down to blur-16 content and then
                    # collapses to 0.34 of it on the staircase, against 0.39 on
                    # twelve real wall crops.
                    if self.flat_weight:
                        flat_content = flat_probe(a, self.flat_sigma, self.flat_shrink)
                        with torch.no_grad():
                            flat_teacher = self.teacher(flat_content)
                        # Running statistics, not the flat batch's own: the target
                        # is the deployed generator's behaviour, and a batch-stats
                        # pass would satisfy the floor by dividing by the flat
                        # batch's tiny variance.
                        with running_stats(self.generator):
                            flat_fake = self.generator(flat_content)
                        flat_terms = flat_content_loss(
                            self.texture, flat_fake, flat_teacher, flat_content,
                            {"contrast": self.flat_contrast_weight,
                             "texture": self.flat_texture_weight,
                             "flow": self.flat_flow_weight,
                             "low": self.flat_low_weight,
                             "coarse": self.coarse_band_weight},
                            self.contrast_gain)
                        distill_flat = flat_terms["combined"]
                        flat_contrast = flat_terms["contrast"]
                        flat_flow = flat_terms["flow"]
                        del flat_content, flat_teacher, flat_fake
                    distill_loss = (self.texture_weight * (distill_hf + distill_coh
                                                          + distill_energy)
                                    + self.relation_weight * distill_rel
                                    + self.low_weight * distill_low
                                    + self.chroma_weight * (distill_chroma
                                                            if distill_chroma is not None
                                                            else 0.0)
                                    + self.broadband_weight * (distill_broadband
                                                               if distill_broadband is not None
                                                               else 0.0)
                                    + self.contrast_weight * (distill_contrast
                                                              if distill_contrast is not None
                                                              else 0.0)
                                    + self.repetition_weight
                                    * (distill_repetition
                                       if distill_repetition is not None else 0.0)
                                    + self.colour_weight
                                    * (distill_colour
                                       if distill_colour is not None else 0.0)
                                    + self.flow_weight
                                    * (distill_flow if distill_flow is not None else 0.0)
                                    + self.swd_weight
                                    * (distill_swd if distill_swd is not None else 0.0)
                                    + self.localgram_weight
                                    * (distill_localgram
                                       if distill_localgram is not None else 0.0)
                                    + self.coarse_band_weight
                                    * (distill_band if distill_band is not None
                                       else 0.0)
                                    + self.shape_weight
                                    * (distill_shape if distill_shape is not None
                                       else 0.0)
                                    + self.judge_weight
                                    * (distill_judge
                                       if distill_judge is not None else 0.0)
                                    + self.flat_weight
                                    * (distill_flat if distill_flat is not None
                                       else 0.0))
                else:
                    # Charbonnier output matching is less brittle than plain
                    # MSE when the tiny student cannot reproduce every pixel.
                    distill_loss=torch.sqrt((fake-teacher_fake).square()+1e-6).mean()
                if self.distill_gradient_target:
                    base_a_grad=gradient_rms(base_a, params)
                    raw_distill_grad=gradient_rms(distill_loss, params)
                    effective_weight=(self.distill_weight
                                      * self.distill_gradient_target
                                      * float(base_a_grad)
                                      / max(float(raw_distill_grad), 1e-16))
                    distill_effective_weight=gan.new_tensor(effective_weight)
                    weighted_distill=effective_weight*distill_loss
                    if diagnose:
                        diagnostics.update(
                            grad_original_A=base_a_grad,
                            grad_distill_raw=raw_distill_grad,
                            grad_distill_ratio_A=gradient_rms(weighted_distill, params)
                            / base_a_grad,
                            distill_effective_weight=distill_effective_weight)
                else:
                    weighted_distill=self.distill_weight*distill_loss
                    distill_effective_weight=gan.new_tensor(self.distill_weight)
                if diagnose:
                    diagnostics["grad_distill_weighted"] = gradient_rms(weighted_distill,params)
            if distill_score is not None:
                score_base_grad = (base_a_grad if base_a_grad is not None
                                   else gradient_rms(base_a, params))
                raw_score_grad = gradient_rms(distill_score, params)
                effective_score = (self.score_gradient_target
                                   * float(score_base_grad)
                                   / max(float(raw_score_grad), 1e-16))
                weighted_score = effective_score * distill_score
                score_effective_weight = gan.new_tensor(effective_score)
                if diagnose:
                    diagnostics.update(
                        grad_score_raw=raw_score_grad,
                        grad_score_ratio_A=gradient_rms(weighted_score, params)
                        / score_base_grad,
                        score_effective_weight=score_effective_weight)
            if diagnose and distill_score is not None:
                # Directional diagnosis: is the existing objective pulling with
                # or against the scorer?  Cosine of the parameter gradients.
                def _flat_grad(loss):
                    grads = torch.autograd.grad(loss, params, retain_graph=True,
                                                allow_unused=True)
                    return torch.cat([g.reshape(-1) for g in grads
                                      if g is not None])
                g_score = _flat_grad(distill_score)
                for _name, _term in (("base", base_a),
                                     ("distill", distill_loss),
                                     ("low", distill_low),
                                     ("colour", distill_colour),
                                     ("judge", distill_judge),
                                     ("shape", distill_shape),
                                     ("flat", distill_flat),
                                     ("flow", distill_flow),
                                     ("gan", gan),
                                     ("nce", nce_a)):
                    if _term is None:
                        continue
                    g_term = _flat_grad(_term)
                    diagnostics[f"grad_cos_score_{_name}"] = gan.new_tensor(float(
                        (g_score @ g_term)
                        / (g_score.norm() * g_term.norm()).clamp_min(1e-12)))
            aespa_feature_loss = None
            weighted_aespa_feature = gan.new_zeros(())
            aespa_feature_effective_weight = gan.new_zeros(())
            aespa_l2_loss = None
            weighted_aespa_l2 = gan.new_zeros(())
            aespa_l2_effective_weight = gan.new_zeros(())
            if aespa_target is not None and (self.aespa_feature_gradient_target
                                             or self.aespa_l2_gradient_target):
                # Phase-invariant feature statistics against the AesPA output.
                # Gram at all four VGG levels + local Gram at relu3/relu4;
                # optionally the perceptual feature L2 at relu4_1.
                with torch.no_grad():
                    aespa_features = self.perceptual.extract(aespa_target)
                student_features = self.perceptual.extract(fake)
                feature_base_grad = (base_a_grad if base_a_grad is not None
                                     else gradient_rms(base_a, params))
                if self.aespa_feature_gradient_target:
                    gram_terms = []
                    for level in range(4):
                        student_gram = self.perceptual.gram(student_features[level])
                        aespa_gram = self.perceptual.gram(aespa_features[level])
                        gram_terms.append(F.mse_loss(student_gram, aespa_gram)
                                          / (aespa_gram.pow(2).mean() + 1e-12))
                    local = student_features[2].new_zeros(())
                    for level in (2, 3):
                        for index in range(fake.shape[0]):
                            local = local + local_gram_distance(
                                student_features[level][index:index + 1],
                                local_gram_descriptors(
                                    aespa_features[level][index:index + 1]))
                    local = local / (fake.shape[0] * 2)
                    aespa_feature_loss = (
                        self.aespa_feature_gram_weight * sum(gram_terms)
                        + self.aespa_feature_localgram_weight * local)
                    raw_feature_grad = gradient_rms(aespa_feature_loss, params)
                    effective_feature = (self.aespa_feature_gradient_target
                                         * float(feature_base_grad)
                                         / max(float(raw_feature_grad), 1e-16))
                    weighted_aespa_feature = effective_feature * aespa_feature_loss
                    aespa_feature_effective_weight = gan.new_tensor(effective_feature)
                    if diagnose:
                        diagnostics.update(
                            grad_aespa_feature_raw=raw_feature_grad,
                            grad_aespa_feature_ratio_A=gradient_rms(
                                weighted_aespa_feature, params) / feature_base_grad,
                            aespa_feature_effective_weight=aespa_feature_effective_weight)
                if self.aespa_l2_gradient_target:
                    # Johnson-style perceptual feature L2 at relu4_1, already
                    # normalised by C*H*W through mse_loss.
                    aespa_l2_loss = F.mse_loss(student_features[3],
                                               aespa_features[3])
                    raw_l2_grad = gradient_rms(aespa_l2_loss, params)
                    effective_l2 = (self.aespa_l2_gradient_target
                                    * float(feature_base_grad)
                                    / max(float(raw_l2_grad), 1e-16))
                    weighted_aespa_l2 = effective_l2 * aespa_l2_loss
                    aespa_l2_effective_weight = gan.new_tensor(effective_l2)
                    if diagnose:
                        diagnostics.update(
                            grad_aespa_l2_raw=raw_l2_grad,
                            grad_aespa_l2_ratio_A=gradient_rms(
                                weighted_aespa_l2, params) / feature_base_grad,
                            aespa_l2_effective_weight=aespa_l2_effective_weight)
            dreamsim_global_loss = None
            weighted_dreamsim_global = gan.new_zeros(())
            dreamsim_global_effective = gan.new_zeros(())
            dreamsim_patch_loss = None
            weighted_dreamsim_patch = gan.new_zeros(())
            dreamsim_patch_effective = gan.new_zeros(())
            if (self.dreamsim is not None and aespa_target is not None
                    and (self.dreamsim_global_gradient_target
                         or self.dreamsim_patch_gradient_target)):
                fake224 = F.interpolate(fake, (224, 224), mode="bilinear",
                                        align_corners=False, antialias=True)
                aespa224 = F.interpolate(aespa_target, (224, 224),
                                         mode="bilinear", align_corners=False,
                                         antialias=True)
                active_global = bool(self.dreamsim_global_gradient_target)
                active_patch = bool(self.dreamsim_patch_gradient_target)
                calibrating = (self._dreamsim_calibration_count
                               < self.dreamsim_calibration_steps)
                current_step = self.steps + 1
                rescale_window = (
                    self.dreamsim_rescale_step > 0
                    and not self._dreamsim_rescale_done
                    and self.dreamsim_rescale_step <= current_step
                    < self.dreamsim_rescale_step
                    + self.dreamsim_rescale_window)
                if active_global:
                    dreamsim_global_loss = self.dreamsim(
                        fake224, aespa224).mean()
                if active_patch:
                    ps = self.dreamsim_patch_size
                    batch = fake.shape[0]
                    xs = torch.randint(0, fake.shape[3] - ps + 1,
                                       (batch, self.dreamsim_patch_count),
                                       device=fake.device)
                    ys = torch.randint(0, fake.shape[2] - ps + 1,
                                       (batch, self.dreamsim_patch_count),
                                       device=fake.device)
                    fake_patches, target_patches = [], []
                    for image_index in range(batch):
                        for k in range(self.dreamsim_patch_count):
                            x = int(xs[image_index, k].item())
                            y = int(ys[image_index, k].item())
                            fake_patches.append(
                                fake[image_index:image_index + 1, :,
                                     y:y + ps, x:x + ps])
                            target_patches.append(
                                aespa_target[image_index:image_index + 1, :,
                                             y:y + ps, x:x + ps])
                    fake_patches = F.interpolate(
                        torch.cat(fake_patches), (224, 224), mode="bilinear",
                        align_corners=False, antialias=True)
                    target_patches = F.interpolate(
                        torch.cat(target_patches), (224, 224), mode="bilinear",
                        align_corners=False, antialias=True)
                    values = self.dreamsim(fake_patches, target_patches)
                    dreamsim_patch_loss = values.mean()
                    if self.dreamsim_patch_worst_weight:
                        worst = torch.topk(
                            values,
                            max(1, values.numel() // 4)).values.mean()
                        dreamsim_patch_loss = (
                            dreamsim_patch_loss
                            + self.dreamsim_patch_worst_weight * worst)
                need_base = calibrating or rescale_window or diagnose
                dream_base_grad = (
                    base_a_grad if base_a_grad is not None
                    else (gradient_rms(base_a, params) if need_base else None))
                if calibrating:
                    # DreamSim is deliberately inactive while the scale is
                    # measured, so the calibration states are not biased by a
                    # provisional weight.  The median is frozen afterwards.
                    if active_global:
                        raw = gradient_rms(dreamsim_global_loss, params)
                        self._dreamsim_calibration_global.append(
                            float(dream_base_grad)
                            / max(float(raw), 1e-16))
                    if active_patch:
                        raw = gradient_rms(dreamsim_patch_loss, params)
                        self._dreamsim_calibration_patch.append(
                            float(dream_base_grad)
                            / max(float(raw), 1e-16))
                    self._dreamsim_calibration_count += 1
                    if (self._dreamsim_calibration_count
                            >= self.dreamsim_calibration_steps):
                        if active_global:
                            ratio = _median(
                                self._dreamsim_calibration_global)
                            self.dreamsim_global_scale = (
                                self.dreamsim_global_gradient_target * ratio)
                        if active_patch:
                            ratio = _median(
                                self._dreamsim_calibration_patch)
                            self.dreamsim_patch_scale = (
                                self.dreamsim_patch_gradient_target * ratio)
                        print(json.dumps({
                            "dreamsim_calibration_steps":
                                self._dreamsim_calibration_count,
                            "dreamsim_global_ratio":
                                _median(self._dreamsim_calibration_global),
                            "dreamsim_patch_ratio":
                                _median(self._dreamsim_calibration_patch),
                            "dreamsim_global_scale":
                                self.dreamsim_global_scale,
                            "dreamsim_patch_scale":
                                self.dreamsim_patch_scale}), flush=True)
                    if diagnose:
                        diagnostics.update(
                            dreamsim_calibration_count=
                                self._dreamsim_calibration_count,
                            dreamsim_global_scale=(
                                0.0 if self.dreamsim_global_scale is None
                                else self.dreamsim_global_scale),
                            dreamsim_patch_scale=(
                                0.0 if self.dreamsim_patch_scale is None
                                else self.dreamsim_patch_scale))
                else:
                    # Fixed weights from the calibration window.  The realised
                    # ratio is reported on diagnostics but never fed back into
                    # the weight: per-step normalisation would amplify noise as
                    # DreamSim approaches its own optimum.
                    scale_global = (0.0 if self.dreamsim_global_scale is None
                                    else self.dreamsim_global_scale)
                    scale_patch = (0.0 if self.dreamsim_patch_scale is None
                                   else self.dreamsim_patch_scale)
                    if active_global:
                        weighted_dreamsim_global = (
                            scale_global * dreamsim_global_loss)
                        dreamsim_global_effective = gan.new_tensor(
                            scale_global)
                    if active_patch:
                        weighted_dreamsim_patch = (
                            scale_patch * dreamsim_patch_loss)
                        dreamsim_patch_effective = gan.new_tensor(
                            scale_patch)
                    if need_base:
                        realized_global = None
                        realized_patch = None
                        if active_global:
                            realized_global = float(gradient_rms(
                                weighted_dreamsim_global, params)) / max(
                                    float(dream_base_grad), 1e-16)
                        if active_patch:
                            realized_patch = float(gradient_rms(
                                weighted_dreamsim_patch, params)) / max(
                                    float(dream_base_grad), 1e-16)
                        if rescale_window:
                            if realized_global is not None:
                                self._dreamsim_rescale_global.append(
                                    realized_global)
                            if realized_patch is not None:
                                self._dreamsim_rescale_patch.append(
                                    realized_patch)
                            ready = (
                                len(self._dreamsim_rescale_global)
                                >= self.dreamsim_rescale_window
                                or (not active_global
                                    and len(self._dreamsim_rescale_patch)
                                    >= self.dreamsim_rescale_window))
                            if ready:
                                cap = self.dreamsim_rescale_cap
                                if (active_global
                                        and self._dreamsim_rescale_global):
                                    med = _median(
                                        self._dreamsim_rescale_global)
                                    factor = (
                                        self.dreamsim_global_gradient_target
                                        / med if med > 0 else 1.0)
                                    factor = min(cap, max(1.0 / cap, factor))
                                    self.dreamsim_global_scale *= factor
                                if (active_patch
                                        and self._dreamsim_rescale_patch):
                                    med = _median(
                                        self._dreamsim_rescale_patch)
                                    factor = (
                                        self.dreamsim_patch_gradient_target
                                        / med if med > 0 else 1.0)
                                    factor = min(cap, max(1.0 / cap, factor))
                                    self.dreamsim_patch_scale *= factor
                                self._dreamsim_rescale_done = True
                                print(json.dumps({
                                    "dreamsim_rescale_step": current_step,
                                    "dreamsim_global_scale":
                                        self.dreamsim_global_scale,
                                    "dreamsim_patch_scale":
                                        self.dreamsim_patch_scale}), flush=True)
                        if diagnose:
                            values = {
                                "dreamsim_global_scale": scale_global,
                                "dreamsim_patch_scale": scale_patch,
                                "dreamsim_global_effective_weight":
                                    dreamsim_global_effective,
                                "dreamsim_patch_effective_weight":
                                    dreamsim_patch_effective}
                            if realized_global is not None:
                                values.update(
                                    grad_dreamsim_global_ratio_A=
                                        realized_global,
                                    grad_dreamsim_global_raw=
                                        realized_global
                                        * float(dream_base_grad)
                                        / max(scale_global, 1e-16))
                            if realized_patch is not None:
                                values.update(
                                    grad_dreamsim_patch_ratio_A=
                                        realized_patch,
                                    grad_dreamsim_patch_raw=
                                        realized_patch
                                        * float(dream_base_grad)
                                        / max(scale_patch, 1e-16))
                            diagnostics.update(values)
            aespa_low_loss = None
            weighted_aespa_low = gan.new_zeros(())
            aespa_low_effective = gan.new_zeros(())
            painting_colour_loss = None
            weighted_painting_colour = gan.new_zeros(())
            painting_colour_effective = gan.new_zeros(())
            aespa_chroma_loss = None
            weighted_aespa_chroma = gan.new_zeros(())
            aespa_chroma_effective = gan.new_zeros(())
            halo_loss_value = None
            weighted_halo = gan.new_zeros(())
            halo_effective = gan.new_zeros(())
            if (self.aespa_low_gradient_target
                    or self.painting_colour_gradient_target
                    or self.aespa_chroma_gradient_target
                    or self.halo_gradient_target):
                if (self.aespa_low_gradient_target
                        and aespa_target is not None):
                    aespa_low_loss = low_frequency_loss(
                        fake, aespa_target, self.aespa_low_sigma)
                if self.painting_colour_gradient_target:
                    painting_colour_loss = colour_distribution_loss(
                        fake, self.colour_reference)
                if (self.aespa_chroma_gradient_target
                        and aespa_target is not None):
                    # The top-1% warm statistic can already be satisfied on a
                    # crop, leaving a zero gradient.  The low-passed warm field
                    # is dense and still targets the halos around highlights.
                    aespa_chroma_loss = low_frequency_loss(
                        (fake[:, 0:1] + fake[:, 1:2]) / 2 - fake[:, 2:3],
                        (aespa_target[:, 0:1] + aespa_target[:, 1:2]) / 2
                        - aespa_target[:, 2:3],
                        self.aespa_low_sigma)
                if self.halo_gradient_target:
                    from refine_policy import anchored_halo_loss
                    halo_loss_value = anchored_halo_loss(
                        fake, a, aespa_target, self.halo_target, self.halo_sigma_ring,
                        self.halo_sigma_back, self.halo_bright_fraction)
                calibrating_colour = (
                    self._aespa_colour_calibration_count
                    < self.aespa_colour_calibration_steps)
                need_colour_base = calibrating_colour or diagnose
                colour_reference_loss = (self.nce_a_scale*nce_a
                    + weighted_global + weighted_patch
                    + weighted_dreamsim_global + weighted_dreamsim_patch)
                colour_base_grad = (gradient_rms(colour_reference_loss, params)
                                    if need_colour_base else None)
                if calibrating_colour:
                    if aespa_low_loss is not None:
                        raw = gradient_rms(aespa_low_loss, params)
                        self._aespa_colour_calibration_low.append(
                            float(colour_base_grad) / max(float(raw), 1e-16))
                    if painting_colour_loss is not None:
                        raw = gradient_rms(painting_colour_loss, params)
                        self._aespa_colour_calibration_painting.append(
                            float(colour_base_grad) / max(float(raw), 1e-16))
                    if aespa_chroma_loss is not None:
                        try:
                            raw = gradient_rms(aespa_chroma_loss, params)
                        except AssertionError:
                            raw = None
                        if raw is not None:
                            self._aespa_colour_calibration_chroma.append(
                                float(colour_base_grad)
                                / max(float(raw), 1e-16))
                    if halo_loss_value is not None:
                        try:
                            raw = gradient_rms(halo_loss_value, params)
                        except AssertionError:
                            raw = None
                        if raw is not None:
                            self._aespa_colour_calibration_halo.append(
                                float(colour_base_grad)
                                / max(float(raw), 1e-16))
                    self._aespa_colour_calibration_count += 1
                    if (self._aespa_colour_calibration_count
                            >= self.aespa_colour_calibration_steps):
                        if self.aespa_low_gradient_target:
                            ratio = _median(self._aespa_colour_calibration_low)
                            self.aespa_low_scale = (
                                self.aespa_low_gradient_target * ratio)
                        if self.painting_colour_gradient_target:
                            ratio = _median(
                                self._aespa_colour_calibration_painting)
                            self.painting_colour_scale = (
                                self.painting_colour_gradient_target * ratio)
                        if (self.aespa_chroma_gradient_target
                                and self._aespa_colour_calibration_chroma):
                            ratio = _median(
                                self._aespa_colour_calibration_chroma)
                            self.aespa_chroma_scale = (
                                self.aespa_chroma_gradient_target * ratio)
                        if (self.halo_gradient_target
                                and self._aespa_colour_calibration_halo):
                            ratio = _median(
                                self._aespa_colour_calibration_halo)
                            self.halo_scale = (
                                self.halo_gradient_target * ratio)
                        print(json.dumps({
                            "aespa_colour_calibration_steps":
                                self._aespa_colour_calibration_count,
                            "aespa_low_ratio":
                                _median(self._aespa_colour_calibration_low),
                            "painting_colour_ratio":
                                _median(
                                    self._aespa_colour_calibration_painting),
                            "aespa_low_scale": self.aespa_low_scale,
                            "painting_colour_scale":
                                self.painting_colour_scale,
                            "aespa_chroma_ratio":
                                _median(self._aespa_colour_calibration_chroma),
                            "aespa_chroma_scale":
                                self.aespa_chroma_scale,
                            "halo_ratio":
                                _median(self._aespa_colour_calibration_halo),
                            "halo_scale":
                                self.halo_scale}), flush=True)
                else:
                    if self.aespa_low_gradient_target:
                        weighted_aespa_low = (
                            self.aespa_low_scale * aespa_low_loss)
                        aespa_low_effective = gan.new_tensor(
                            self.aespa_low_scale)
                    if self.painting_colour_gradient_target:
                        weighted_painting_colour = (
                            self.painting_colour_scale
                            * painting_colour_loss)
                        painting_colour_effective = gan.new_tensor(
                            self.painting_colour_scale)
                    if (self.aespa_chroma_gradient_target
                            and self.aespa_chroma_scale is not None):
                        weighted_aespa_chroma = (
                            self.aespa_chroma_scale * aespa_chroma_loss)
                        aespa_chroma_effective = gan.new_tensor(
                            self.aespa_chroma_scale)
                    if (self.halo_gradient_target
                            and self.halo_scale is not None):
                        weighted_halo = self.halo_scale * halo_loss_value
                        halo_effective = gan.new_tensor(self.halo_scale)
                if diagnose:
                    values = {
                        "aespa_low_scale": (
                            0.0 if self.aespa_low_scale is None
                            else self.aespa_low_scale),
                        "painting_colour_scale": (
                            0.0 if self.painting_colour_scale is None
                            else self.painting_colour_scale),
                        "aespa_low_effective_weight": aespa_low_effective,
                        "painting_colour_effective_weight":
                            painting_colour_effective,
                        "aespa_chroma_effective_weight":
                            aespa_chroma_effective,
                        "halo_effective_weight": halo_effective}
                    if (not calibrating_colour
                            and aespa_low_loss is not None
                            and self.aespa_low_scale is not None):
                        values["grad_aespa_low_ratio_A"] = float(
                            gradient_rms(weighted_aespa_low, params)) / max(
                                float(colour_base_grad), 1e-16)
                    if (not calibrating_colour
                            and painting_colour_loss is not None
                            and self.painting_colour_scale is not None):
                        values["grad_painting_colour_ratio_A"] = float(
                            gradient_rms(weighted_painting_colour, params)
                        ) / max(float(colour_base_grad), 1e-16)
                    if (not calibrating_colour
                            and aespa_chroma_loss is not None
                            and self.aespa_chroma_scale is not None):
                        values["grad_aespa_chroma_ratio_A"] = float(
                            gradient_rms(weighted_aespa_chroma, params)
                        ) / max(float(colour_base_grad), 1e-16)
                    if (not calibrating_colour
                            and halo_loss_value is not None
                            and self.halo_scale is not None):
                        values["grad_halo_ratio_A"] = float(
                            __import__("refine_policy").gradient_rms_or_zero(weighted_halo, params)
                        ) / max(float(colour_base_grad), 1e-16)
                    diagnostics.update(values)
            _backward(base_a + weighted_distill + weighted_score
                      + weighted_aespa_feature + weighted_aespa_l2
                      + weighted_dreamsim_global + weighted_dreamsim_patch
                      + weighted_aespa_low + weighted_painting_colour
                      + weighted_aespa_chroma + weighted_halo)
            parts = {"G_GAN_raw": gan_raw.detach(),
                     "G_GAN": gan.detach(), "NCE": nce_a.detach(),
                     "NCE_raw": self._last_nce_raw,
                     "D": d_loss.detach(), "D_real": d_real.detach(), "D_fake": d_fake.detach()}
            parts.update(VGG_global_raw=global_style.detach(),VGG_patch_raw=local_style.detach(),
                         VGG_global_weighted=weighted_global.detach(),VGG_patch_weighted=weighted_patch.detach(),
                         VGG_global_weight=global_weight_tensor,VGG_patch_weight=patch_weight_tensor,
                         VGG_global_gradient_ratio=realized_global_tensor,VGG_patch_gradient_ratio=realized_patch_tensor,
                         saturation_fraction=((fake.detach()<.001)|(fake.detach()>.999)).float().mean())
            if distill_loss is not None:
                parts.update(Distill_raw=distill_loss.detach(),
                             Distill_weighted=weighted_distill.detach(),
                             Distill_effective_weight=distill_effective_weight.detach())
                if distill_hf is not None:
                    parts.update(Distill_HF_raw=distill_hf.detach(),
                                 Distill_REL_raw=distill_rel.detach())
                for name, value in (("Distill_COH_raw", distill_coh),
                                    ("Distill_ENERGY_raw", distill_energy),
                                    ("Distill_LOW_raw", distill_low),
                                    ("Distill_CHROMA_raw", distill_chroma),
                                    ("Distill_BROADBAND_raw", distill_broadband),
                                    ("Distill_CONTRAST_raw", distill_contrast),
                                    ("Distill_REPETITION_raw", distill_repetition),
                                    ("Distill_COLOUR_raw", distill_colour),
                                    ("Distill_FLOW_raw", distill_flow),
                                    ("Distill_SWD_raw", distill_swd),
                                    ("Distill_LOCALGRAM_raw", distill_localgram),
                                    ("Distill_JUDGE_raw", distill_judge),
                                    ("Distill_BAND_raw", distill_band),
                                    ("Distill_SHAPE_raw", distill_shape),
                                    ("Distill_FLAT_raw", distill_flat),
                                    ("Distill_FLATCONTRAST_raw", flat_contrast),
                                    ("Distill_FLATFLOW_raw", flat_flow)):
                    if value is not None:
                        parts[name] = value.detach()
            if distill_score is not None:
                parts.update(Distill_SCORE_raw=distill_score.detach(),
                             SCORE_weighted=weighted_score.detach(),
                             SCORE_effective_weight=score_effective_weight.detach(),
                             score_mean=score_mean)
            if aespa_feature_loss is not None:
                parts.update(AesPA_FEATURE_raw=aespa_feature_loss.detach(),
                             AesPA_FEATURE_weighted=weighted_aespa_feature.detach(),
                             AesPA_FEATURE_effective_weight=aespa_feature_effective_weight.detach())
            if aespa_l2_loss is not None:
                parts.update(AesPA_L2_raw=aespa_l2_loss.detach(),
                             AesPA_L2_weighted=weighted_aespa_l2.detach(),
                             AesPA_L2_effective_weight=aespa_l2_effective_weight.detach())
            if dreamsim_global_loss is not None:
                parts.update(DreamSim_GLOBAL_raw=dreamsim_global_loss.detach(),
                             DreamSim_GLOBAL_weighted=weighted_dreamsim_global.detach(),
                             DreamSim_GLOBAL_effective_weight=dreamsim_global_effective.detach())
            if dreamsim_patch_loss is not None:
                parts.update(DreamSim_PATCH_raw=dreamsim_patch_loss.detach(),
                             DreamSim_PATCH_weighted=weighted_dreamsim_patch.detach(),
                             DreamSim_PATCH_effective_weight=dreamsim_patch_effective.detach())
            if aespa_low_loss is not None:
                parts.update(AesPA_LOW_raw=aespa_low_loss.detach(),
                             AesPA_LOW_weighted=weighted_aespa_low.detach(),
                             AesPA_LOW_effective_weight=
                                 aespa_low_effective.detach())
            if painting_colour_loss is not None:
                parts.update(PAINTING_COLOUR_raw=painting_colour_loss.detach(),
                             PAINTING_COLOUR_weighted=
                                 weighted_painting_colour.detach(),
                             PAINTING_COLOUR_effective_weight=
                                 painting_colour_effective.detach())
            if aespa_chroma_loss is not None:
                parts.update(AesPA_CHROMA_raw=aespa_chroma_loss.detach(),
                             AesPA_CHROMA_weighted=
                                 weighted_aespa_chroma.detach(),
                             AesPA_CHROMA_effective_weight=
                                 aespa_chroma_effective.detach())
            if halo_loss_value is not None:
                parts.update(HALO_raw=halo_loss_value.detach(),
                             HALO_weighted=weighted_halo.detach(),
                             HALO_effective_weight=halo_effective.detach())
            parts.update(diagnostics)
            del fake, gan, nce_a, d_loss, d_real, d_fake,global_style,local_style,weighted_global,weighted_patch,base_a
            if teacher_fake is not None:
                del teacher_fake
            if student_body_stages is not None:
                del student_body_stages
            if teacher_body_stages is not None:
                del teacher_body_stages
            # Accumulate identity gradients before either G or F optimizer steps.
            # This releases the A graph before allocating the B graph.
            with auxiliary_batch_stats(self.generator):
                identity = self.generator(b)
            nce_b = self._nce(b, identity)
            if diagnose:
                parts["grad_NCE_Y_weighted"] = gradient_rms(self.nce_y_scale*nce_b, params)
            _backward(self.nce_y_scale*nce_b)
            parts["NCE_Y"] = nce_b.detach()
            parts["NCE_Y_raw"] = self._last_nce_raw
            parts["G"] = parts["G_GAN"] + self.nce_a_scale * parts["NCE"] + self.nce_y_scale * parts["NCE_Y"]
            parts["G"] += parts["VGG_global_weighted"] + parts["VGG_patch_weighted"]
            if "Distill_weighted" in parts:
                parts["G"] += parts["Distill_weighted"]
            if "DreamSim_GLOBAL_weighted" in parts:
                parts["G"] += parts["DreamSim_GLOBAL_weighted"]
            if "DreamSim_PATCH_weighted" in parts:
                parts["G"] += parts["DreamSim_PATCH_weighted"]
            if "AesPA_LOW_weighted" in parts:
                parts["G"] += parts["AesPA_LOW_weighted"]
            if "PAINTING_COLOUR_weighted" in parts:
                parts["G"] += parts["PAINTING_COLOUR_weighted"]
            if "AesPA_CHROMA_weighted" in parts:
                parts["G"] += parts["AesPA_CHROMA_weighted"]
            if "HALO_weighted" in parts:
                parts["G"] += parts["HALO_weighted"]
            del identity, nce_b
            _optimizer_step(self.optimizers["G"])
            _optimizer_step(self.optimizers["F"])
            result = _numbers(parts)
        return result
