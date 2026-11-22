"""NativeGroupMixNet-v1: document-exact FP32 model, no PixelShuffle."""
from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F


class HalfResGBlock(nn.Module):
    """C16 grouped 3x3 residual block; each group has eight input channels."""

    def __init__(self):
        super().__init__()
        self.gconv = nn.Conv2d(16, 16, 3, padding=1, groups=2,
                               bias=False, padding_mode="reflect")
        self.norm = nn.BatchNorm2d(16, eps=1e-5, momentum=0.1,
                                   affine=True, track_running_stats=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.norm(self.gconv(x)))
        return F.relu6(x + y)


class GroupMixBlock(nn.Module):
    """C32 grouped spatial convolution followed by dense channel mixing."""

    def __init__(self):
        super().__init__()
        self.gconv = nn.Conv2d(32, 32, 3, padding=1, groups=4,
                               bias=False, padding_mode="reflect")
        self.gconv_norm = nn.BatchNorm2d(32, eps=1e-5, momentum=0.1,
                                         affine=True, track_running_stats=True)
        self.pw = nn.Conv2d(32, 32, 1, bias=False)
        self.pw_norm = nn.BatchNorm2d(32, eps=1e-5, momentum=0.1,
                                      affine=True, track_running_stats=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.gconv_norm(self.gconv(x)))
        y = self.pw_norm(self.pw(y))
        return F.relu6(x + y)


class NativeGroupMixNet(nn.Module):
    """NativeGroupMixNet-v1 as specified in the design document.

    Spatial reductions are PixelUnshuffle(2) followed by PixelUnshuffle(2),
    giving an H/4, C32 bottleneck. Decoder upsampling uses nearest-neighbour
    interpolation twice and finishes with a learned full-resolution 3x3 RGB
    head. The model is fully convolutional and uses no PixelShuffle.
    """

    def __init__(self):
        super().__init__()
        self.stem = nn.Conv2d(12, 16, 1, bias=False)
        self.stem_norm = nn.BatchNorm2d(16, eps=1e-5, momentum=0.1,
                                        affine=True, track_running_stats=True)
        self.enc = HalfResGBlock()

        self.down = nn.Conv2d(64, 32, 1, bias=False)
        self.down_norm = nn.BatchNorm2d(32, eps=1e-5, momentum=0.1,
                                        affine=True, track_running_stats=True)
        self.body = nn.Sequential(*(GroupMixBlock() for _ in range(4)))

        self.reduce = nn.Conv2d(32, 16, 1, bias=False)
        self.reduce_norm = nn.BatchNorm2d(16, eps=1e-5, momentum=0.1,
                                          affine=True, track_running_stats=True)
        self.dec = HalfResGBlock()
        self.head = nn.Conv2d(16, 4, 1, bias=False)
        self.head_norm = nn.BatchNorm2d(4, eps=1e-5, momentum=0.1,
                                        affine=True, track_running_stats=True)
        self.rgb = nn.Conv2d(4, 3, 3, padding=1, bias=True,
                              padding_mode="reflect")

        self.bn_layers = 14
        self.reflection_conv_layers = 7
        assert sum(p.numel() for p in self.parameters()) == 19255

    @staticmethod
    def _pad_to_4(x: torch.Tensor) -> tuple[torch.Tensor, tuple[int, int]]:
        h, w = x.shape[-2:]
        ph, pw = (-h) % 4, (-w) % 4
        if ph or pw:
            x = F.pad(x, (0, pw, 0, ph), mode="reflect")
        return x, (ph, pw)

    def _encode(self, x: torch.Tensor, return_body_stages: bool = False):
        original, padding = self._pad_to_4(x)
        unshuffled = F.pixel_unshuffle(original, 2)
        stem = F.relu6(self.stem_norm(self.stem(unshuffled)))
        half = stem
        half = self.enc(half)
        quarter64 = F.pixel_unshuffle(half, 2)
        quarter = F.relu6(self.down_norm(self.down(quarter64)))
        if return_body_stages:
            body_stages = []
            body = quarter
            for block in self.body:
                body = block(body)
                body_stages.append(body)
        else:
            body = self.body(quarter)
        reduced = F.relu6(self.reduce_norm(self.reduce(body)))
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
        """Five encoder stages used by CUT PatchNCE."""
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


def model_stats(model: nn.Module) -> dict[str, int]:
    params = sum(parameter.numel() for parameter in model.parameters())
    return {"parameters": params, "int8_weight_bytes": params}
