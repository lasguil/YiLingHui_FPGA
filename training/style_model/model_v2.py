"""NativeGroupMixNet-v2: parameterised generator for the three NPU candidates.

Everything except kernel / groups / block count / resolution path is copied
verbatim from NativeGroupMixNet-v1.1 in model.py:

  * convs are bias-free with padding_mode="reflect" (except the RGB head),
  * every conv is followed by BatchNorm2d(eps=1e-5, momentum=0.1,
    affine=True, track_running_stats=True) and then F.relu6,
  * HalfResGBlock residual order is relu6(x + relu6(bn(conv(x)))),
  * GroupMixBlock residual order is relu6(x + bn(pw(relu6(bn(gconv(x)))))),
  * Head has BN but no activation; RGB has a real bias and ends in sigmoid,
  * the input is padded to a multiple of the downsampling factor with
    reflect padding and cropped back at the end.

Because padding to 4 previously happened before the first PixelUnshuffle and
V2-C adds a second one, the pad factor is 4 for V2-A/V2-B and 8 for V2-C.

Configs follow docs/NativeGroupMixNet_v2_three_models_NPU_quantization_guide.md
sections 4, 5 and 6, including the V2-C squeeze being a 1x1 group conv with
G=2 (section 6.3).
"""
from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

MODEL_CONFIGS = {
    "v2a_depthcut": {
        "enc_groups": 4,
        "body_count": 1,
        "body_groups": 4,
        "body_scale": 4,
        "extra_squeeze": False,
    },
    "v2b_groupcut": {
        "enc_groups": 4,
        "body_count": 2,
        "body_groups": 8,
        "body_scale": 4,
        "extra_squeeze": False,
    },
    "v2c_spatialshift": {
        "enc_groups": 4,
        "body_count": 4,
        "body_groups": 4,
        "body_scale": 8,
        "extra_squeeze": True,
        "squeeze_groups": 2,
    },
}

# (BatchNorm2d count, reflect-padded conv count, parameter count), measured from
# the built models.  build_v2() re-checks these, and _Trainer compares the
# generator against the expected tuple, so an architecture edit cannot slip
# through unnoticed.  The v1.1 reference fingerprint is (14, 7, 19255).
MODEL_FINGERPRINTS = {
    "v2a_depthcut": (8, 4, 7735),
    "v2b_groupcut": (10, 5, 8887),
    "v2c_spatialshift": (15, 7, 20215),
}


def model_fingerprint(generator) -> tuple:
    """Fingerprint a generator by inspection, never by its own declaration."""
    norms = sum(1 for module in generator.modules()
                if isinstance(module, nn.BatchNorm2d))
    reflect = sum(1 for module in generator.modules()
                  if isinstance(module, nn.Conv2d)
                  and module.padding_mode == "reflect")
    params = sum(p.numel() for p in generator.parameters())
    return (norms, reflect, params)


class HalfResGBlock(nn.Module):
    """C16 grouped 3x3 residual block; group count is the only change in v2."""

    def __init__(self, groups: int = 2, channels: int = 16) -> None:
        super().__init__()
        self.gconv = nn.Conv2d(channels, channels, 3, padding=1, groups=groups,
                               bias=False, padding_mode="reflect")
        self.norm = nn.BatchNorm2d(channels, eps=1e-5, momentum=0.1,
                                   affine=True, track_running_stats=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.norm(self.gconv(x)))
        return F.relu6(x + y)


class GroupMixBlock(nn.Module):
    """C32 grouped spatial convolution followed by dense channel mixing."""

    def __init__(self, channels: int = 32, groups: int = 4) -> None:
        super().__init__()
        self.gconv = nn.Conv2d(channels, channels, 3, padding=1, groups=groups,
                               bias=False, padding_mode="reflect")
        self.gconv_norm = nn.BatchNorm2d(channels, eps=1e-5, momentum=0.1,
                                         affine=True, track_running_stats=True)
        self.pw = nn.Conv2d(channels, channels, 1, bias=False)
        self.pw_norm = nn.BatchNorm2d(channels, eps=1e-5, momentum=0.1,
                                      affine=True, track_running_stats=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.gconv_norm(self.gconv(x)))
        y = self.pw_norm(self.pw(y))
        return F.relu6(x + y)


