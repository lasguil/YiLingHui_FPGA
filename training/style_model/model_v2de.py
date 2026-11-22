"""NativeGroupMixNet-v2 candidates D and E.

Source of truth: docs/NativeGroupMixNet_v2_no_depth_cut_two_models_D_E_guide.md
  V2-D NarrowDeep        C16 trunk, four bodies kept, 3x3 G2 body + PW16
  V2-E FactorizedShuffle C32 trunk, four bodies kept, 1x3 G4 + shuffle + 3x1 G4

Both keep the v1.1 blocks (BN/activation placement, reflect padding, ReLU6,
nearest-neighbour upsampling, sigmoid RGB head) so that only the generator
topology differs from the previous runs.  Frozen numbers from the guide:

  D: 822,067,200 MAC @720p | 8,428 conv weights | max chunk 6
  E: 777,830,400 MAC @720p | 8,812 conv weights | max chunk 3

``python model_v2de.py`` rebuilds both models and checks every one of those
numbers, plus the per-stage MAC tables of guide sections 3.5 and 4.7, the
shuffle permutations of section 4.5 and the loss-stage shapes.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import torch
from torch import nn
from torch.nn import functional as F


HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from model_v2 import GroupMixBlock, HalfResGBlock, model_fingerprint  # noqa: E402


MODEL_KEYS = ("v2d_narrowdeep", "v2e_factorizedshuffle")

# Experiment names frozen by guide section 17 (FP32 stage); the settings module
# uses the same strings as its run-directory names.
EXPERIMENTS = {
    "native_groupmix_v2d_narrowdeep_c16_fp32": "v2d_narrowdeep",
    "native_groupmix_v2e_factorizedshuffle_c32_fp32": "v2e_factorizedshuffle",
}

# (BatchNorm2d count, reflect-padded conv count, parameter count).  Derived from
# the guide's structures and weight totals; build_v2de() re-checks them.
MODEL_FINGERPRINTS = {
    "v2d_narrowdeep": (14, 7, 8855),
    "v2e_factorizedshuffle": (16, 13, 9591),
}

CONV_WEIGHTS = {"v2d_narrowdeep": 8428, "v2e_factorizedshuffle": 8812}
MAC_TOTAL = {"v2d_narrowdeep": 822_067_200, "v2e_factorizedshuffle": 777_830_400}
MAX_CHUNK = {"v2d_narrowdeep": 6, "v2e_factorizedshuffle": 3}

# Channel count of the five CUT loss stages (stem, enc, down, body, reduce).
# V2-D narrows the H/4 trunk to C16, so its PatchNCE projection input follows;
# V2-E keeps v1.1's layout exactly.  selfcheck() verifies both by forward.
STAGE_CHANNELS = {
    "v2d_narrowdeep": (16, 16, 16, 16, 16),
    "v2e_factorizedshuffle": (16, 16, 32, 32, 16),
}

# Guide section 3.5 / 4.7 per-stage MAC at 1280x720, keyed by module name.
STAGE_MAC = {
    "v2d_narrowdeep": {
        "stem": 44_236_800,
        "enc.gconv": 132_710_400,
        "down": 58_982_400,
        **{f"body.{i}.gconv": 66_355_200 for i in range(4)},
        **{f"body.{i}.pw": 14_745_600 for i in range(4)},
        "mix": 14_745_600,
        "dec.gconv": 132_710_400,
        "head": 14_745_600,
        "rgb": 99_532_800,
    },
    "v2e_factorizedshuffle": {
        "stem": 44_236_800,
        "enc.hconv": 44_236_800,
        "enc.vconv": 44_236_800,
        "down": 58_982_400,
        **{f"body.{i}.hconv": 44_236_800 for i in range(4)},
        **{f"body.{i}.vconv": 44_236_800 for i in range(4)},
        "reduce": 29_491_200,
        "dec.hconv": 44_236_800,
        "dec.vconv": 44_236_800,
        "head": 14_745_600,
        "rgb": 99_532_800,
    },
}

# Guide section 4.5: exact channel shuffle permutations.
PERM_16 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
PERM_32 = [0, 8, 16, 24, 1, 9, 17, 25, 2, 10, 18, 26, 3, 11, 19, 27,
           4, 12, 20, 28, 5, 13, 21, 29, 6, 14, 22, 30, 7, 15, 23, 31]


def _inverse(perm: list[int]) -> list[int]:
    inv = [0] * len(perm)
    for new_index, old_index in enumerate(perm):
        inv[old_index] = new_index
    return inv


def bn(channels: int) -> nn.BatchNorm2d:
    return nn.BatchNorm2d(channels, eps=1e-5, momentum=0.1,
                          affine=True, track_running_stats=True)


class FactorizedShuffleBlock(nn.Module):
    """Guide section 4.6: 1x3 G4 -> shuffle -> 3x1 G4 -> inverse shuffle -> add.

    The permutation is a registered buffer, so the shuffle is part of the graph
    (guide section 4.5: training must really use this shuffle semantics).
    """

    def __init__(self, channels: int) -> None:
        super().__init__()
        if channels not in (16, 32):
            raise ValueError(f"FactorizedShuffleBlock supports C16/C32, got {channels}")
        self.hconv = nn.Conv2d(channels, channels, (1, 3), padding=(0, 1), groups=4,
                               bias=False, padding_mode="reflect")
        self.bn1 = bn(channels)
        self.vconv = nn.Conv2d(channels, channels, (3, 1), padding=(1, 0), groups=4,
                               bias=False, padding_mode="reflect")
        self.bn2 = bn(channels)
        perm = PERM_16 if channels == 16 else PERM_32
        self.register_buffer("perm", torch.tensor(perm, dtype=torch.long))
        self.register_buffer("inv_perm", torch.tensor(_inverse(perm), dtype=torch.long))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.bn1(self.hconv(x)))
        y = y[:, self.perm, :, :]
        y = self.bn2(self.vconv(y))
        y = y[:, self.inv_perm, :, :]
        return F.relu6(x + y)


class NarrowDeep(nn.Module):
    """V2-D NarrowDeep (guide section 3): C16 trunk, Encoder + 4 Body + Decoder."""

    def __init__(self) -> None:
        super().__init__()
        self.pad_to = 4
        self.stem = nn.Conv2d(12, 16, 1, bias=False)
        self.stem_norm = bn(16)
        self.enc = HalfResGBlock(groups=4, channels=16)
        self.down = nn.Conv2d(64, 16, 1, bias=False)
        self.down_norm = bn(16)
        self.body = nn.Sequential(*(GroupMixBlock(channels=16, groups=2) for _ in range(4)))
        self.mix = nn.Conv2d(16, 16, 1, bias=False)
        self.mix_norm = bn(16)
        self.dec = HalfResGBlock(groups=4, channels=16)
        self.head = nn.Conv2d(16, 4, 1, bias=False)
        self.head_norm = bn(4)
        self.rgb = nn.Conv2d(4, 3, 3, padding=1, bias=True, padding_mode="reflect")
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
        quarter = F.relu6(self.down_norm(self.down(F.pixel_unshuffle(half, 2))))
        if return_body_stages:
            body_stages = []
            body = quarter
            for block in self.body:
                body = block(body)
                body_stages.append(body)
        else:
            body = self.body(quarter)
        reduced = F.relu6(self.mix_norm(self.mix(body)))
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
        _original, _padding, stem, half, quarter, body, reduced = self._encode(x)
        return stem, half, quarter, body, reduced

    def forward_with_body_stages(self, x: torch.Tensor):
        """Forward output plus every Body output for training-only distillation.

        The four C16 H/4 bodies line up one to one with the v1 teacher's four
        C32 H/4 bodies, so the relation distillation uses direct stage pairs.
        """
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


class FactorizedShuffle(nn.Module):
    """V2-E FactorizedShuffle (guide section 4): C32 trunk kept, bodies keep two convs."""

    def __init__(self) -> None:
        super().__init__()
        self.pad_to = 4
        self.stem = nn.Conv2d(12, 16, 1, bias=False)
        self.stem_norm = bn(16)
        self.enc = FactorizedShuffleBlock(16)
        # Guide 4.4: the down projection is grouped (G=2) so each output looks
        # at 32 inputs; with C64 phase-major order each group still sees all
        # four spatial phases of the C16 channels it covers.
        self.down = nn.Conv2d(64, 32, 1, groups=2, bias=False)
        self.down_norm = bn(32)
        self.body = nn.Sequential(*(FactorizedShuffleBlock(32) for _ in range(4)))
        self.reduce = nn.Conv2d(32, 16, 1, bias=False)
        self.reduce_norm = bn(16)
        self.dec = FactorizedShuffleBlock(16)
        self.head = nn.Conv2d(16, 4, 1, bias=False)
        self.head_norm = bn(4)
        self.rgb = nn.Conv2d(4, 3, 3, padding=1, bias=True, padding_mode="reflect")
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
        quarter = F.relu6(self.down_norm(self.down(F.pixel_unshuffle(half, 2))))
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
        _original, _padding, stem, half, quarter, body, reduced = self._encode(x)
        return stem, half, quarter, body, reduced

    def forward_with_body_stages(self, x: torch.Tensor):
        """Forward output plus every Body output for training-only distillation.

        The four C32 H/4 bodies line up one to one with the v1 teacher's four
        C32 H/4 bodies, so the relation distillation uses direct stage pairs.
        """
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


BUILDERS = {"v2d_narrowdeep": NarrowDeep, "v2e_factorizedshuffle": FactorizedShuffle}


def build_v2de(name: str) -> nn.Module:
    if name not in BUILDERS:
        raise ValueError(f"unknown D/E model: {name}")
    model = BUILDERS[name]()
    actual = model_fingerprint(model)
    if actual != MODEL_FINGERPRINTS[name]:
        raise AssertionError(
            f"{name}: fingerprint {actual} != declared {MODEL_FINGERPRINTS[name]}")
    weights = sum(m.weight.numel() for m in model.modules()
                  if isinstance(m, nn.Conv2d))
    if weights != CONV_WEIGHTS[name]:
        raise AssertionError(
            f"{name}: conv weights {weights} != guide {CONV_WEIGHTS[name]}")
    return model


def mac_table(model: nn.Module, height: int = 720, width: int = 1280) -> dict[str, dict]:
    """Per-conv MAC at HxW (guide sections 3.5/4.7 define both models at 720p)."""
    names = {module: name for name, module in model.named_modules()}
    rows: dict[str, dict] = {}
    handles = []

    def hook(module: nn.Conv2d, _inputs, output):
        taps = module.kernel_size[0] * module.kernel_size[1] * \
            (module.in_channels // module.groups)
        rows[names[module]] = {
            "mac": output.numel() * taps,
            "taps": taps,
            "chunk": math.ceil(taps / 12),
            "out_shape": tuple(output.shape),
        }

    for module in model.modules():
        if isinstance(module, nn.Conv2d):
            handles.append(module.register_forward_hook(hook))
    device = next(model.parameters()).device
    model.eval()
    with torch.inference_mode():
        model(torch.zeros(1, 3, height, width, device=device))
    for handle in handles:
        handle.remove()
    return rows


def selfcheck() -> dict:
    report: dict[str, dict] = {}
    for name in MODEL_KEYS:
        model = build_v2de(name)
        device = "cuda" if torch.cuda.is_available() else "cpu"
        model = model.to(device)
        table = mac_table(model)
        expected = STAGE_MAC[name]
        if set(table) != set(expected):
            missing = sorted(set(expected) - set(table))
            extra = sorted(set(table) - set(expected))
            raise AssertionError(f"{name}: conv set mismatch missing={missing} extra={extra}")
        for layer, value in expected.items():
            if table[layer]["mac"] != value:
                raise AssertionError(
                    f"{name}: {layer} MAC {table[layer]['mac']} != guide {value}")
        total = sum(row["mac"] for row in table.values())
        if total != MAC_TOTAL[name]:
            raise AssertionError(f"{name}: total MAC {total} != guide {MAC_TOTAL[name]}")
        chunk = max(row["chunk"] for row in table.values())
        if chunk != MAX_CHUNK[name]:
            raise AssertionError(f"{name}: max chunk {chunk} != guide {MAX_CHUNK[name]}")

        # Loss-stage shapes, 720p through the real forward and cut_features.
        with torch.inference_mode():
            sample = torch.rand(1, 3, 720, 1280, device=device)
            output = model(sample)
            features = model.cut_features(sample)
        if tuple(output.shape) != (1, 3, 720, 1280):
            raise AssertionError(f"{name}: output {tuple(output.shape)}")
        if not (float(output.min()) >= 0.0 and float(output.max()) <= 1.0):
            raise AssertionError(f"{name}: output outside [0,1]")
        trunk = 16 if name == "v2d_narrowdeep" else 32
        expected_shapes = [(1, 16, 360, 640), (1, 16, 360, 640), (1, trunk, 180, 320),
                           (1, trunk, 180, 320), (1, 16, 180, 320)]
        actual_shapes = [tuple(t.shape) for t in features]
        if actual_shapes != expected_shapes:
            raise AssertionError(f"{name}: cut_features {actual_shapes} != {expected_shapes}")
        measured_channels = tuple(t.shape[1] for t in features)
        if measured_channels != STAGE_CHANNELS[name]:
            raise AssertionError(
                f"{name}: loss-stage channels {measured_channels} != "
                f"declared {STAGE_CHANNELS[name]}")

        report[name] = {
            "fingerprint": list(MODEL_FINGERPRINTS[name]),
            "conv_weights": CONV_WEIGHTS[name],
            "mac_total": total,
            "max_chunk": chunk,
            "loss_stage_channels": list(measured_channels),
            "layer_mac": {k: v["mac"] for k, v in sorted(table.items())},
        }
    # Guide 4.5: the C16 shuffle is self-inverse; the C32 one is not.
    if _inverse(PERM_16) != PERM_16:
        raise AssertionError("C16 shuffle must be self-inverse")
    if _inverse(PERM_32) == PERM_32:
        raise AssertionError("C32 shuffle must not be self-inverse")
    # Guide 4.5/4.10: every new group must draw from all four old groups, which
    # is the whole point of the shuffle (otherwise the groups stay isolated).
    for channels, perm in ((16, PERM_16), (32, PERM_32)):
        size = channels // 4
        old_groups = [set(range(i * size, (i + 1) * size)) for i in range(4)]
        for g in range(4):
            new_group = perm[g * size:(g + 1) * size]
            covered = {i for i, old in enumerate(old_groups) if old & set(new_group)}
            if covered != {0, 1, 2, 3}:
                raise AssertionError(
                    f"C{channels} new group {g} only sees old groups {sorted(covered)}")
    return report


if __name__ == "__main__":
    import json
    print(json.dumps(selfcheck(), indent=2, ensure_ascii=False))
