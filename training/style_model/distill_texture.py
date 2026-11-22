"""Strong, phase-tolerant texture distillation for the half-size generators.

Why this exists
---------------
Every half-size candidate so far keeps colour and outline and loses the
brushstroke.  Measured on the fixed landscape frame, in the sky and in absolute
terms, the v1 reference amplifies the fine-scale contrast to about 2.9x the
input, while v2e reaches only about 1.4x; the gap is broadband (it is the same
factor at every fine scale), and the strongest orientation of the texture does
not match the reference either.

A pixel-aligned high-frequency loss cannot close that gap, because it asks the
student to reproduce the teacher's strokes at the teacher's exact phase.  That
target is unreachable for a smaller model, so the residual is large everywhere
and the gradient mostly teaches blur.  This is what the earlier ``haar_hf`` and
``hf_rel`` runs did, and their ``Distill_HF_raw`` never moved.

What is learnable is the teacher's *oriented energy*: how much contrast, in
which direction, at which scale, and where.  All four statistics below are
invariant to stroke phase, so the student is free to place strokes where its own
features allow, while still being told what the reference does there.

Terms
-----
``texture_stat_loss``
    Multi-scale Gabor pyramid on the luminance; matches the spatially resolved
    per-orientation energy field of student against teacher, each filter
    normalised by its own teacher mean so every orientation counts equally.
``coherence_loss``
    Normalised cross-orientation correlation of those energy fields.  Two
    images can have identical average orientation energy while one is made of
    coherent strokes and the other of isotropic grain; this term separates
    them, which is exactly the "coherent stroke vs broken texture" difference
    reported for the previous candidates.
``low_frequency_loss``
    Blurred-output L1.  It protects colour and large structure while the two
    terms above concentrate on the fine scales.

None of these introduce trainable parameters and none of them are used at
inference.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import torch
from torch import nn
from torch.nn import functional as F


ORIENTATIONS = 12

# (pyramid level, kernel size, wavelength in that level's pixels, gaussian sigma).
# Level 0 is the image at its own resolution, so the two kernels cover periods of
# about 2.6 and 5 px; level 1 halves the resolution, so they cover about 5 and
# 10 px.  Level 2 halves it again -- 10.4 and 20 px at the image's own resolution
# -- and is used when COARSE_LEVEL_WEIGHT is set, because a radial measurement of
# the decoded demo found the 12-16 px band at only 0.71 of the reference's power
# while the 4.5-9 px bands sat at 1.32-1.44.  It is *off by default*: the first
# preflight with it added as an extra weighted level pulled the whole distill mix
# toward texture (judge -0.050 -> -0.059 and every band down), because the block's
# total gradient is normalised and the added level diluted everything else.
FILTERS = (
    (0, 9, 2.6, 1.3),
    (0, 15, 5.0, 2.5),
    (1, 9, 2.6, 1.3),
    (1, 15, 5.0, 2.5),
    (2, 9, 2.6, 1.3),
    (2, 15, 5.0, 2.5),
)
KERNELS_PER_LEVEL = 2
LEVELS = 3

# Share of the coarse level inside the texture terms.  0 (the default) keeps the
# two-level behaviour exactly.  Per-level weights: with 0.0 the two original
# levels are averaged as before; with a positive value the coarse level is added
# on top rather than re-averaged, so the fine-scale pressure does not weaken.
COARSE_LEVEL_WEIGHT = 0.0
COARSE_LEVEL = 2
LEVEL_COUNT = 2

# The stroke band the radial decomposition found short, as sigmas of a difference
# of Gaussians: periods of roughly 9-16 px, which is what "the strokes are not yet
# as strong as the reference's" measures out to.
COARSE_BAND = (1.2, 2.5)

# The spectral-shape term: sigmas of the difference-of-Gaussians chain whose
# relative energies have to match the teacher's.  Consecutive differences give
# bands of roughly 1.5-3, 3-6.5, 6.5-13 and 13-26 px, which spans the range the
# radial decomposition covers.  Per-band *floors* (stroke_contrast_loss,
# band_contrast_loss) only ever add energy, and the student adds it where it is
# cheapest: pushing the coarse band from 0.43 to 0.63 of the reference raised the
# 4.5-9 px bands from 0.91/1.36 to 1.53/2.25 at the same time.  Matching the
# normalised *distribution* is two-sided, so an over-supplied band is pulled down
# as well as an under-supplied one pulled up.
SHAPE_SIGMAS = (0.6, 1.2, 2.5, 5.0, 10.0)

# Local energy pooling window, in pixels of level 0.  Eight pixels spans one to
# three stroke periods, so the field says "here" without pinning a phase.
POOL = 8

# Weight of the coherence term inside the combined texture loss.
COHERENCE_WEIGHT = 0.25

PAD_MULTIPLE = 8

# The flat-content probe.  The corridor wall the user rejected measures an
# activity of 1e-5..1e-4 under ``smooth_region_mask``'s statistic, an order of
# magnitude below the sky band that every earlier detail metric watched, while the
# training content's own flattest 30 percent sits at 0.0097 at the median -- so the
# stroke-contrast target was never evaluated in the regime the wall lives in.
# Walking down that ladder on 48 training crops, the student holds or beats the
# teacher (1.00 raw, 1.33 at blur 8, 1.43 at blur 16, 1.61 at blur 32) and then
# collapses: 0.44 on a shallow ramp, 0.34 on an 8-bit staircase, 0.39 on twelve
# real wall crops.  A shallow *ramp* is not the right augmentation either -- the
# wall is not a ramp, it is a shallow field quantised to 8 bits, and the steps are
# what the teacher amplifies into strokes.  These constants reproduce it: blur the
# texture away, shrink the shading to a few percent of its contrast, quantise.
FLAT_SIGMA = 16.0
FLAT_SHRINK = 0.10
FLAT_LEVELS = 256.0


def flat_probe(content: torch.Tensor, sigma: float = FLAT_SIGMA,
               shrink: float = FLAT_SHRINK, levels: float = FLAT_LEVELS
               ) -> torch.Tensor:
    """Content reduced to what a painted wall is: a shallow 8-bit staircase.

    Used as an extra batch for the stroke-contrast target, so that target is
    measured in the activity range where the eye found the student going flat.
    """
    smooth = blur(content, sigma) if sigma > 0 else content
    if shrink < 1.0:
        centre = smooth.mean(dim=(-1, -2), keepdim=True)
        smooth = centre + (smooth - centre) * shrink
    if levels > 0:
        smooth = (smooth * levels).round() / levels
    return smooth


def _gabor(kernel_size: int, wavelength: float, sigma: float,
           orientation: int) -> torch.Tensor:
    axis = torch.arange(kernel_size, dtype=torch.float32) - (kernel_size - 1) / 2
    y, x = torch.meshgrid(axis, axis, indexing="ij")
    theta = math.pi * orientation / ORIENTATIONS
    along = x * math.cos(theta) + y * math.sin(theta)
    across = -x * math.sin(theta) + y * math.cos(theta)
    envelope = torch.exp(-(along ** 2 + across ** 2) / (2 * sigma ** 2))
    kernel = envelope * torch.cos(2 * math.pi * along / wavelength)
    kernel = kernel - kernel.mean()
    return kernel / kernel.abs().sum()


def build_bank(dtype=torch.float32):
    """Fixed [K, 1, size, size] filters per pyramid level, zero-padded to the max size.

    Returning one stacked tensor per level lets each level run as a single
    grouped-free convolution instead of one convolution per orientation.
    """
    size = max(entry[1] for entry in FILTERS)
    banks = []
    for level in range(LEVELS):
        rows = []
        for entry_level, kernel_size, wavelength, sigma in FILTERS:
            if entry_level != level:
                continue
            for orientation in range(ORIENTATIONS):
                kernel = _gabor(kernel_size, wavelength, sigma, orientation)
                pad = (size - kernel_size) // 2
                rows.append(F.pad(kernel[None, None], (pad, pad, pad, pad)))
        banks.append(torch.cat(rows, dim=0).to(dtype))
    return banks


def luma(image: torch.Tensor) -> torch.Tensor:
    weight = image.new_tensor([0.299, 0.587, 0.114])[None, :, None, None]
    return (image * weight).sum(dim=1, keepdim=True)


class TextureDescriptor(nn.Module):
    """Phase-invariant oriented-energy descriptor of an RGB01 image.

    ``forward`` returns one tensor per level with shape
    ``[batch, kernels_per_level, orientations, h, w]`` holding the local mean
    absolute Gabor response.
    """

    def __init__(self, pool: int = POOL, coherence_weight: float = COHERENCE_WEIGHT):
        super().__init__()
        self.pool = int(pool)
        self.coherence_weight = float(coherence_weight)
        for index, bank in enumerate(build_bank()):
            self.register_buffer(f"bank_{index}", bank)
        self.config = {"orientations": ORIENTATIONS, "filters": [list(f) for f in FILTERS],
                       "pool": self.pool, "coherence_weight": self.coherence_weight,
                       "space": "luma", "pad_multiple": PAD_MULTIPLE}

    def _pyramid(self, gray: torch.Tensor):
        height, width = gray.shape[-2:]
        pad_h, pad_w = (-height) % PAD_MULTIPLE, (-width) % PAD_MULTIPLE
        if pad_h or pad_w:
            gray = F.pad(gray, (0, pad_w, 0, pad_h), mode="replicate")
        levels = [gray]
        for _ in range(LEVELS - 1):
            levels.append(F.avg_pool2d(levels[-1], 2))
        return levels

    def forward(self, image: torch.Tensor):
        gray = luma(image)
        levels = self._pyramid(gray)
        fields = []
        for index in range(LEVELS):
            bank = getattr(self, f"bank_{index}")
            padding = (bank.shape[-1] - 1) // 2
            response = F.conv2d(levels[index], bank, padding=padding)
            batch, count, height, width = response.shape
            # Pool the magnitude: the mean absolute response over a window is a
            # local oriented energy, and it does not care where in the window the
            # stroke phase sits.
            window = max(1, self.pool >> index)
            pooled = F.avg_pool2d(response.abs().reshape(batch, count, height, width),
                                  window)
            fields.append(pooled.view(batch, KERNELS_PER_LEVEL, ORIENTATIONS,
                                      pooled.shape[-2], pooled.shape[-1]))
        return fields


def _level_mix(terms: list, coarse_weight: float = 0.0) -> torch.Tensor:
    """Mean over the fine levels, plus the coarse level on top when asked for.

    At the default 0.0 this is exactly the mean over ``LEVEL_COUNT`` levels, which
    is what every completed round used.  With a positive weight the coarse level
    is added rather than folded into the average, so the fine-scale pressure that
    the earlier rounds built does not weaken.
    """
    fine = sum(terms[:LEVEL_COUNT]) / LEVEL_COUNT
    coarse = terms[LEVEL_COUNT:]
    if coarse_weight and coarse:
        fine = fine + coarse_weight * sum(coarse) / len(coarse)
    return fine


def texture_stat_loss(descriptor: TextureDescriptor, student: torch.Tensor,
                      teacher: torch.Tensor,
                      coarse_weight: float = COARSE_LEVEL_WEIGHT) -> torch.Tensor:
    """Match the spatially resolved per-orientation energy field of two images."""
    student_fields = descriptor(student)
    with torch.no_grad():
        teacher_fields = descriptor(teacher)
    terms = []
    for student_field, teacher_field in zip(student_fields, teacher_fields):
        # Each filter is normalised by its own teacher mean, so a strong
        # orientation cannot dominate a weak one and the loss stays a relative
        # error in the same units for every scale.  The floor keeps a filter the
        # teacher leaves almost empty (a flat sky region has very little energy
        # in some orientations) from turning a near-zero mean into a huge gain.
        reference = teacher_field.detach()
        scale = reference.mean(dim=(0, 3, 4), keepdim=True)
        floor = 0.05 * reference.mean(dim=(0, 1, 3, 4), keepdim=True)
        scale = scale.clamp(min=floor) + 1e-6
        terms.append(((student_field - teacher_field).abs() / scale).mean())
    return _level_mix(terms, coarse_weight)


def coherence_loss(descriptor: TextureDescriptor, student: torch.Tensor,
                   teacher: torch.Tensor, weight: float = COHERENCE_WEIGHT,
                   coarse_weight: float = COARSE_LEVEL_WEIGHT) -> torch.Tensor:
    """Match cross-orientation correlation, which separates strokes from grain."""
    student_fields = descriptor(student)
    with torch.no_grad():
        teacher_fields = descriptor(teacher)
    terms = [_relation(student_field, teacher_field)
             for student_field, teacher_field in zip(student_fields, teacher_fields)]
    return weight * _level_mix(terms, coarse_weight)


def _relation(student_field: torch.Tensor, teacher_field: torch.Tensor) -> torch.Tensor:
    def normalised(field):
        batch, kernels, orientations, height, width = field.shape
        values = field.reshape(batch * kernels, orientations, height * width)
        values = values - values.mean(dim=2, keepdim=True)
        values = values / (values.norm(dim=2, keepdim=True) + 1e-6)
        return torch.bmm(values, values.transpose(1, 2))

    student_relation = normalised(student_field)
    with torch.no_grad():
        teacher_relation = normalised(teacher_field)
    return F.l1_loss(student_relation, teacher_relation)


LOW_SIGMA = 6.0
CHROMA_SIGMA = 8.0
CHROMA_BASE_SIGMA = 32.0


def _gaussian_kernel(sigma: float, device, dtype) -> torch.Tensor:
    radius = int(3 * sigma)
    axis = torch.arange(-radius, radius + 1, dtype=dtype, device=device)
    kernel = torch.exp(-axis ** 2 / (2 * sigma ** 2))
    return kernel / kernel.sum()


def _blur(x: torch.Tensor, kernel: torch.Tensor) -> torch.Tensor:
    """Separable Gaussian blur; the kernel is shared by all channels."""
    radius = (kernel.numel() - 1) // 2
    channels = x.shape[1]
    vertical = kernel.view(1, 1, -1, 1).expand(channels, 1, -1, 1)
    x = F.conv2d(F.pad(x, (0, 0, radius, radius), mode="reflect"), vertical,
                 groups=channels)
    horizontal = kernel.view(1, 1, 1, -1).expand(channels, 1, 1, -1)
    return F.conv2d(F.pad(x, (radius, radius, 0, 0), mode="reflect"), horizontal,
                    groups=channels)


def blur(x: torch.Tensor, sigma: float) -> torch.Tensor:
    """Gaussian blur of a tensor, building the kernel from the sigma."""
    return _blur(x, _gaussian_kernel(sigma, x.device, x.dtype))


def _hann2d(height: int, width: int, dtype, device) -> torch.Tensor:
    """Separable Hann window, so non-square frames are handled correctly."""
    rows = torch.hann_window(height, periodic=False, dtype=dtype, device=device)
    columns = torch.hann_window(width, periodic=False, dtype=dtype, device=device)
    return rows[:, None] * columns[None, :]


def low_frequency_loss(student: torch.Tensor, teacher: torch.Tensor,
                       sigma: float = LOW_SIGMA) -> torch.Tensor:
    """Blurred-output L1, normalised by the teacher's own mean brightness.

    The blur has to be a real low-pass: a small box filter still passes the
    stroke band, and then this term would fight the texture terms instead of
    only protecting colour and large structure.  With sigma 6 the whole stroke
    band is suppressed by more than four orders of magnitude.  The first and last
    ``3*sigma`` pixels are dropped, because there the padding, not the image,
    decides the blur.
    """
    kernel = _gaussian_kernel(sigma, student.device, student.dtype)
    student_low = _blur(student, kernel)
    with torch.no_grad():
        teacher_low = _blur(teacher, kernel)
    margin = min(int(3 * sigma), min(student.shape[-2:]) // 4)
    if margin:
        student_low = student_low[..., margin:-margin, margin:-margin]
        teacher_low = teacher_low[..., margin:-margin, margin:-margin]
    scale = teacher_low.detach().abs().mean() + 1e-6
    return (student_low - teacher_low).abs().mean() / scale


def halo_loss(student: torch.Tensor, target: float = 0.048,
              sigma_ring: float = 4.0, sigma_back: float = 12.0,
              bright_fraction: float = 0.01, tau: float = 0.005) -> torch.Tensor:
    """One-sided warm-ring floor around the brightest pixels.

    A difference of Gaussians on the warm axis is positive when a warm ring
    surrounds a bright spot, and ~0 for a uniform warm cast.  The mask is the
    top ``bright_fraction`` of luma, softened so the ring receives gradient.
    The target 0.048 is the reference halo image's own score at 256x256; the
    from-scratch student measures about 0.033, so the term only pushes up.
    """
    red, green, blue = student[:, 0:1], student[:, 1:2], student[:, 2:3]
    warm = (red + green) / 2 - blue
    luma = 0.299 * red + 0.587 * green + 0.114 * blue
    ring = blur(warm, sigma_ring) - blur(warm, sigma_back)
    flat = luma.flatten(1)
    threshold = torch.quantile(flat, 1.0 - bright_fraction, dim=1)
    mask = torch.sigmoid((luma - threshold[:, None, None]) / tau)
    score = ((ring * mask).sum(dim=(1, 2, 3))
             / (mask.sum(dim=(1, 2, 3)) + 1e-6))
    return torch.relu(target - score).mean()


SPECTRAL_SIGMA_LO = 1.6
SPECTRAL_SIGMA_HI = 9.0
# Frequency band to score, in cycles per pixel: the stroke band the descriptor
# above also covers.
SPECTRAL_LOW = 0.09
SPECTRAL_HIGH = 0.45


def stroke_band(gray: torch.Tensor, sigma_lo: float = SPECTRAL_SIGMA_LO,
                sigma_hi: float = SPECTRAL_SIGMA_HI) -> torch.Tensor:
    return blur(gray, sigma_lo) - blur(gray, sigma_hi)


def spectral_entropy(band: torch.Tensor, low: float = SPECTRAL_LOW,
                     high: float = SPECTRAL_HIGH) -> torch.Tensor:
    """Entropy of the normalised power spectrum inside the stroke band.

    Low entropy means the band's energy has collapsed into a few frequency and
    orientation cells, which is what a repeating pattern is.
    """
    height, width = band.shape[-2:]
    window = _hann2d(height, width, band.dtype, band.device)
    windowed = band * window[None, None]
    spectrum = torch.fft.fftshift(torch.fft.fft2(windowed), dim=(-2, -1)).abs() ** 2
    cy, cx = height // 2, width // 2
    ky = (torch.arange(height, dtype=band.dtype, device=band.device) - cy)[:, None] / height
    kx = (torch.arange(width, dtype=band.dtype, device=band.device) - cx)[None, :] / width
    radius = torch.sqrt(ky ** 2 + kx ** 2)
    mask = ((radius >= low) & (radius <= high)).view(1, 1, height, width)
    values = spectrum * mask
    probability = values / (values.sum(dim=(2, 3), keepdim=True) + 1e-12)
    entropy = -(probability * (probability + 1e-12).log()).sum(dim=(2, 3))
    return entropy.mean()


def broadbandness_loss(student: torch.Tensor, teacher: torch.Tensor) -> torch.Tensor:
    """Ask for a stroke band at least as broadband as the teacher's.

    This is the term for the failure the eye named last: the step-13000 student
    does have texture, but it reads as a repeated pattern rather than as
    brushwork.  A repeat is periodic, so its power spectrum concentrates, and the
    energy and orientation statistics above cannot see the difference -- a
    periodic pattern has the same energy and the same orientation as an irregular
    one of equal strength.  Measured on the demo frames the stroke band's spectral
    entropy is 5.73 for the reference, 5.58 for the round-1 student and 5.44 for
    v2e, with peak-to-mean 404 against 474, so the statistic orders the candidates
    the way the eye does.

    One-sided, like the accent term: being *more* broadband than the teacher is
    the painterly direction (AESPA and the painting both measure higher), so only
    a shortfall is penalised.
    """
    student_entropy = spectral_entropy(stroke_band(luma(student)))
    with torch.no_grad():
        teacher_entropy = spectral_entropy(stroke_band(luma(teacher)))
    shortfall = torch.relu(teacher_entropy - student_entropy)
    return shortfall / (teacher_entropy.detach().abs() + 1e-6)


REPETITION_PATCH = 24
REPETITION_STRIDE = 8
REPETITION_EXCLUSION = 3


def patch_self_similarity(image: torch.Tensor, patch: int = REPETITION_PATCH,
                          stride: int = REPETITION_STRIDE,
                          exclusion: int = REPETITION_EXCLUSION) -> torch.Tensor:
    """How close each stroke-band patch is to its best match elsewhere.

    This is the statistic for the failure the eye named as repeated texture, and
    it is the one that orders the candidates the way the eye does.  Measured as
    the fraction of patches that have a near-duplicate elsewhere in the frame:
    the painting scores 0.002, AESPA 0.002, the reference generator 0.021 and the
    round-1 student 0.018, while v2e at step 13000 scores 0.061 and at step 20000
    scores 0.098.  On the demo frames the same numbers are 0.104 for the reference
    and 0.224 for v2e.  Spectral entropy points the same way but far more weakly,
    because a patch can be duplicated without the spectrum concentrating.
    """
    band = stroke_band(luma(image))
    batch = band.shape[0]
    unfolded = band.unfold(2, patch, stride).unfold(3, patch, stride)
    rows, columns = unfolded.shape[2], unfolded.shape[3]
    flat = unfolded.reshape(batch, rows * columns, patch * patch)
    flat = flat - flat.mean(dim=2, keepdim=True)
    flat = flat / (flat.norm(dim=2, keepdim=True) + 1e-8)
    similarity = torch.bmm(flat, flat.transpose(1, 2))
    grid = torch.stack(torch.meshgrid(torch.arange(rows, device=band.device),
                                      torch.arange(columns, device=band.device),
                                      indexing="ij"), dim=-1).reshape(-1, 2)
    distance = (grid[:, None, :] - grid[None, :, :]).abs().max(dim=-1).values
    # Overlapping neighbours match trivially; they carry no information about
    # repetition, so they are excluded from the search.
    similarity = similarity.masked_fill(distance <= exclusion, -1.0)
    return similarity.max(dim=2).values.mean()


def repetition_loss(student: torch.Tensor, teacher: torch.Tensor) -> torch.Tensor:
    """Ask for no more self-similarity than the teacher has.

    One-sided for the same reason as the accent term: less repetition than the
    reference is the painterly direction, so only an excess is penalised.  The
    gradient is sparse by construction -- it pushes each patch away from its
    closest duplicate -- which is exactly the repair the texture needs.
    """
    student_score = patch_self_similarity(student)
    with torch.no_grad():
        teacher_score = patch_self_similarity(teacher)
    excess = torch.relu(student_score - teacher_score)
    return excess / (teacher_score.detach().abs() + 1e-6)


SMOOTH_REGION_KEEP = 0.30


def smooth_region_mask(content: torch.Tensor, keep: float = SMOOTH_REGION_KEEP,
                       sigma: float = 3.0) -> torch.Tensor:
    """Mask of the smoothest ``keep`` fraction of the content, as [B,1,H,W].

    Computed from the *content* image, so it is a constant with respect to the
    generator and gradients only flow through the pixels it selects.

    The distilled terms have to be scored where the eye looks.  A 256x256 training
    crop is mostly not sky, so a warm-accent statistic taken over the whole crop can
    be paid for by warm buildings or foliage while the sky goes cold -- measured at
    step 14000 the accent loss still read 0.54 while the warm peak in the sky had
    fallen to -0.072 against the reference's +0.144.  The complaint has been about
    smooth regions from the start, so the terms are restricted to them.
    """
    gray = luma(content)
    kernel_y = torch.tensor([-0.5, 0.0, 0.5], dtype=gray.dtype,
                            device=gray.device).view(1, 1, 3, 1)
    kernel_x = kernel_y.view(1, 1, 1, 3)
    dy = F.conv2d(F.pad(gray, (0, 0, 1, 1), mode="reflect"), kernel_y)
    dx = F.conv2d(F.pad(gray, (1, 1, 0, 0), mode="reflect"), kernel_x)
    activity = blur((dy * dy + dx * dx).sqrt(), sigma)
    flat = activity.flatten(1)
    count = max(1, int(keep * flat.shape[1]))
    threshold = flat.topk(count, dim=1, largest=False).values[:, -1:]
    return (flat <= threshold).reshape_as(activity)


def _masked_statistics(field: torch.Tensor, mask: torch.Tensor,
                       fraction: float) -> tuple:
    """Mean and top-fraction mean of ``field`` over the selected pixels only."""
    selected = mask.expand_as(field)
    total = selected.sum()
    mean = (field * selected).sum() / (total + 1e-6)
    count = max(1, int(fraction * float(total.item())))
    flat = field.masked_fill(~selected, -1e4).flatten()
    top = flat.topk(count).values.mean()
    return mean, top


def _masked_std(values: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
    selected = mask.expand_as(values)
    count = selected.sum()
    mean = (values * selected).sum() / (count + 1e-6)
    variance = ((values - mean).square() * selected).sum() / (count + 1e-6)
    # Floor inside the sqrt: a uniform region has exactly zero variance, and
    # sqrt(0) has an infinite derivative.
    return variance.clamp(min=1e-12).sqrt()


COLOUR_BINS = 24
COLOUR_SPAN = 1.0


def colour_distribution(image: torch.Tensor, bins: int = COLOUR_BINS,
                        span: float = COLOUR_SPAN) -> torch.Tensor:
    """Soft 2D histogram of the opponent plane (R-G, G-B), as a distribution.

    This is the colour *proportion* of the image: where the mass sits, not where
    any particular colour is.  Built with Gaussian binning so it is differentiable
    and cheap, and normalised so it does not depend on the image size.
    """
    red, green, blue = image[:, 0:1], image[:, 1:2], image[:, 2:3]
    centres = torch.linspace(-span, span, bins, dtype=image.dtype, device=image.device)
    width = (2 * span) / (bins - 1)
    weights = []
    for axis in (red - green, green - blue):
        values = axis.flatten(1)
        distance = values[:, :, None] - centres[None, None, :]
        weights.append(torch.exp(-0.5 * (distance / width) ** 2))
    joint = torch.einsum("bnk,bnl->bkl", weights[0], weights[1])
    return joint / (joint.sum(dim=(1, 2), keepdim=True) + 1e-12)


def colour_reference_from_file(path) -> torch.Tensor:
    """The target distribution: the painting's own colour proportions."""
    import numpy as np
    from PIL import Image
    with Image.open(path) as image:
        array = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    tensor = torch.from_numpy(array).permute(2, 0, 1)[None]
    return colour_distribution(tensor)[0]