class NativeGroupMixNetV2(nn.Module):
    """Parameterised v2 network; see MODEL_CONFIGS for the three candidates."""

    def __init__(self, config: dict) -> None:
        super().__init__()
        cfg = dict(config)
        self.cfg = cfg
        scale = int(cfg["body_scale"])
        if scale not in (4, 8):
            raise ValueError(f"body_scale must be 4 or 8, got {scale}")
        self.pad_to = scale

        self.stem = nn.Conv2d(12, 16, 1, bias=False)
        self.stem_norm = nn.BatchNorm2d(16, eps=1e-5, momentum=0.1,
                                        affine=True, track_running_stats=True)
        self.enc = HalfResGBlock(groups=int(cfg["enc_groups"]))

        self.down = nn.Conv2d(64, 32, 1, bias=False)
        self.down_norm = nn.BatchNorm2d(32, eps=1e-5, momentum=0.1,
                                        affine=True, track_running_stats=True)

        if cfg.get("extra_squeeze", False):
            # V2-C: H/4 C32 -> PixelUnshuffle(2) -> C128 @ H/8 -> 1x1 G=2 -> C32
            self.squeeze = nn.Conv2d(128, 32, 1, groups=int(cfg["squeeze_groups"]),
                                     bias=False)
            self.squeeze_norm = nn.BatchNorm2d(32, eps=1e-5, momentum=0.1,
                                               affine=True, track_running_stats=True)

        self.body = nn.Sequential(*(GroupMixBlock(groups=int(cfg["body_groups"]))
                                    for _ in range(int(cfg["body_count"]))))

        self.reduce = nn.Conv2d(32, 16, 1, bias=False)
        self.reduce_norm = nn.BatchNorm2d(16, eps=1e-5, momentum=0.1,
                                          affine=True, track_running_stats=True)
        self.dec = HalfResGBlock(groups=int(cfg["enc_groups"]))
        self.head = nn.Conv2d(16, 4, 1, bias=False)
        self.head_norm = nn.BatchNorm2d(4, eps=1e-5, momentum=0.1,
                                        affine=True, track_running_stats=True)
        self.rgb = nn.Conv2d(4, 3, 3, padding=1, bias=True,
                             padding_mode="reflect")

        # Same declared metadata the v1.1 model carries, for tools that read it.
        self.bn_layers = sum(1 for m in self.modules() if isinstance(m, nn.BatchNorm2d))
        self.reflection_conv_layers = sum(
            1 for m in self.modules()
            if isinstance(m, nn.Conv2d) and m.padding_mode == "reflect")

    def _pad(self, x: torch.Tensor):
        h, w = x.shape[-2:]
        ph, pw = (-h) % self.pad_to, (-w) % self.pad_to
        if ph or pw:
            x = F.pad(x, (0, pw, 0, ph), mode="reflect")
        return x, (ph, pw)

    def _encode(self, x: torch.Tensor, return_body_stages: bool = False):
        original, padding = self._pad(x)
        stem = F.relu6(self.stem_norm(self.stem(F.pixel_unshuffle(original, 2))))
        half = self.enc(stem)
        # The stage the CUT loss calls "down" is always the down-conv output
        # (C32 @ H/4), for all three models.  V2-C inserts an extra
        # PixelUnshuffle + squeeze after it, which feeds the body but is not a
        # loss stage, so stage 3 stays the same tensor as in v1.1/V2-A/V2-B.
        quarter = F.relu6(self.down_norm(self.down(F.pixel_unshuffle(half, 2))))
        if self.cfg.get("extra_squeeze", False):
            body_in = F.relu6(self.squeeze_norm(
                self.squeeze(F.pixel_unshuffle(quarter, 2))))
        else:
            body_in = quarter
        if return_body_stages:
            body_stages = []
            body = body_in
            for block in self.body:
                body = block(body)
                body_stages.append(body)
        else:
            body = self.body(body_in)
        # V2-C keeps its bodies at H/8, so the first nearest x2 back to H/4
        # happens before Reduce (guide section 6.2).  Without it the rest of
        # the decoder would be one octave too low.
        upsampled = (F.interpolate(body, scale_factor=2, mode="nearest")
                     if self.cfg.get("extra_squeeze", False) else body)
        reduced = F.relu6(self.reduce_norm(self.reduce(upsampled)))
        if return_body_stages:
            return original, padding, stem, half, quarter, body, reduced, body_stages
        return original, padding, stem, half, quarter, body, reduced

    def forward(self, x: torch.Tensor, clamp_output: bool = True) -> torch.Tensor:
        input_h, input_w = x.shape[-2:]
        _original, (ph, pw), _stem, _half, _quarter, _body, reduced = self._encode(x)
        y = F.interpolate(reduced, scale_factor=2, mode="nearest")
        y = self.dec(y)
        y = self.head_norm(self.head(y))
        y = F.interpolate(y, scale_factor=2, mode="nearest")
        y = torch.sigmoid(self.rgb(y))
        if ph or pw:
            y = y[..., :input_h, :input_w]
        return y

    def cut_features(self, x: torch.Tensor):
        """Five patch stages, in the same order the CUT loss expects."""
        _original, _padding, stem, half, quarter, body, reduced = self._encode(x)
        return stem, half, quarter, body, reduced

    def forward_with_body_stages(self, x: torch.Tensor):
        """Forward output plus every Body output for training-only distillation."""
        input_h, input_w = x.shape[-2:]
        (_original, (ph, pw), _stem, _half, _quarter, _body, reduced,
         body_stages) = self._encode(x, return_body_stages=True)
        y = F.interpolate(reduced, scale_factor=2, mode="nearest")
        y = self.dec(y)
        y = self.head_norm(self.head(y))
        y = F.interpolate(y, scale_factor=2, mode="nearest")
        y = torch.sigmoid(self.rgb(y))
        if ph or pw:
            y = y[..., :input_h, :input_w]
        return y, body_stages


def build_v2(name: str) -> NativeGroupMixNetV2:
    if name not in MODEL_CONFIGS:
        raise ValueError(f"unknown v2 model: {name}")
    model = NativeGroupMixNetV2(MODEL_CONFIGS[name])
    actual = model_fingerprint(model)
    if actual != MODEL_FINGERPRINTS[name]:
        raise AssertionError(
            f"{name}: fingerprint {actual} != documented {MODEL_FINGERPRINTS[name]}")
    return model
