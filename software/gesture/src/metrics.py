"""Confusion counts and the metrics the training strategy requires.

Beyond per-class precision/recall/F1 and macro-F1, this reports the metric that
matters for deployment: how often a true `other` sample is accepted as one of
the three target gestures. Overall accuracy is computed but is not a selection
criterion, because `other` is about 82% of the data.
"""
import numpy as np

NUM_CLASSES = 4


def _counts(targets, preds, n):
    return np.bincount(targets * n + preds, minlength=n * n).reshape(n, n)


def _prf(conf):
    """Per-class precision, recall, f1 and support from a confusion matrix."""
    diag = np.diag(conf).astype(np.float64)
    support = conf.sum(axis=1).astype(np.float64)
    predicted = conf.sum(axis=0).astype(np.float64)
    recall = np.divide(diag, support, out=np.zeros_like(diag), where=support > 0)
    precision = np.divide(diag, predicted, out=np.zeros_like(diag), where=predicted > 0)
    denom = precision + recall
    f1 = np.divide(2 * precision * recall, denom, out=np.zeros_like(diag),
                   where=denom > 0)
    return precision, recall, f1, support


class MetricAccumulator:
    """Accumulate predictions, then report metrics overall and per source."""

    def __init__(self, class_keys, other_class_id=3):
        self.class_keys = tuple(class_keys)
        if len(self.class_keys) != NUM_CLASSES:
            raise ValueError('expected four classes')
        self.other = other_class_id
        self.targets = tuple(i for i in range(NUM_CLASSES) if i != other_class_id)
        self._conf = np.zeros((NUM_CLASSES, NUM_CLASSES), dtype=np.int64)
        self._by_source = {}

    def update(self, preds, targets, sources=None):
        preds = np.asarray(preds, dtype=np.int64)
        targets = np.asarray(targets, dtype=np.int64)
        self._conf += _counts(targets, preds, NUM_CLASSES)
        if sources is not None:
            sources = np.asarray(sources)
            for source in np.unique(sources):
                mask = sources == source
                conf = self._by_source.setdefault(str(source),
                                                  np.zeros_like(self._conf))
                conf += _counts(targets[mask], preds[mask], NUM_CLASSES)
        return self

    def _false_positive_rates(self, conf):
        row = conf[self.other].astype(np.float64)
        total = row.sum()
        rates = {self.class_keys[t]: (float(row[t] / total) if total else 0.0)
                 for t in self.targets}
        rates['any_target'] = (float(row[list(self.targets)].sum() / total)
                               if total else 0.0)
        return rates

    def result(self):
        precision, recall, f1, support = _prf(self._conf)
        present = support > 0
        per_class = [dict(class_id=i, key=self.class_keys[i],
                          precision=float(precision[i]), recall=float(recall[i]),
                          f1=float(f1[i]), support=int(support[i]))
                     for i in range(NUM_CLASSES)]
        total = int(self._conf.sum())
        target_recalls = [float(recall[t]) for t in self.targets]
        return dict(
            n=total,
            confusion_matrix=self._conf.tolist(),
            per_class=per_class,
            macro_f1=float(f1[present].mean()) if present.any() else 0.0,
            accuracy=(float(np.trace(self._conf) / total) if total else 0.0),
            worst_target_recall=min(target_recalls) if target_recalls else 0.0,
            target_false_positive_rate=self._false_positive_rates(self._conf),
            other_support=int(support[self.other]),
            by_source={source: dict(
                n=int(conf.sum()),
                counts_by_class={self.class_keys[i]: int(conf[i].sum())
                                 for i in range(NUM_CLASSES)},
                target_false_positive_rate=self._false_positive_rates(conf),
            ) for source, conf in sorted(self._by_source.items())},
        )


def format_report(result, title=''):
    """Render a metric result as a short aligned text block."""
    lines = []
    if title:
        lines.append(title)
    lines.append(f"n={result['n']}  macro_f1={result['macro_f1']:.4f}  "
                 f"accuracy={result['accuracy']:.4f}  "
                 f"worst_target_recall={result['worst_target_recall']:.4f}")
    lines.append('  class          prec     recall   f1       support')
    for row in result['per_class']:
        lines.append(f"  {row['key']:<13s} {row['precision']:.4f}  "
                     f"{row['recall']:.4f}  {row['f1']:.4f}  {row['support']:>7d}")
    rates = result['target_false_positive_rate']
    lines.append('  false positives on true other: ' + '  '.join(
        f'{key}={value:.4f}' for key, value in rates.items()))
    for source, block in result['by_source'].items():
        rates = block['target_false_positive_rate']
        lines.append(f"  source {source}: n={block['n']}  " + '  '.join(
            f'{key}={value:.4f}' for key, value in rates.items()))
    conf = np.asarray(result['confusion_matrix'])
    lines.append('  confusion (rows = truth, cols = prediction):')
    for i, row in enumerate(conf):
        lines.append(f"    {result['per_class'][i]['key']:<13s} " +
                     ' '.join(f'{v:>7d}' for v in row))
    return '\n'.join(lines)