def colour_distribution_loss(student: torch.Tensor,
                            reference: torch.Tensor) -> torch.Tensor:
    """L1 distance between the image's colour proportions and the painting's.

    Two-sided on purpose, and it is the one term where that is right: the user
    asked for the proportions to *match*, so too little warmth is wrong and so is
    too much.  Unlike the field-matching terms it cannot be gamed by moving or
    smearing colour, because it compares only how much mass sits where.
    """
    histogram = colour_distribution(student)
    if reference.dim() == 2:
        reference = reference[None]
    reference = reference.to(histogram.device, histogram.dtype)
    return (histogram - reference).abs().sum(dim=(1, 2)).mean()


FLOW_LAGS = (4, 8, 16, 32)
FLOW_WINDOW = 6.0


def orientation_flow(image: torch.Tensor, lags: tuple = FLOW_LAGS,
                     window: float = FLOW_WINDOW) -> torch.Tensor:
    """Normalised correlation of the local stroke orientation at increasing lags.

    The local orientation is the double-angle vector v = (jxx - jyy, 2 jxy) of the
    stroke band, normalised to unit length, so the product of two of them is
    cos(2*dtheta).  A field of long, continuous strokes keeps pointing the same way
    over that distance and scores near one at every lag; unstructured noise drops
    towards zero.  Measured at 32px: reference generator 0.651, AESPA 0.707,
    round-1 and round-7 students 0.520.
    """
    band = stroke_band(luma(image))
    kernel_y = torch.tensor([-0.5, 0.0, 0.5], dtype=band.dtype,
                            device=band.device).view(1, 1, 3, 1)
    kernel_x = kernel_y.view(1, 1, 1, 3)
    dy = F.conv2d(F.pad(band, (0, 0, 1, 1), mode="reflect"), kernel_y)
    dx = F.conv2d(F.pad(band, (1, 1, 0, 0), mode="reflect"), kernel_x)
    jyy = blur(dy * dy, window)
    jxx = blur(dx * dx, window)
    jxy = blur(dy * dx, window)
    vector = torch.cat((jxx - jyy, 2 * jxy), dim=1)
    # The floor matters: sqrt(0) has an infinite derivative, and a perfectly
    # isotropic patch has exactly zero strength, so the raw sqrt gives a NaN
    # gradient even though the loss itself is finite.
    strength = vector.square().sum(dim=1, keepdim=True).add(1e-12).sqrt()
    # Scale-relative floor: on a nearly flat crop the strength is near zero and a
    # fixed epsilon would leave the normalisation dividing by almost nothing.
    vector = vector / (strength + 1e-3 * strength.amax() + 1e-9)
    # Only patches that carry oriented energy say anything about flow.
    active = (strength > strength.median()).float()
    profile = []
    for lag in lags:
        left = vector[..., :-lag, :-lag]
        right = vector[..., lag:, lag:]
        weight = (strength[..., :-lag, :-lag] * strength[..., lag:, lag:]
                  * active[..., :-lag, :-lag] * active[..., lag:, lag:])
        product = (left * right).sum(dim=1, keepdim=True)
        denominator = weight.sum() + 1e-3 * weight.amax() + 1e-9
        profile.append((product * weight).sum() / denominator)
    return torch.stack(profile)


