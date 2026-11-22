"""PIL RGB letterbox reference. Image preprocessing is not model inference."""
import math

import numpy as np
from PIL import Image

from .spec import load_config


def preprocess_image(image, config=None):
    """Return float32 CHW input and geometry; tensor transfer is caller-owned.

    PIL bilinear includes its downsampling filter. Future RTL resize must be
    compared with this reference (or replace/version both train and deploy).
    """
    spec = load_config(config)
    image = image.convert('RGB')
    width, height = image.size
    target_w, target_h = spec['input']['width'], spec['input']['height']
    ratio = min(target_w / width, target_h / height)
    resized_w = max(1, min(target_w, math.floor(width * ratio + 0.5)))
    resized_h = max(1, min(target_h, math.floor(height * ratio + 0.5)))
    left, top = (target_w - resized_w) // 2, (target_h - resized_h) // 2
    canvas = Image.new('RGB', (target_w, target_h), (128, 128, 128))
    canvas.paste(image.resize((resized_w, resized_h), Image.Resampling.BILINEAR),
                 (left, top))
    pixels = np.asarray(canvas, dtype=np.uint8)
    x = (pixels.astype(np.float32) - 128.0) / 128.0
    return np.ascontiguousarray(x.transpose(2, 0, 1)), {
        'source_wh': [width, height], 'resized_wh': [resized_w, resized_h],
        'pad_left_top': [left, top],
    }
