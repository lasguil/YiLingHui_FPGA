"""Shared architecture and preprocessing specification, usable without torch.

Two families live here, and they are separate tasks rather than versions of each
other:

`g4net_v1..v4` classify a frame into four gesture classes. v1 is the historical
palm-facing / back-hand / fist / other task; v2 replaces the two orientation
classes with shape classes a small model can actually separate; v3 keeps v2's
classes but moves to a square input, so the square training crops fill the canvas
instead of being letterboxed into a 16:9 one with grey flanks; v4 keeps the
square geometry and swaps the fist for the open palm, whose spread fingers sit
further from a head in silhouette. The body is identical across all four, so only
the class map and the input size differ.

`gpos_v1` answers a different question: where is the hand. It reuses the same
body -- so it costs the same MAC per frame -- on the 16:9 canvas at 256x144, taps
stride 8, and its only output is a single-channel hand-centre heatmap. It has no
classifier section at all: no GAP, no FC, no four-class logits. Presence comes
from the heatmap peak, so it is not a second head either. Its `classes` table is
kept because the index and the sampler are keyed by `class_id`.

Loading the wrong config is the failure mode both families share: the body is
shape-agnostic, so weights trained under one framing load without complaint under
another and then predict silently wrong things. The geometry therefore always
comes from the checkpoint's own `model_id` (`INPUT_BY_MODEL`), never from a
module-level default.
"""
import json
from copy import deepcopy
from pathlib import Path

CONFIG_DIR = Path(__file__).resolve().parents[1] / 'configs'

# The class order is fixed per model version and is never derived from directory
# names or sorted order. For `gpos_v1` it is the index's table, not an output.
CLASS_KEYS_BY_MODEL = {
    'g4net_v1': ('palm_front', 'hand_back', 'fist', 'other'),
    'g4net_v2': ('fist', 'finger_up', 'thumb_down', 'other'),
    'g4net_v3': ('fist', 'finger_up', 'thumb_down', 'other'),
    'g4net_v4': ('palm', 'finger_up', 'thumb_down', 'other'),
    'gpos_v1': ('palm', 'finger_up', 'thumb_down', 'other'),
}
CONFIG_PATH_BY_MODEL = {name: CONFIG_DIR / f'{name}.json'
                        for name in CLASS_KEYS_BY_MODEL}

# Input geometry is part of a checkpoint's identity for the same reason the class
# map is. The geometry that drives `preprocess_image` is resolved from the
# checkpoint's own `model_id`, never from a module-level default.
INPUT_BY_MODEL = {
    'g4net_v1': (3, 144, 256),
    'g4net_v2': (3, 144, 256),
    'g4net_v3': (3, 192, 192),
    'g4net_v4': (3, 192, 192),
    'gpos_v1': (3, 144, 256),
}

# The position head is part of `gpos_v1`'s identity, not an option: a checkpoint
# either has the extra output or it does not, and the geometry it is tapped from
# is fixed by the body, so the config only names the tap and the stride it must
# come out at. A position model with no classifier section is also position-only.
POSITION_MODELS = ('gpos_v1',)
POSITION_ONLY_MODELS = ('gpos_v1',)
POSITION_TAP_STRIDE = 8
POSITION_ACTIVATION = 'sigmoid'
POSITION_TARGET = 'hand_centre_gaussian'
POSITION_LOSSES = ('focal', 'mse')

CURRENT_MODEL = 'g4net_v4'
DEFAULT_CONFIG = CONFIG_PATH_BY_MODEL[CURRENT_MODEL]
CLASS_KEYS = CLASS_KEYS_BY_MODEL[CURRENT_MODEL]

EXPECTED_PREPROCESSING = {
    'color': 'RGB', 'resize': 'bilinear_letterbox',
    'dimension_rounding': 'floor(x + 0.5)', 'pad_value': 128,
    'normalization': '(pixel - 128) / 128',
    'input_int8_scale': 1 / 128, 'input_int8_zero_point': 0,
}