def orientation_flow_loss(student: torch.Tensor,
                          teacher: torch.Tensor) -> torch.Tensor:
    """Ask for at least the reference's orientation continuity.

    One-sided, like the other structural terms: more continuity than the reference
    is the painterly direction (AESPA measures higher than the reference), so only a
    shortfall is penalised.  This is the term for the complaint that the strokes
    must read as drawn with a brush rather than as an unorganised texture.
    """
    student_profile = orientation_flow(student)
    with torch.no_grad():
        teacher_profile = orientation_flow(teacher)
    shortfall = torch.relu(teacher_profile.detach() - student_profile)
    return (shortfall / (teacher_profile.detach().abs() + 1e-6)).mean()


SWD_LAYERS = (2, 3)          # relu3_1 and relu4_1 of the project's extraction
SWD_PROJECTIONS = 128
SWD_QUANTILES = 64


def style_directions(channels, projections: int = SWD_PROJECTIONS,
                     seed: int = 20260923):
    """Fixed random projection directions, one matrix per channel count.

    Fixed, not resampled per step: the loss then estimates one well-defined
    quantity, and its gradient does not carry projection noise.
    """
    generator = torch.Generator().manual_seed(seed)
    out = []
    for count in channels:
        directions = torch.randn(int(count), projections, generator=generator)
        out.append(directions / directions.norm(dim=0, keepdim=True))
    return out


