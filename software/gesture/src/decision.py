"""Deployment decision rule: turn four scores into one predicted class.

The model is trained with a fixed batch quota in which `other` is 43.75% of the
samples, while in the field `other` is the large majority of frames. The softmax
therefore reflects the training prior and under-calls the target classes: a true
palm can sit below `other` and still show a clearly raised palm score. This is
the prior mismatch the training strategy already warns about, and this module is
where the correction lives.

Keeping the rule separate from the metrics means the board's CPU can implement
exactly the function that was validated here, and that the same function drives
the live demo, so what is measured is what is demonstrated.

Two rule forms are supported:

``None``            plain argmax over all four classes (the training-time view)
``float T``         predict the strongest target when its score reaches T,
                    otherwise `other` (the generic prior-correction form)
``dict cascade``    an ordered list of tests, first match wins. Each test names
                    a class and either a score threshold or "must be the max":

                        {"cascade": [{"class": "fist", "min_score": 0.1},
                                     {"class": "hand_back", "must_be_max": true},
                                     {"class": "palm_front", "min_score": 0.2}],
                         "fallback": "other"}

                    Thresholds are strict (`>`). A cascade encodes a priority
                    order, so it is not the same as "predict the strongest
                    target above a threshold".
"""
import json
from pathlib import Path

import numpy as np

TARGET_INDICES = (0, 1, 2)
OTHER_INDEX = 3


def load_rule(path):
    """Read a rule document.

    The document may carry the rule under `rule` (a threshold number, a cascade
    dict, or the string/null for argmax) or be a bare cascade dict. Returns None
    for plain argmax.
    """
    payload = json.loads(Path(path).read_text(encoding='utf-8'))
    rule = payload.get('rule', payload)
    if isinstance(rule, dict) and rule.get('name') == 'argmax':
        return None
    if rule == 'argmax':
        return None
    return rule


def compile_rule(rule, class_keys):
    """Turn a rule document into a list of (class_index, test) in priority order."""
    if not isinstance(rule, dict) or 'cascade' not in rule:
        raise ValueError('a cascade rule needs a "cascade" list')
    index_of = {key: i for i, key in enumerate(class_keys)}
    steps = []
    for position, step in enumerate(rule['cascade']):
        name = step['class']
        if name not in index_of:
            raise ValueError(f'unknown class in cascade step {position}: {name}')
        if 'min_score' in step:
            steps.append((index_of[name], ('min_score', float(step['min_score']))))
        elif step.get('must_be_max'):
            steps.append((index_of[name], ('must_be_max', None)))
        else:
            raise ValueError(f'cascade step {position} has no test')
    fallback = rule.get('fallback', 'other')
    if fallback not in index_of:
        raise ValueError(f'unknown fallback class: {fallback}')
    return steps, index_of[fallback]


def decide(scores, rule=None, class_keys=('palm_front', 'hand_back', 'fist', 'other'),
           other_index=OTHER_INDEX):
    """Map score rows to predicted class ids.

    `scores` is a single row or a batch with the class axis last.
    """
    values = np.asarray(scores, dtype=np.float64)
    single = values.ndim == 1
    if single:
        values = values[None, :]

    if rule is None:
        predicted = values.argmax(axis=1)
    elif isinstance(rule, dict):
        steps, fallback = compile_rule(rule, class_keys)
        predicted = np.full(values.shape[0], fallback, dtype=np.int64)
        decided = np.zeros(values.shape[0], dtype=bool)
        for index, (test, argument) in steps:
            if test == 'min_score':
                hit = (~decided) & (values[:, index] > argument)
            else:
                hit = (~decided) & (values.argmax(axis=1) == index)
            predicted[hit] = index
            decided |= hit
            if decided.all():
                break
    else:
        targets = np.delete(values, other_index, axis=1)
        strongest = targets.argmax(axis=1)
        predicted = np.where(targets.max(axis=1) >= float(rule),
                             strongest, other_index)

    predicted = predicted.astype(np.int64)
    return predicted[0] if single else predicted


def explain(scores, rule, class_keys, other_index=OTHER_INDEX):
    """Why one row got its decision; used by the demo overlay and reports."""
    values = np.asarray(scores, dtype=np.float64)
    predicted = int(decide(values, rule, class_keys, other_index))
    if rule is None:
        return f'argmax -> {class_keys[predicted]}'
    if not isinstance(rule, dict):
        strongest = int(values[:other_index].argmax())
        return (f'{class_keys[strongest]} {values[strongest]:.3f} '
                f'vs threshold {rule:g} -> {class_keys[predicted]}')
    steps, fallback = compile_rule(rule, class_keys)
    for index, (test, argument) in steps:
        if test == 'min_score' and values[index] > argument:
            return (f'{class_keys[index]} {values[index]:.3f} > {argument:g} '
                    f'-> {class_keys[predicted]}')
        if test == 'must_be_max' and int(values.argmax()) == index:
            return (f'{class_keys[index]} is the max ({values[index]:.3f}) '
                    f'-> {class_keys[predicted]}')
    return f'no step matched -> {class_keys[fallback]}'


def describe(rule, class_keys=('palm_front', 'hand_back', 'fist', 'other')):
    if rule is None:
        return 'argmax over all four classes'
    if not isinstance(rule, dict):
        return (f'target_priority: strongest target wins when its score '
                f'reaches {rule:g}')
    steps, fallback = compile_rule(rule, class_keys)
    parts = []
    for index, (test, argument) in steps:
        if test == 'min_score':
            parts.append(f'{class_keys[index]}>{argument:g}')
        else:
            parts.append(f'{class_keys[index]}=max')
    return 'cascade: ' + ' | '.join(parts) + f' | else {class_keys[fallback]}'
