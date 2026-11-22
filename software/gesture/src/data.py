"""Index-backed dataset for G4Net.

Read -> augment -> `preprocess_image`. Augmentation is applied to the source
image before the resize, so the shared preprocessing contract stays the only
geometry authority: an unaugmented sample is bit-identical to the inference
path, and a trained model sees exactly the resize behaviour it will meet on the
board.

EXIF orientation is deliberately not applied, matching `preprocess_image` and
the deployment path.

For a model with a position head the sample also carries the hand-centre target.
Every geometric augmentation moves that centre, so each one that is enabled has
to transform the label too: mirroring is exact (`cx -> 1 - cx`), and rotation and
zoom are refused here rather than applied to the image alone, because a target
that no longer matches its image is a silent label corruption no metric
downstream would reveal.
"""
import random
from pathlib import Path

import torch
from PIL import Image, ImageEnhance, ImageOps
from torch.utils.data import Dataset

from .position import build_target
from .preprocess import preprocess_image
from .spec import load_config


class GestureDataset(Dataset):
    """Map index rows to (CHW float32 tensor, class id, row index[, target]).

    The 4th element is the position target and appears only when the model
    config has a position head; consumers of the four-class models keep
    unpacking three.

    `model_config` is the model spec whose input geometry the tensors are built
    for. It is passed in rather than read from the module default, because that
    default tracks the newest model: an older run would otherwise be
    preprocessed at the wrong size and never say so.
    """

    def __init__(self, rows, data_root, spec, train=False, model_config=None):
        self.rows = list(rows)
        self.data_root = Path(data_root)
        self.spec = spec
        self.train = bool(train)
        self.model_config = model_config
        self.augmentation = spec['augmentation'] if train else None
        self.seed = spec['seed']
        self.epoch = 0
        self.position_spec = load_config(model_config)
        self.with_position = 'position_head' in self.position_spec
        self.target_sigma = (spec.get('loss', {}).get('position', {})
                             .get('sigma_cells'))
        if self.with_position and self.target_sigma is not None:
            print(f'position target sigma {self.target_sigma} cells '
                  f'(override of {self.position_spec["position_head"]["target_sigma_cells"]})')
        if self.with_position:
            if 'hand_presence' not in self.rows[0]:
                raise ValueError(
                    f'{self.position_spec["model_id"]} has a position head but the '
                    f'index rows carry no hand_presence/hand_cx/hand_cy '
                    f'({self.rows[0]["path"]}): build it with tools/build_v5_index.py')
            if self.augmentation:
                movable = [key for key in ('rotation_degrees', 'zoom')
                           if self.augmentation.get(key) not in (0, 0.0, [1.0, 1.0])]
                if movable:
                    raise ValueError(
                        f'these augmentations move the hand and the position target '
                        f'does not follow them: {movable}')

    def set_epoch(self, epoch):
        """Rotation index mixed into the augmentation seed.

        Every (epoch, sample) pair maps to one fixed augmentation, independent
        of worker count or scheduling, so a run can be reproduced exactly.
        """
        self.epoch = int(epoch)

    def __len__(self):
        return len(self.rows)

    def _rng(self, row):
        return random.Random(f'{self.seed}:{self.epoch}:{row["sample_id"]}')

    def _augment(self, image, rng, row):
        """Augment the image and return it with the (possibly moved) centre.

        Only the transforms that keep the label exact are applied: mirroring
        maps `cx -> 1 - cx`, and the photometric ones move nothing. Rotation and
        zoom are rejected in `__init__` rather than applied here.
        """
        cfg = self.augmentation
        centre = (row.get('hand_cx'), row.get('hand_cy'))
        if rng.random() < cfg['horizontal_flip']:
            image = ImageOps.mirror(image)
            if centre[0] is not None:
                centre = (1.0 - centre[0], centre[1])
        for key, enhancer in (('brightness', ImageEnhance.Brightness),
                              ('contrast', ImageEnhance.Contrast),
                              ('saturation', ImageEnhance.Color)):
            low, high = cfg[key]
            factor = rng.uniform(low, high)
            if abs(factor - 1.0) > 1e-6:
                image = enhancer(image).enhance(factor)
        return image, centre

    def __getitem__(self, index):
        row = self.rows[index]
        with Image.open(self.data_root / row['path']) as handle:
            image = handle.convert('RGB')
            centre = (row.get('hand_cx'), row.get('hand_cy'))
            if self.train:
                image, centre = self._augment(image, self._rng(row), row)
            array, _ = preprocess_image(image, self.model_config)
        image_tensor = torch.from_numpy(array)
        if not self.with_position:
            return image_tensor, row['class_id'], index
        target = build_target(self.position_spec, bool(row['hand_presence']),
                              centre[0] or 0.0, centre[1] or 0.0,
                              sigma=self.target_sigma)
        return (image_tensor, row['class_id'], index,
                torch.from_numpy(target).unsqueeze(0))