def to_luma_image(image: torch.Tensor) -> torch.Tensor:
    """Luminance replicated to three channels, for the VGG.

    Splitting texture from colour matters because a colour gain can pay for a
    combined RGB style distance: on the demo video the student's RGB SWD was level
    with the reference generator (0.707 against 0.714) while its luminance-only SWD
    was clearly worse (0.560 against 0.512).  The colour terms handle colour; this is
    the texture-only view.
    """
    return luma(image).repeat(1, 3, 1, 1)


def style_tensor_from_file(path, size: int = 256) -> torch.Tensor:
    """The painting as a [1,3,size,size] tensor, at the size the style crops use."""
    import numpy as np
    from PIL import Image
    with Image.open(path) as image:
        image = image.convert("RGB").resize((size, size), Image.BILINEAR)
    array = np.asarray(image, dtype=np.float32) / 255.0
    return torch.from_numpy(array).permute(2, 0, 1)[None]


def _quantile_curve(sorted_values: torch.Tensor, count: int) -> torch.Tensor:
    """The empirical quantile function of a sorted tensor, on a fixed grid.

    Sampling the curve at fixed probabilities, rather than comparing every element,
    is what makes the loss independent of how many pixels each image has.
    """
    total = sorted_values.shape[0]
    positions = torch.linspace(0, total - 1, count, dtype=sorted_values.dtype,
                               device=sorted_values.device)
    low = positions.floor().long()
    high = (low + 1).clamp(max=total - 1)
    fraction = (positions - low).unsqueeze(1)
    return sorted_values[low] * (1.0 - fraction) + sorted_values[high] * fraction


def sliced_wasserstein_style_loss(student_features, reference_features, directions,
                                  layers: tuple = SWD_LAYERS,
                                  quantiles: int = SWD_QUANTILES) -> torch.Tensor:
    """Sliced Wasserstein distance between the feature clouds and the painting's.

    Measured on the same content and size, this is the VGG judgement whose ordering
    matches the eye: AESPA closest to the painting, then the reference generator,
    then the students.  Gram gets that backwards, which is why the project's Gram
    style loss never produced brushwork however it was weighted.
    """
    total = student_features[layers[0]].new_zeros(())
    for index, (layer, direction) in enumerate(zip(layers, directions)):
        student = student_features[layer]
        direction = direction.to(student.device, student.dtype)
        student_flat = student.permute(0, 2, 3, 1).reshape(-1, direction.shape[0])
        student_projection = (student_flat @ direction).sort(dim=0).values
        reference = reference_features[layer]
        with torch.no_grad():
            reference_flat = reference.permute(0, 2, 3, 1).reshape(-1, direction.shape[0])
            reference_projection = (reference_flat @ direction).sort(dim=0).values
        total = total + (
            _quantile_curve(student_projection, quantiles)
            - _quantile_curve(reference_projection, quantiles)).abs().mean()
    return total / len(layers)


LOCAL_GRAM_LAYER = 2          # relu3_1 of the project's extraction
LOCAL_GRAM_WINDOW = 8
LOCAL_GRAM_STRIDE = 4
LOCAL_GRAM_PROJECTIONS = 32
LOCAL_GRAM_DIRECTIONS = 64
LOCAL_GRAM_QUANTILES = 48


def local_gram_descriptors(feature: torch.Tensor,
                           seed: int = 20260923) -> torch.Tensor:
    """Local Gram matrices over sliding windows, as [directions, locations].

    A whole-image Gram averages over every pixel, so it is dominated by the overall
    colour and contrast and the local brushwork contributes only a little.  A small
    patch has few colours, so its Gram is mostly texture; comparing the *distribution*
    of local Grams therefore isolates the thing the eye reads, and it is the only
    metric tried whose ordering matches the eye everywhere (AESPA closest to the
    painting, then the reference generator, then the small models, then the input).
    """
    generator = torch.Generator(device=feature.device).manual_seed(seed)
    channels = feature.shape[1]
    reduce = torch.randn(channels, LOCAL_GRAM_PROJECTIONS, generator=generator,
                         device=feature.device)
    reduced = torch.einsum("bchw,cp->bphw", feature, reduce) / channels ** 0.5
    windows = F.unfold(reduced, kernel_size=LOCAL_GRAM_WINDOW,
                       stride=LOCAL_GRAM_STRIDE)
    locations = windows.shape[-1]
    windows = windows[0].view(LOCAL_GRAM_PROJECTIONS,
                              LOCAL_GRAM_WINDOW * LOCAL_GRAM_WINDOW, locations)
    gram = torch.einsum("pkl,qkl->pql", windows, windows) / (LOCAL_GRAM_WINDOW ** 2)
    gram = gram.reshape(LOCAL_GRAM_PROJECTIONS ** 2, locations)
    # Normalised, so a bright patch and a dim one with the same texture compare equal.
    gram = gram / (gram.norm(dim=0, keepdim=True) + 1e-8)
    directions = torch.randn(LOCAL_GRAM_PROJECTIONS ** 2, LOCAL_GRAM_DIRECTIONS,
                             generator=generator, device=feature.device)
    return directions.t() @ gram


def local_gram_distance(feature: torch.Tensor,
                        reference_descriptors: torch.Tensor) -> torch.Tensor:
    """Sliced Wasserstein distance between two sets of local Gram descriptors."""
    student = local_gram_descriptors(feature).t().sort(dim=0).values
    with torch.no_grad():
        reference = reference_descriptors.t().sort(dim=0).values
    return (_quantile_curve(student, LOCAL_GRAM_QUANTILES)
            - _quantile_curve(reference, LOCAL_GRAM_QUANTILES)).abs().mean()


def local_gram_teacher_loss(student_feature: torch.Tensor,
                            teacher_feature: torch.Tensor,
                            reference_descriptors: torch.Tensor) -> torch.Tensor:
    """Ask the student's local texture to be no worse than the teacher's.

    One-sided and relative: the reference generator's own distance to the painting is
    the target, so the term only ever asks the student to catch up rather than to
    become a copy.  Measured at the watched size the reference sits 15% ahead of every
    small model, and this is the term for that 15%.
    """
    student_distance = local_gram_distance(student_feature, reference_descriptors)
    with torch.no_grad():
        teacher_distance = local_gram_distance(teacher_feature, reference_descriptors)
    if student_distance.dim() == 0:
        student_distance = student_distance[None]
        teacher_distance = teacher_distance[None]
    shortfall = torch.relu(teacher_distance.detach() - student_distance)
    return (shortfall / (teacher_distance.detach().abs() + 1e-6)).mean()


def judge_score(discriminator, image: torch.Tensor) -> torch.Tensor:
    """The frozen judge's verdict: mean discriminator output, higher is better.

    This is the metric that matches the eye and is stable across sizes.  Its
    discriminator was trained to separate real Van Gogh patches from a stylised
    photo, so its output is a learned "how much does this look like the real
    painting" score rather than a statistic someone guessed.
    """
    return discriminator(image).mean()


def judge_loss(discriminator, image: torch.Tensor) -> torch.Tensor:
    """LSGAN-style generator objective against the frozen judge.

    The same form the trainer already uses for its own discriminator, so the two
    fight consistently; the difference is that this judge is frozen and was trained
    against a better generator, so it cannot simply be satisfied.
    """
    return (discriminator(image) - 1.0).square().mean()