def model_config_for(model_id):
    """Path of the model spec a checkpoint with this `model_id` was trained with."""
    path = CONFIG_PATH_BY_MODEL.get(model_id)
    if path is None:
        raise ValueError(f'unknown model_id: {model_id!r}')
    return path


def load_config(config=None):
    if isinstance(config, dict):
        spec = deepcopy(config)
    else:
        spec = json.loads(Path(config or DEFAULT_CONFIG).read_text(encoding='utf-8'))
    if spec['schema_version'] != 1:
        raise ValueError('Unsupported model specification schema.')
    model_id = spec['model_id']
    if model_id not in CLASS_KEYS_BY_MODEL:
        raise ValueError(f'Unsupported model_id: {model_id}')
    keys = CLASS_KEYS_BY_MODEL[model_id]
    if [c['id'] for c in spec['classes']] != list(range(4)):
        raise ValueError('Class IDs must be 0, 1, 2, 3.')
    if tuple(c['key'] for c in spec['classes']) != keys:
        raise ValueError(f'The class order for {model_id} is fixed: {keys}')
    position_only = model_id in POSITION_ONLY_MODELS
    classifier = spec.get('classifier')
    if position_only:
        # v5 predicts where the hand is, not what it is doing, so it has no
        # classifier output at all. The class table stays in the config because
        # the index and the sampler are keyed by `class_id`.
        if classifier:
            raise ValueError(f'{model_id} has no classifier output; drop the '
                             f'classifier section')
    elif not classifier or classifier.get('out_features') != 4:
        raise ValueError('G4Net has exactly four outputs.')
    requested = (spec['input'].get('channels'), spec['input'].get('height'),
                 spec['input'].get('width'))
    expected = INPUT_BY_MODEL[model_id]
    if requested != expected:
        raise ValueError(f'{model_id} requires input CHW {expected}, the config '
                         f'asks for {requested}.')
    if (spec['activation'] != 'ReLU6'
            or spec['training_normalization'] != 'BatchNorm2d'
            or spec['deployment_normalization'] != 'fold_into_conv'):
        raise ValueError('Unsupported normalization/activation contract.')
    names = []
    for block in spec['blocks']:
        names.append(block['name'])
        if (block['type'] not in ('conv', 'dsconv')
                or block['kernel'] not in (1, 3)
                or block['stride'] not in (1, 2)
                or block['out_channels'] <= 0
                or (block['type'] == 'dsconv' and block['kernel'] != 3)):
            raise ValueError(f'Unsupported block: {block}')
    if not names or len(set(names)) != len(names):
        raise ValueError('Block names must be nonempty and unique.')
    position = spec.get('position_head')
    if model_id in POSITION_MODELS:
        if not isinstance(position, dict):
            raise ValueError(f'{model_id} requires a position_head section.')
        tap = position.get('tap')
        if tap not in names:
            raise ValueError(f'Position head taps an unknown block: {tap!r}')
        stride = 1
        for block in spec['blocks']:
            stride *= block['stride']
            if block['name'] == tap:
                break
        if stride != POSITION_TAP_STRIDE or position.get('output_stride') != stride:
            raise ValueError(f'Position head taps {tap} at stride {stride}; this '
                             f'head is defined at stride {POSITION_TAP_STRIDE}.')
        if (position.get('kernel') != 1 or position.get('out_channels') != 1
                or position.get('activation') != POSITION_ACTIVATION
                or position.get('target') != POSITION_TARGET
                or position.get('loss') not in POSITION_LOSSES
                or not 0 < position.get('target_sigma_cells', 0) <= 4):
            raise ValueError(f'Unsupported position head: {position}')
    elif position is not None:
        raise ValueError(f'{model_id} has no position head.')
    if spec['preprocessing'] != EXPECTED_PREPROCESSING:
        raise ValueError('Unsupported preprocessing contract.')
    return spec
