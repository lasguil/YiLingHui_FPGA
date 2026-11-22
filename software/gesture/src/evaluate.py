"""Deterministic evaluation of one checkpoint on one index split.

Two result shapes come out of here. A four-class model reports confusion counts
and per-class metrics; a position model (a config with a `position_head` and no
classifier) reports presence and centre error instead. The split is read as-is,
with no augmentation and no balancing, because a rebalanced validation set stops
measuring the deployment question.

A position model's batch carries a 4th element, the heatmap target, so the
ground-truth centre is taken back out of that map rather than from a second copy
of the label: the metric then measures exactly the quantity the loss saw.
"""
import json
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from .data import GestureDataset
from .metrics import MetricAccumulator, format_report
from .position import PositionAccumulator, format_position_report


def _target_centres(targets):
    """Centre of each Gaussian target map, in normalised canvas coordinates."""
    array = targets.numpy()
    batch, _, rows, cols = array.shape
    xs = (np.arange(cols) + 0.5) / cols
    ys = (np.arange(rows) + 0.5) / rows
    centres = np.zeros((batch, 2), dtype=np.float64)
    for index in range(batch):
        weights = array[index, 0]
        total = weights.sum()
        if total <= 0:
            continue
        centres[index, 0] = (weights.sum(axis=0) * xs).sum() / total
        centres[index, 1] = (weights.sum(axis=1) * ys).sum() / total
    return torch.from_numpy(centres)


@torch.inference_mode()
def evaluate_model(model, rows, data_root, spec, device, batch_size=128,
                   num_workers=8, limit=None, model_config=None):
    """Return the metric result dict for `rows` (already filtered to one split)."""
    if limit is not None:
        rows = rows[:limit]
    if not rows:
        raise ValueError('empty evaluation split')
    dataset = GestureDataset(rows, data_root, spec, train=False,
                             model_config=model_config)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False,
                        num_workers=num_workers, pin_memory=(device.type == 'cuda'))
    was_training = model.training
    model.eval()
    position = PositionAccumulator() if dataset.with_position else None
    classes = (None if model.classifier is None
               else MetricAccumulator(model.class_keys))
    for batch in loader:
        if dataset.with_position:
            images, targets, index, heat_targets = batch
        else:
            images, targets, index = batch
        output = model(images.to(device, non_blocking=True))
        if classes is not None:
            classes.update(output.argmax(dim=1).cpu().numpy(), targets.numpy(),
                           [rows[i]['source_dataset'] for i in index.tolist()])
        if position is not None:
            presence = (heat_targets.amax(dim=(1, 2, 3)) >= 0.5).numpy()
            position.update(output, presence, _target_centres(heat_targets))
    if was_training:
        model.train()
    result = classes.result() if classes is not None else {}
    if position is not None:
        result.update(position.result(
            recall_floor=float(spec.get('checkpoint', {}).get(
                'presence_recall_floor', 0.95))))
    return result


def write_report(result, path, title=None, extra=None):
    """Write one metric result as JSON, with optional run provenance."""
    payload = dict(extra or {})
    if title:
        payload['title'] = title
    payload['metrics'] = result
    text = (format_report(result, title or '') if 'per_class' in result
            else format_position_report(result, title or ''))
    print(text, flush=True)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n',
                    encoding='utf-8')
    return path