def stroke_contrast_loss(student: torch.Tensor, teacher: torch.Tensor,
                         content: torch.Tensor, gain: float = 1.0,
                         scales: tuple = (1.2, 2.5, 5.0)) -> torch.Tensor:
    """Keep the stroke band at least ``gain`` times the teacher's contrast.

    Measured on the same content, the painting carries 1.9x the GroupMix
    teacher's stroke-band contrast and AESPA -- the model the eye rates closest to
    Van Gogh -- carries 1.23x.  Matching the teacher exactly therefore caps the
    style at a level measurably below both, so the level has to be a knob rather
    than whatever the teacher happens to produce.  One-sided again: the term
    raises a floor and never pulls contrast back down.
    """
    mask = smooth_region_mask(content)
    student_gray = luma(student)
    with torch.no_grad():
        teacher_gray = luma(teacher)
        targets = [gain * _masked_std(teacher_gray - blur(teacher_gray, sigma), mask)
                   for sigma in scales]
    total = student_gray.new_zeros(())
    for sigma, target in zip(scales, targets):
        spread = _masked_std(student_gray - blur(student_gray, sigma), mask)
        total = total + torch.relu(target - spread) / (target + 1e-6)
    return total / len(scales)


def band_contrast_loss(student: torch.Tensor, teacher: torch.Tensor,
                       content: torch.Tensor, band: tuple = COARSE_BAND,
                       gain: float = 1.0) -> torch.Tensor:
    """Keep one specific stroke band at least ``gain`` times the teacher's contrast.

    The radial decomposition of the decoded demo says which band is short: at
    periods of 12-16 px the student carries 0.80 of the reference's power and at
    9-12.5 px 0.85, while the 4.5-9 px bands sit at 1.08-1.20 -- the flat-probe
    round pushed those above the reference.  A difference of Gaussians with sigmas
    ``band`` passes periods of roughly 9-16 px (the -3 dB points of blur(1.2) and
    blur(2.5) are at 0.11 and 0.053 cycles per pixel), so this is the one term
    that can ask specifically for the coarse strokes that are missing.

    Both properties matter.  Being band-selective, it cannot be satisfied by the
    fine bands that are already over target the way a plain high-pass std could
    be; being one-sided, it raises a floor and never pulls those bands back down.
    """
    mask = smooth_region_mask(content)
    low, high = band
    student_gray = luma(student)
    with torch.no_grad():
        teacher_gray = luma(teacher)
        target = gain * _masked_std(blur(teacher_gray, low) - blur(teacher_gray, high),
                                    mask)
    spread = _masked_std(blur(student_gray, low) - blur(student_gray, high), mask)
    return torch.relu(target - spread) / (target + 1e-6)


def band_share(gray: torch.Tensor, mask: torch.Tensor,
               sigmas: tuple = SHAPE_SIGMAS) -> torch.Tensor:
    """Normalised share of the masked high-pass energy in each band."""
    blurs = [blur(gray, sigma) for sigma in sigmas]
    shares = torch.stack([_masked_std(blurs[index] - blurs[index + 1], mask)
                          for index in range(len(sigmas) - 1)])
    return shares / (shares.sum() + 1e-6)


def spectral_shape_loss(student: torch.Tensor, teacher: torch.Tensor,
                        content: torch.Tensor,
                        sigmas: tuple = SHAPE_SIGMAS) -> torch.Tensor:
    """Match how the texture energy is distributed across scales, not how much.

    The measured failure is a misallocation: in the sky the student carried 1.57
    of the reference's power at 6-9 px and 0.77 at 12-16 px, and every per-band
    floor pushed it further out of balance because floors cannot ask for less.
    This compares the two normalised band vectors, so it is invariant to the
    overall amount of texture and two-sided per band: the over-supplied fine bands
    are pulled down while the short coarse band is pulled up.

    Scale-invariant and phase-invariant by construction, and bounded to [0, 1]
    (the total-variation distance between two distributions), which makes its
    gradient share directly comparable between runs.
    """
    mask = smooth_region_mask(content)
    student_gray = luma(student)
    with torch.no_grad():
        reference = band_share(luma(teacher), mask, sigmas).detach()
    return (band_share(student_gray, mask, sigmas) - reference).abs().sum() / 2


def flat_content_loss(descriptor: TextureDescriptor, student: torch.Tensor,
                      teacher: torch.Tensor, content: torch.Tensor,
                      weights: dict, gain: float = 1.0) -> dict:
    """The same targets, asked again on the flat probe batch.

    The main terms are measured on real content, whose flattest 30 percent is at
    an activity of 0.0097 -- two orders of magnitude away from the corridor wall.
    Feeding ``flat_probe`` through both models puts the comparison where the wall
    is, and the teacher's answer there (0.014 against the student's 0.005 on the
    same crops) is the target the student has to reach.

    The guard terms matter more here than anywhere else: on a near-constant input
    the cheapest way to satisfy a contrast floor is to sprinkle noise, which is
    the round-7 mosaic.  Oriented-energy matching, cross-orientation coherence,
    orientation-flow continuity and the blurred colour term all reject that,
    which is why they are part of the block rather than optional extras.
    """
    contrast = stroke_contrast_loss(student, teacher, content, gain)
    band = (band_contrast_loss(student, teacher, content, weights.get("band", COARSE_BAND),
                               gain) if weights.get("coarse") else None)
    texture = texture_stat_loss(descriptor, student, teacher)
    coherence = coherence_loss(descriptor, student, teacher)
    energy = energy_scale_loss(descriptor, student, teacher, gain)
    flow = orientation_flow_loss(student, teacher)
    low = low_frequency_loss(student, teacher)
    combined = (weights["contrast"] * contrast
                + weights["texture"] * (texture + coherence + energy)
                + weights["flow"] * flow
                + weights["low"] * low
                + (weights.get("coarse", 0.0) * band if band is not None else 0.0))
    return {"combined": combined, "contrast": contrast, "texture": texture,
            "coherence": coherence, "energy": energy, "flow": flow, "low": low,
            "band": band}


def texture_distillation(descriptor: TextureDescriptor, student: torch.Tensor,
                         teacher: torch.Tensor, weights: dict) -> dict:
    """The texture terms under the names the trainer logs."""
    texture = texture_stat_loss(descriptor, student, teacher)
    coherence = coherence_loss(descriptor, student, teacher)
    # The energy term follows the same gain as the contrast term: otherwise the
    # two would fight, one pulling the amount of texture up to the gained level
    # and the other pulling it back to the teacher's.
    energy = energy_scale_loss(descriptor, student, teacher, weights.get("gain", 1.0))
    low = low_frequency_loss(student, teacher)
    # The optional terms are only computed when they contribute: the accent needs
    # an image large enough for its band pass, and the others are pure additions
    # when their weight is zero.
    chroma = (chroma_loss(student, teacher, weights["content"])
              if weights.get("chroma") else None)
    colour = (colour_distribution_loss(student, weights["colour_reference"])
              if weights.get("colour") else None)
    broadband = (broadbandness_loss(student, teacher)
                 if weights.get("broadband") else None)
    repetition = (repetition_loss(student, teacher)
                  if weights.get("repetition") else None)
    flow = (orientation_flow_loss(student, teacher)
            if weights.get("flow") else None)
    swd = None
    if weights.get("swd") and weights.get("style_features") is not None:
        swd = sliced_wasserstein_style_loss(
            weights["style_model"].perceptual.extract(student),
            weights["style_features"], weights["style_directions"])
    contrast = (stroke_contrast_loss(student, teacher, weights["content"],
                                     weights.get("gain", 1.0))
                if weights.get("contrast") else None)
    combined = (weights["texture"] * (texture + coherence + energy)
                + weights["low"] * low
                + (weights["chroma"] * chroma if chroma is not None else 0.0)
                + (weights["broadband"] * broadband if broadband is not None else 0.0)
                + (weights["contrast"] * contrast if contrast is not None else 0.0)
                + (weights["repetition"] * repetition if repetition is not None else 0.0)
                + (weights["colour"] * colour if colour is not None else 0.0)
                + (weights["flow"] * flow if flow is not None else 0.0)
                + (weights["swd"] * swd if swd is not None else 0.0))
    return {"combined": combined, "texture": texture, "coherence": coherence,
            "energy": energy, "low": low, "chroma": chroma,
            "broadband": broadband, "contrast": contrast,
            "repetition": repetition, "colour": colour, "flow": flow,
            "swd": swd}


def opponent_chroma(image: torch.Tensor, kernel: torch.Tensor) -> torch.Tensor:
    """Warm-minus-cool, with the local luminance divided out.

    Only the red-minus-blue axis is used, because the accent this term exists for
    is warm and the statistic keeps only its positive part.

    Dividing by a blurred local luminance is what makes this invariant to a
    luminance gain: scaling the image scales numerator and denominator together.
    A plain difference of channels is not, because a luma gain also scales the
    colour contrast and the term is normalised, so it would read a pure
    luminance gain as a colour error.  The floor is a clamp rather than an added
    constant for the same reason: adding one would break the cancellation
    wherever the local luminance is well above the floor.
    """
    red, blue = image[:, 0:1], image[:, 2:3]
    local = _blur(luma(image), kernel).clamp(min=0.05)
    return (red - blue) / local


def chroma_band_pass(image: torch.Tensor, sigma: float = CHROMA_SIGMA,
                     base: float = CHROMA_BASE_SIGMA) -> torch.Tensor:
    """Band-passed warm-versus-cool field: positive where the image is warm.

    Three earlier versions of this function used the unsigned opponent chroma.
    The measured failure of the last one is the reason for the sign: over 2000
    training steps the loss fell exactly as asked while the warm accent in the sky
    collapsed from 0.215 to 0.054, because |chroma| is satisfied by *any* strong
    colour variation anywhere in the crop — saturated foliage does the job just as
    well as a warm sky.  Projecting onto the warm axis (red minus blue, divided by
    the local luminance) and keeping the positive part means the statistics can
    only be met by actual warm accents, which is what the eye asked for.

    Dividing by the local luminance keeps this exactly invariant to a luminance
    gain; the difference of two blurs removes the overall colour level and the
    slow cast, so only features of roughly the accent's size survive.
    """
    height, width = image.shape[-2:]
    if min(height, width) < 4 * base:
        raise ValueError(
            f"chroma band pass needs at least {4 * base:.0f}px per side for its "
            f"{base:.0f}px blur, got {height}x{width}")
    fine = _gaussian_kernel(sigma, image.device, image.dtype)
    coarse = _gaussian_kernel(base, image.device, image.dtype)
    warm = opponent_chroma(image, fine)
    return _blur(warm, fine) - _blur(warm, coarse)


def warm_level_statistics(image: torch.Tensor, sigma: float = CHROMA_SIGMA,
                          top_fraction: float = 0.01,
                          content: torch.Tensor = None) -> torch.Tensor:
    """How warm the warmest region is, at the accent's own scale.

    The band-pass statistics above measure local warm contrast, and they can be
    satisfied by spreading the warmth thinly over the whole frame.  Measured, that
    is what happened: the warm peak fell from 0.215 to 0.125 while the spatial
    spread of yellowness *rose* from 0.117 to 0.128 against the reference's 0.114.
    The eye is looking for a patch, not a haze, so the term also requires as much
    *concentration* of warmth as the reference has: the excess of the warmest one
    percent over the image's own mean warmth.  Still location-free, still
    one-sided, and the excess form is what stops a uniform warm cast from paying
    for it.
    """
    local = blur(luma(image), sigma).clamp(min=0.05)
    warm = (image[:, 0:1] - image[:, 2:3]) / local
    field = blur(warm, sigma)
    margin = int(3 * sigma)
    field = field[..., margin:-margin, margin:-margin]
    if content is None:
        mask = torch.ones_like(field, dtype=torch.bool)
    else:
        mask = smooth_region_mask(content)[..., margin:-margin, margin:-margin]
    mean, top = _masked_statistics(torch.relu(field), mask, top_fraction)
    # The excess of the warmest region over the image's own warm level, not the
    # level itself: a uniform warm cast raises both by the same amount and is
    # therefore not a way to pay for the term.
    # A scalar: the masked statistics pool the batch, which is fine because every
    # crop contributes to the same requirement.
    return top - mean


def chroma_loss(student: torch.Tensor, teacher: torch.Tensor, content: torch.Tensor,
                sigma: float = CHROMA_SIGMA, base: float = CHROMA_BASE_SIGMA,
                top_fraction: float = 0.01) -> torch.Tensor:
    """Ask for at least as much warm accent as the reference, wherever it sits.

    The history of this term is worth keeping: comparing the chroma *field* against
    the teacher's required the accent at the teacher's exact pixels, so every
    misaligned over-shoot looked like an error and the cheapest repair was to
    flatten the chroma (measured accent 0.215 -> -0.057, then 0.028).  Location-free
    statistics fixed that, a two-sided match still pulled the accent down towards
    the reference (0.215 -> 0.100), and one-sided statistics fixed that but left
    the statistic unsigned, so the loss fell while the accent fell too
    (0.215 -> 0.054 over 2000 steps).

    What remains is directional and one-sided: the statistics are the mean and the
    top one percent of the *positive* part of the warm band-pass field, so only a
    shortfall of warm accent is penalised, and only warm counts.
    """
    student_band = chroma_band_pass(student, sigma, base)
    with torch.no_grad():
        teacher_band = chroma_band_pass(teacher, sigma, base)
    margin = int(3 * base)
    student_band = student_band[..., margin:-margin, margin:-margin]
    teacher_band = teacher_band[..., margin:-margin, margin:-margin]
    mask = smooth_region_mask(content)[..., margin:-margin, margin:-margin]

    def statistics(field):
        mean, top = _masked_statistics(torch.relu(field), mask, top_fraction)
        return mean.reshape(1), top.reshape(1)

    student_mean, student_top = statistics(student_band)
    with torch.no_grad():
        teacher_mean, teacher_top = statistics(teacher_band)
    shortfall_mean = torch.relu(teacher_mean.detach() - student_mean)
    shortfall_top = torch.relu(teacher_top.detach() - student_top)
    # Third statistic: the warmest region must stay a patch rather than a haze.
    student_peak = warm_level_statistics(student, sigma, top_fraction, content)
    with torch.no_grad():
        teacher_peak = warm_level_statistics(teacher, sigma, top_fraction, content)
    shortfall_peak = torch.relu(teacher_peak.detach() - student_peak)
    reference = teacher_top.detach().mean() + 1e-6
    return ((shortfall_mean.mean() + shortfall_top.mean()) / reference
            + shortfall_peak.mean() / (teacher_peak.detach().mean() + 1e-6))


def energy_scale_loss(descriptor: TextureDescriptor, student: torch.Tensor,
                      teacher: torch.Tensor, gain: float = 1.0) -> torch.Tensor:
    """Match how much oriented energy each filter carries, in absolute terms.

    ``texture_stat_loss`` compares every filter relative to its own teacher mean.
    That is what makes it safe on filters the teacher barely uses, but it also
    means the loss can fall while the total amount of texture falls, by
    rebalancing between filters.  The round-2 preflight showed exactly that: the
    per-filter loss improved 0.504 -> 0.489 while the measured stroke energy
    dropped 0.93 -> 0.80 of the teacher.  This term pins the total, so the two
    cannot be traded against each other.
    """
    student_fields = descriptor(student)
    with torch.no_grad():
        teacher_fields = descriptor(teacher)
    terms = []
    for student_field, teacher_field in zip(student_fields, teacher_fields):
        student_mean = student_field.mean(dim=(0, 3, 4))
        teacher_mean = gain * teacher_field.detach().mean(dim=(0, 3, 4))
        scale = teacher_mean.mean() + 1e-6
        terms.append(((student_mean - teacher_mean).abs() / scale).mean())
    return _level_mix(terms, COARSE_LEVEL_WEIGHT)


def _selfcheck():
    """Shapes, orientation selectivity, phase tolerance, gradient sanity."""
    torch.manual_seed(0)
    descriptor = TextureDescriptor()
    image = torch.rand(2, 3, 128, 128)
    fields = descriptor(image)
    # Every level pools to the same grid in level-0 pixels, so the fields can be
    # compared location by location across scales.  Level 2 covers periods of
    # about 10 and 20 px at the image's own resolution, which is the band the
    # radial measurement found short.
    assert [tuple(f.shape) for f in fields] == [(2, 2, 12, 16, 16)] * LEVELS, \
        [tuple(f.shape) for f in fields]
    # Non-multiple-of-eight sizes must still work.
    assert descriptor(torch.rand(1, 3, 100, 132))[0].shape[-2:] == (13, 17)
    assert descriptor(torch.rand(1, 3, 100, 132))[-1].shape[-2:] == (13, 17)
    # The coarse level must reach the band the two-level bank could not: a
    # 12 px pattern has to show up in the level-2 field far above a flat field.
    coarse_pattern = (0.5 + 0.35 * torch.cos(
        2 * math.pi * torch.arange(256)[None, :] / 12.0)).expand(1, 3, 256, 256).clone()
    flat_field = descriptor(torch.full((1, 3, 256, 256), 0.5))[-1]
    pattern_field = descriptor(coarse_pattern)[-1]
    assert float(pattern_field.mean()) > 5 * float(flat_field.mean()) + 1e-6, \
        (float(pattern_field.mean()), float(flat_field.mean()))

    axis = torch.arange(64, dtype=torch.float32)

    def stripes(phase, diagonal=False, wavelength=2.6):
        coordinate = (((axis[None, :] + axis[:, None]) / math.sqrt(2.0)) if diagonal
                      else axis[None, :].expand(64, 64))
        values = 0.5 + 0.4 * torch.cos(2 * math.pi * coordinate / wavelength + phase)
        return values[None, None].repeat(1, 3, 1, 1)

    def total(student, teacher):
        return float(texture_stat_loss(descriptor, student, teacher)
                     + coherence_loss(descriptor, student, teacher))

    horizontal = stripes(0.0)
    diagonal = stripes(0.0, diagonal=True)
    torch.manual_seed(1)
    grain = (torch.rand(1, 3, 64, 64) - 0.5) * 0.4 + 0.5

    # Orientation selectivity: a vertical-stripe pattern must peak on the
    # orientation whose carrier runs along x, the diagonal one on 45 degrees,
    # and isotropic grain must be flat.
    energy = descriptor(horizontal)[0][0, 0].mean(dim=(1, 2))
    assert int(energy.argmax()) == 0, energy.tolist()
    diagonal_energy = descriptor(diagonal)[0][0, 0].mean(dim=(1, 2))
    assert int(diagonal_energy.argmax()) == ORIENTATIONS // 4, diagonal_energy.tolist()
    grain_energy = descriptor(grain)[0][0, 0].mean(dim=(1, 2))
    assert float(grain_energy.max() / grain_energy.min()) < 1.4, grain_energy.tolist()

    # Phase tolerance: the same pattern shifted by a quarter cycle is far closer
    # than an unrelated texture of the same contrast.  This is the property the
    # earlier pixel-aligned high-frequency loss lacked, and it is why that loss
    # could never be driven down.
    identical = total(horizontal, horizontal.clone())
    phase_shifted = total(horizontal, stripes(0.25 * 2 * math.pi))
    grain_distance = total(grain, horizontal)
    assert identical == 0.0, identical
    assert phase_shifted < 0.2 * grain_distance, (phase_shifted, grain_distance)
    # A wrongly oriented pattern is further than generic grain, so "add grain
    # everywhere" is never the cheapest way to reduce the loss.
    assert total(horizontal, diagonal) > 1.5 * grain_distance, \
        (total(horizontal, diagonal), grain_distance)

    # Gradients reach the student and are finite and non-zero.
    student = horizontal.clone().requires_grad_(True)
    loss = texture_distillation(descriptor, student, stripes(0.25 * 2 * math.pi),
                                {"texture": 1.0, "low": 0.15, "chroma": 0.0})["combined"]
    gradient, = torch.autograd.grad(loss, student)
    assert torch.isfinite(gradient).all() and float(gradient.abs().max()) > 0

    # Broadbandness: a strictly periodic pattern concentrates its spectrum, so it
    # must lose against an irregular field of comparable energy, and only in the
    # direction of "too concentrated" -- a student already broader than the
    # reference must not be penalised.
    torch.manual_seed(2)
    irregular = 0.5 + 0.4 * torch.rand(1, 1, 256, 256)
    periodic = (0.5 + 0.4 * torch.cos(2 * math.pi * torch.arange(256)[None, None, :, None]
                                      / 5.4).expand(1, 1, 256, 256).clone())
    periodic = periodic + 0.02 * irregular
    entropy_periodic = float(spectral_entropy(stroke_band(periodic)))
    entropy_irregular = float(spectral_entropy(stroke_band(irregular)))
    assert entropy_periodic < entropy_irregular, (entropy_periodic, entropy_irregular)
    shortfall = float(broadbandness_loss(periodic, irregular))
    surplus = float(broadbandness_loss(irregular, periodic))
    assert shortfall > 0.0 and surplus == 0.0, (shortfall, surplus)

    # A smoothly varying content selects every pixel, so the probes below keep
    # testing the statistic itself rather than the region mask.
    def smooth_like(x):
        return torch.full_like(x, 0.5)


    # SWD: identical clouds score zero, a shifted cloud scores more, and moving a
    # cloud towards the reference must lower the loss monotonically.  The last one is
    # the property that makes it usable as an objective rather than only as a judge.
    torch.manual_seed(4)
    # Equal sample counts on purpose: the quantile curve of two clouds drawn from
    # the same distribution still differs by the sampling error, so comparing clouds
    # of different sizes has a floor that is an artefact of the counts.  In training
    # that floor is a constant, which is harmless, but a test of the property has to
    # hold the counts fixed.
    start = [torch.randn(2, 6, 16, 16) for _ in range(4)]
    target = [torch.randn(2, 6, 16, 16) * 0.5 + 2.0 for _ in range(4)]
    swd_directions = style_directions([6, 6])
    loss_same = float(sliced_wasserstein_style_loss(start, start, swd_directions))
    assert abs(loss_same) < 1e-5, loss_same
    ladder = [float(sliced_wasserstein_style_loss(
        [alpha * s + (1 - alpha) * t for s, t in zip(start, target)],
        target, swd_directions)) for alpha in (0.0, 0.3, 0.6, 1.0)]
    # alpha = 0 is the target itself, alpha = 1 is far away: strictly increasing.
    assert all(ladder[i] < ladder[i + 1] for i in range(3)), ladder

    # Orientation continuity: a field of long strokes must score higher than
    # noise, identical images must score zero, and being more continuous than the
    # reference must be free.
    # Concentric rings: a literal swirl.  The stroke direction is tangential
    # everywhere, so it varies smoothly with the azimuth and, at a radius of about
    # a hundred pixels, turns by roughly a third of a radian over the longest lag --
    # which is what a curving stroke does.  (A rotating grating does not work as a
    # test: its phase acquires an x-dependent term and the pattern comes out
    # chirped rather than swirled.)
    ring_axis = torch.arange(256, dtype=torch.float32)
    radius = ((ring_axis[None, :, None] - 128.0) ** 2
              + (ring_axis[None, None, :] - 128.0) ** 2).sqrt()
    curved = 0.5 + 0.4 * torch.cos(2 * math.pi * radius / 5.0)
    curved = curved.reshape(1, 1, 256, 256).expand(1, 3, 256, 256).contiguous()
    torch.manual_seed(3)
    noise = 0.5 + 0.4 * torch.rand(1, 3, 256, 256)
    curved_flow = float(orientation_flow(curved)[-1])
    noise_flow = float(orientation_flow(noise)[-1])
    assert curved_flow > noise_flow, (curved_flow, noise_flow)
    assert float(orientation_flow_loss(noise, curved)) > 0.0
    assert float(orientation_flow_loss(curved, noise)) == 0.0
    assert float(orientation_flow_loss(curved, curved.clone())) == 0.0

    # Repetition: a periodic field must lose against an irregular one, identical
    # images must score zero, and less repetition than the reference must be free.
    periodic_image = periodic.expand(1, 3, 256, 256) * 0.9 + 0.05
    irregular_image = (0.5 + 0.4 * torch.rand(1, 3, 256, 256))
    repeated_score = float(patch_self_similarity(periodic_image))
    irregular_score = float(patch_self_similarity(irregular_image))
    assert repeated_score > irregular_score, (repeated_score, irregular_score)
    assert float(repetition_loss(periodic_image, irregular_image)) > 0.0
    assert float(repetition_loss(irregular_image, periodic_image)) == 0.0
    assert float(repetition_loss(irregular_image, irregular_image.clone())) == 0.0

    # Stroke contrast: one-sided against a gained target, so a model already above
    # the target pays nothing and the gain really moves the floor.
    weak = 0.5 + 0.3 * irregular
    strong = 0.5 + 0.9 * irregular
    assert float(stroke_contrast_loss(weak, strong, smooth_like(weak), 1.0)) > 0
    assert float(stroke_contrast_loss(strong, weak, smooth_like(weak), 1.0)) == 0.0
    assert float(stroke_contrast_loss(weak, weak, smooth_like(weak), 1.0)) == 0.0
    assert float(stroke_contrast_loss(weak, weak, smooth_like(weak), 1.5)) > 0

    # Low-frequency term ignores stroke phase completely but still sees colour.
    phase_low = float(low_frequency_loss(horizontal, stripes(0.25 * 2 * math.pi)))
    colour_low = float(low_frequency_loss(horizontal, torch.clamp(horizontal + 0.2, 0, 1)))
    assert phase_low < 0.01, phase_low
    assert colour_low > 20 * phase_low, (colour_low, phase_low)

    # The chroma term works at its own scale, so it is tested on an image large
    # enough to hold a 32px band pass.  The probes below are all at the same
    # per-pixel magnitude, so the comparison between them is meaningful: a
    # luminance gain must be invisible, and the same hue change must count far
    # more when it is a localised accent than when it is spread over the image
    # as a cast.  Removing the cast response is what stops the cheapest way to
    # reduce this term from being "shift the whole sky's colour".
    big = (torch.rand(1, 3, 256, 256) * 0.4 + 0.3)
    # A cool accent must not be able to pay for a warm one: that is the failure
    # the unsigned version had, where saturated foliage satisfied the term while
    # the warm sky accent disappeared.
    cool_teacher = big.clone()
    cool_teacher[:, 0, 96:160, 96:192] = torch.clamp(
        cool_teacher[:, 0, 96:160, 96:192] - 0.25, 0, 1)
    cool_teacher[:, 2, 96:160, 96:192] = torch.clamp(
        cool_teacher[:, 2, 96:160, 96:192] + 0.25, 0, 1)
    cool_student = cool_teacher.clone()
    # A pure luminance *gain*: the term must be blind to it.  An additive
    # brightness offset does change the colour contrast relative to the local
    # luminance, so a non-zero answer there is correct, not a bug.
    luma_shifted = big * 0.9
    uniform = big.clone()
    uniform[:, 0] = torch.clamp(uniform[:, 0] + 0.25, 0, 1)
    uniform[:, 2] = torch.clamp(uniform[:, 2] - 0.15, 0, 1)
    patch = big.clone()
    patch[:, 0, 96:160, 96:192] = torch.clamp(patch[:, 0, 96:160, 96:192] + 0.25, 0, 1)
    patch[:, 2, 96:160, 96:192] = torch.clamp(patch[:, 2, 96:160, 96:192] - 0.15, 0, 1)
    # Location-freedom is the property that matters, because the student's accent
    # is never at the teacher's pixels: an accent placed elsewhere must still be
    # far better than no accent at all.  Removing it entirely is the failure this
    # term exists to prevent.
    moved = big.clone()
    moved[:, 0, 24:96, 24:144] = torch.clamp(moved[:, 0, 24:96, 24:144] + 0.25, 0, 1)
    moved[:, 2, 24:96, 24:144] = torch.clamp(moved[:, 2, 24:96, 24:144] - 0.15, 0, 1)
    # ``chroma_loss(student, teacher)``: the first argument is the student.
    neutral = float(chroma_loss(big, luma_shifted, smooth_like(big)))       # blind to a luma gain
    uniform_loss = float(chroma_loss(big, uniform, smooth_like(big)))       # cast demands little
    patch_loss = float(chroma_loss(big, patch, smooth_like(big)))           # missing accent: costly
    surplus_loss = float(chroma_loss(patch, big, smooth_like(patch)))         # extra accent: free
    moved_loss = float(chroma_loss(patch, moved, smooth_like(patch)))         # accent elsewhere: fine
    assert neutral < 0.002, neutral
    assert patch_loss > 3 * uniform_loss, (patch_loss, uniform_loss)
    warm_shortfall = float(chroma_loss(cool_student, patch, smooth_like(patch)))
    cool_surplus = float(chroma_loss(patch, cool_teacher, smooth_like(patch)))
    assert warm_shortfall > 0.0, warm_shortfall
    assert cool_surplus == 0.0, cool_surplus
    # A concentrated warm patch must beat the same warmth spread thinly: the
    # statistic exists because a haze satisfied the band-pass statistics while the
    # visible patch disappeared.
    haze = big.clone()
    haze[:, 0] = torch.clamp(haze[:, 0] + 0.06, 0, 1)
    haze[:, 2] = torch.clamp(haze[:, 2] - 0.06, 0, 1)
    patch_peak = float(warm_level_statistics(patch, content=smooth_like(patch)))
    haze_peak = float(warm_level_statistics(haze, content=smooth_like(haze)))
    assert patch_peak > haze_peak, (patch_peak, haze_peak)
    # An accent outside the smooth region must not count: that is the mismatch
    # between the sky metrics and the crop-wide terms that this restriction fixes.
    two_region = torch.full((1, 3, 256, 256), 0.5)
    two_region[..., 128:, :] = torch.rand(1, 1, 128, 256) * 0.6 + 0.2
    inside = torch.full((1, 3, 256, 256), 0.5)
    inside[:, 0, 30:90, 30:90] += 0.25
    inside[:, 2, 30:90, 30:90] -= 0.25
    outside = torch.full((1, 3, 256, 256), 0.5)
    outside[:, 0, 160:220, 160:220] += 0.25
    outside[:, 2, 160:220, 160:220] -= 0.25
    region_gap = (float(chroma_loss(outside, inside, two_region))
                  - float(chroma_loss(inside, inside, two_region)))
    assert region_gap > 0.1, region_gap
    assert surplus_loss == 0.0, surplus_loss
    assert moved_loss < 0.2 * patch_loss, (moved_loss, patch_loss)
    # Too small for the band pass must be a loud error, not a silent no-op.
    try:
        chroma_loss(horizontal, horizontal, smooth_like(horizontal))
    except ValueError:
        too_small = True
    else:
        raise AssertionError("chroma_loss should refuse an image smaller than its band pass")
    # Colour distribution: identical images must score zero, and the term must be
    # two-sided -- both less and more warmth than the reference are errors, which is
    # what "match the proportions" means and what the accent term got wrong.
    reference_histogram = colour_distribution(big)[0]
    neutral = float(colour_distribution_loss(big, reference_histogram))
    # The opponent plane ignores a common offset, so the probes have to move the
    # colour *ratio*: more red and less blue, and the mirror image of that.
    warm_shift = torch.tensor([0.12, 0.04, -0.10]).view(1, 3, 1, 1)
    cool_shift = torch.tensor([-0.10, -0.04, 0.12]).view(1, 3, 1, 1)
    warmer = torch.clamp(big + warm_shift, 0, 1)
    cooler = torch.clamp(big + cool_shift, 0, 1)
    warm_loss = float(colour_distribution_loss(warmer, reference_histogram))
    cool_loss = float(colour_distribution_loss(cooler, reference_histogram))
    assert neutral < 1e-4, neutral
    assert warm_loss > 10 * neutral and cool_loss > 10 * neutral, (warm_loss, cool_loss)
    assert abs(warm_loss - cool_loss) < 0.5 * max(warm_loss, cool_loss), \
        (warm_loss, cool_loss)

    # The flat probe: quantising a shrunk blur must give a shallow staircase --
    # eight-bit levels, a small fraction of the source's contrast -- and the block
    # built on it must be a one-sided floor.  A student that leaves the flat
    # content empty is penalised; one already carrying the teacher's contrast is
    # not, which is what keeps the term from fighting the real-content metrics.
    torch.manual_seed(3)
    source = torch.rand(1, 3, 256, 256) * 0.3 + 0.35
    probe = flat_probe(source)
    assert float(probe.std()) < 0.05 * float(source.std()), \
        (float(probe.std()), float(source.std()))
    assert torch.allclose(probe * FLAT_LEVELS, (probe * FLAT_LEVELS).round(), atol=1e-4)
    axis256 = torch.arange(256, dtype=torch.float32)
    pattern = 0.5 + 0.4 * torch.cos(2 * math.pi * axis256 / 2.6)
    patterned = probe + 0.15 * (pattern.view(1, 1, 1, 256) - 0.5)
    floor_gap = float(stroke_contrast_loss(probe, patterned, probe))
    floor_met = float(stroke_contrast_loss(patterned, patterned, probe))
    assert floor_gap > 0.5, floor_gap
    assert floor_met == 0.0, floor_met
    # The band term: a student that already carries the teacher's coarse band
    # scores zero, a student with only fine texture is penalised, and a student
    # with *more* fine texture than the teacher gains nothing by it (the term is
    # band-selective and one-sided).
    coarse_only = 0.5 + 0.35 * torch.cos(2 * math.pi * axis256 / 12.0)
    coarse_only = coarse_only.view(1, 1, 1, 256).expand(1, 3, 256, 256)
    fine_only = 0.5 + 0.35 * torch.cos(2 * math.pi * axis256 / 2.6)
    fine_only = fine_only.view(1, 1, 1, 256).expand(1, 3, 256, 256)
    met = float(band_contrast_loss(coarse_only, coarse_only, probe))
    fine_shortfall = float(band_contrast_loss(fine_only, coarse_only, probe))
    assert met == 0.0, met
    assert fine_shortfall > 0.5, fine_shortfall
    assert float(band_contrast_loss(fine_only * 1.5, coarse_only, probe)) > 0.5

    # The spectral-shape term: identical images score zero, a pure amplitude
    # change is invisible to it (that is the whole point -- the amount is the
    # other terms' business), and a student whose energy sits in the wrong band
    # is penalised.  It is tested on structured images: a *constant* image has no
    # distribution to match, which is also why the term is not used on the flat
    # probe batch, where blur-16 plus the shrink makes the content exactly
    # constant.
    fine_bias = (0.5 + 0.30 * torch.cos(2 * math.pi * axis256 / 3.0).view(1, 1, 1, 256)
                 ).expand(1, 3, 256, 256)
    coarse_bias = (0.5 + 0.30 * torch.cos(2 * math.pi * axis256 / 14.0).view(1, 1, 1, 256)
                   ).expand(1, 3, 256, 256)
    assert float(spectral_shape_loss(coarse_bias, coarse_bias, probe)) == 0.0
    scaled = torch.clamp((coarse_bias - 0.5) * 0.5 + 0.5, 0, 1)
    assert float(spectral_shape_loss(scaled, coarse_bias, probe)) < 0.02
    mismatch = float(spectral_shape_loss(fine_bias, coarse_bias, probe))
    assert mismatch > 0.15, mismatch
    shape_input = coarse_bias.clone().requires_grad_(True)
    shape_gradient, = torch.autograd.grad(
        spectral_shape_loss(shape_input, fine_bias, probe), shape_input)
    assert torch.isfinite(shape_gradient).all() and float(shape_gradient.abs().max()) > 0

    flat_student = probe.clone().requires_grad_(True)
    flat_terms = flat_content_loss(descriptor, flat_student, patterned, probe,
                                   {"contrast": 1.0, "texture": 1.0,
                                    "flow": 1.0, "low": 1.0})
    flat_gradient, = torch.autograd.grad(flat_terms["combined"], flat_student)
    assert torch.isfinite(flat_gradient).all() and float(flat_gradient.abs().max()) > 0

    return {"descriptor_shapes": [tuple(f.shape) for f in fields],
            "identical_loss": identical,
            "phase_shifted_loss": round(phase_shifted, 5),
            "grain_distance": round(grain_distance, 5),
            "orthogonal_orientation_loss": round(total(horizontal, diagonal), 5),
            "low_frequency_phase": round(phase_low, 6),
            "low_frequency_colour": round(colour_low, 5),
            "chroma_luma_gain": round(neutral, 5),
            "chroma_uniform_hue": round(uniform_loss, 5),
            "chroma_local_accent": round(patch_loss, 5),
            "chroma_missing_accent": round(patch_loss, 5),
            "chroma_extra_accent_free": round(surplus_loss, 5),
            "chroma_accent_moved": round(moved_loss, 5),
            "warm_patch_peak": round(patch_peak, 5),
            "warm_haze_peak": round(haze_peak, 5),
            "accent_outside_smooth_region_gap": round(region_gap, 5),
            "chroma_refuses_small_images": too_small,
            "spectral_entropy_periodic": round(entropy_periodic, 4),
            "spectral_entropy_irregular": round(entropy_irregular, 4),
            "broadband_shortfall": round(shortfall, 5),
            "broadband_surplus_free": round(surplus, 5),
            "colour_identical": round(neutral, 6),
            "colour_warmer": round(warm_loss, 5),
            "colour_cooler": round(cool_loss, 5),
            "swd_ladder": [round(v, 5) for v in ladder],
            "flow_curved": round(curved_flow, 4),
            "flow_noise": round(noise_flow, 4),
            "repetition_periodic": round(repeated_score, 4),
            "repetition_irregular": round(irregular_score, 4),
            "horizontal_peak_orientation": int(energy.argmax()),
            "diagonal_peak_orientation": int(diagonal_energy.argmax()),
            "grain_orientation_flatness": round(float(grain_energy.max() / grain_energy.min()), 4),
            "coarse_band_met": met,
            "shape_mismatch": round(mismatch, 4),
            "coarse_band_fine_shortfall": round(fine_shortfall, 4),
            "flat_probe_contrast": round(float(probe.std() / source.std()), 5),
            "flat_floor_gap": round(floor_gap, 4),
            "flat_floor_met": round(floor_met, 4)}


if __name__ == "__main__":
    import json
    print(json.dumps(_selfcheck(), indent=2))
