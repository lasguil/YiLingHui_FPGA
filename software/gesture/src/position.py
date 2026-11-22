"""Hand-centre heatmap: target, loss, decode and metrics.

The v5 position head predicts one map at stride 8 over the canvas (18x32 for
256x144). Presence and position come out of that single map: the peak after a
sigmoid is the presence score, and the soft-argmax of the whole map is the
centre. There is deliberately no separate presence logit, because a frame with
no hand is trained as an all-zero map -- which is exactly "no peak" -- so the
two outputs cannot disagree.

Soft-argmax rather than a discrete argmax because the map is coarse: one cell is
8 input px, and 8 input px is 40 px in a 720p frame. The decode lives on the CPU
in the board design, which is why it is written here in numpy as well as in
torch for training.

The loss is the standard penalty-reduced focal form (alpha 2, beta 4) from the
CentreNet family, normalised by the number of positive cells: with a Gaussian
target every cell carries a soft label, so plain MSE would be dominated by the
background.
"""
import numpy as np
import torch
import torch.nn.functional as F


def heatmap_shape(spec):
    """(rows, cols) of the position map for a model config."""
    head = spec.get('position_head')
    if head is None:
        raise ValueError('this config has no position head')
    stride = head['output_stride']
    height, width = spec['input']['height'], spec['input']['width']
    rows = -(-height // stride)      # ceil: the body rounds feature maps up
    cols = -(-width // stride)
    return rows, cols


def build_target(spec, presence, cx, cy, sigma=None):
    """Gaussian around the labelled centre, or an all-zero map when no hand.

    `sigma` overrides the model config's value. Where the peak is sharpened is a
    training choice, not a property of the structure or of the checkpoint, so the
    training config is allowed to own it and the model config carries only the
    reference value.

    `cx` and `cy` are fractions of the canvas, so the centre sits at `cx * cols`
    cell units measured from the left edge. The Gaussian is built over cell
    *indices*, and cell `k` is centred at `k + 0.5` in those units, hence the
    half-cell shift: without it the peak lands half a cell right and down of the
    truth, which is a constant 0.5/32 of the width -- 20 px in a 720p frame.

    The peak follows the continuous centre rather than being snapped to a cell,
    so a centre that falls between cells gets a target that says so.
    """
    rows, cols = heatmap_shape(spec)
    target = np.zeros((rows, cols), dtype=np.float32)
    if not presence:
        return target
    if sigma is None:
        sigma = float(spec['position_head']['target_sigma_cells'])
    sigma = float(sigma)
    centre_x = float(cx) * cols - 0.5
    centre_y = float(cy) * rows - 0.5
    dx = (np.arange(cols, dtype=np.float32) - centre_x) ** 2
    dy = (np.arange(rows, dtype=np.float32) - centre_y) ** 2
    target[:] = np.exp(-(dx[None, :] + dy[:, None]) / (2.0 * sigma * sigma))
    # Scale so the nearest cell is exactly 1. The shape around it still encodes
    # where between cells the centre really is (that is what soft-argmax reads),
    # but a cell worth exactly one is what makes the positive term of the loss
    # weigh as a positive: with a peak of 0.6 and five cells above 0.5, the
    # background term of 571 cells drowns it and training settles on a constant
    # map (measured: peak 0.47 everywhere, presence AUC 0.37 after 5k steps).
    peak = float(target.max())
    if peak > 0:
        target /= peak
    return target


def centre_loss(logits, targets, alpha=2.0, beta=4.0):
    """Penalty-reduced focal loss on a Gaussian target.

    Normalised by the number of hands rather than by the number of hot cells:
    one hand contributes exactly one, which is the standard form and what makes
    the positive term competitive with the ~570 background cells of a cell map.
    The target's peak cell is scaled to 1 in `build_target`, so "a hand" is one
    cell above 0.999 and the cells around it only partially suppress their
    background weight.
    """
    probability = torch.sigmoid(logits).clamp(1e-4, 1 - 1e-4)
    negative_weight = (1.0 - targets).pow(beta)
    loss = -(targets * (1.0 - probability).pow(alpha) * torch.log(probability)
             + negative_weight * probability.pow(alpha)
             * torch.log(1.0 - probability))
    hands = targets.ge(0.999).sum().clamp(min=1.0)
    return loss.sum() / hands


def peak_and_centre(logits, temperature=1.0):
    """Presence score and soft-argmax centre from one logit map.

    Accepts (N, 1, R, C) or (R, C) and returns arrays over the batch. The centre
    is in normalised canvas coordinates, the same convention as the labels.
    """
    if torch.is_tensor(logits):
        array = torch.sigmoid(logits / temperature).detach().float().cpu().numpy()
    else:
        array = np.asarray(logits, dtype=np.float64)
        array = 1.0 / (1.0 + np.exp(-array / temperature))
    array = np.asarray(array, dtype=np.float64).reshape(-1, *array.shape[-2:])
    rows, cols = array.shape[-2:]
    xs = np.arange(cols, dtype=np.float64) + 0.5
    ys = np.arange(rows, dtype=np.float64) + 0.5
    peaks = array.reshape(len(array), -1).max(axis=1)
    total = np.maximum(array.sum(axis=(1, 2)), 1e-12)
    centre_x = (array.sum(axis=1) * xs[None, :]).sum(axis=1) / total / cols
    centre_y = (array.sum(axis=2) * ys[None, :]).sum(axis=1) / total / rows
    return peaks, np.stack([centre_x, centre_y], axis=1)


def _auc(scores, labels):
    """Rank-based ROC AUC; no threshold needed, and no sklearn on the server."""
    scores = np.asarray(scores, dtype=np.float64)
    labels = np.asarray(labels, dtype=bool)
    positives, negatives = int(labels.sum()), int((~labels).sum())
    if positives == 0 or negatives == 0:
        return None
    order = np.argsort(scores, kind='mergesort')
    ranks = np.empty(len(scores), dtype=np.float64)
    ranks[order] = np.arange(1, len(scores) + 1)
    # Average the ranks of tied scores so ties do not bias the statistic.
    sorted_scores = scores[order]
    start = 0
    for index in range(1, len(sorted_scores) + 1):
        if index == len(sorted_scores) or sorted_scores[index] != sorted_scores[start]:
            if index - start > 1:
                ranks[order[start:index]] = ranks[order[start:index]].mean()
            start = index
    return float((ranks[labels].sum() - positives * (positives + 1) / 2)
                 / (positives * negatives))


def _threshold_grid(peaks):
    """Candidate thresholds from just below the smallest peak to the largest.

    Starting at the median (which is what this used to do) makes any high-recall
    operating point unreachable, because a recall of 0.95 needs a threshold below
    the 5th percentile of the peaks. The grid is dense near the low end on
    purpose: that is where the recall floor lives.
    """
    peaks = np.asarray(peaks, dtype=np.float64)
    low = max(peaks.min() * 0.5, 1e-6)
    return np.unique(np.concatenate([
        np.linspace(low, float(np.quantile(peaks, 0.9)), 200),
        np.linspace(float(np.quantile(peaks, 0.9)), float(peaks.max()), 100)]))


class PositionAccumulator:
    """Presence scores, predicted centres and the truth for one evaluation pass."""

    def __init__(self, canvas=(256, 144), frame=(1280, 720)):
        self.canvas = canvas
        self.frame = frame
        self.peaks, self.truth, self.pred = [], [], []
        self.true_centres = []

    def update(self, logits, presence, centre):
        peaks, predicted = peak_and_centre(logits)
        self.peaks.append(peaks)
        self.pred.append(predicted)
        self.truth.append(np.asarray(presence, dtype=bool))
        self.true_centres.append(np.asarray(centre, dtype=np.float64))

    def result(self, recall_floor=0.95):
        peaks = np.concatenate(self.peaks)
        truth = np.concatenate(self.truth)
        predicted = np.concatenate(self.pred)
        true_centres = np.concatenate(self.true_centres)
        report = dict(n=int(len(peaks)), presence_true=int(truth.sum()),
                      presence_rate=float(truth.mean()),
                      auc=_auc(peaks, truth))

        # Best F1 over the peaks actually seen: the deployment threshold has to
        # come from somewhere, and taking it from the validation split is the
        # honest place as long as the test split stays unread.
        candidates = _threshold_grid(peaks)
        best = dict(threshold=0.0, f1=-1.0, precision=0.0, recall=0.0)
        for threshold in np.unique(candidates):
            hit = peaks >= threshold
            tp = int((hit & truth).sum())
            fp = int((hit & ~truth).sum())
            fn = int((~hit & truth).sum())
            if tp == 0:
                continue
            precision = tp / (tp + fp)
            recall = tp / (tp + fn)
            f1 = 2 * precision * recall / (precision + recall)
            if f1 > best['f1']:
                best = dict(threshold=float(threshold), f1=float(f1),
                            precision=float(precision), recall=float(recall))
        report['presence_best_f1'] = best

        def centre_errors(threshold):
            hit = (peaks >= threshold) & truth
            if not hit.any():
                return None
            error = (predicted[hit] - true_centres[hit]) * np.array(self.canvas)
            distance = np.linalg.norm(error, axis=1)
            return dict(n=int(hit.sum()),
                        canvas_px=dict(mean=float(distance.mean()),
                                       median=float(np.median(distance)),
                                       p90=float(np.percentile(distance, 90)),
                                       max=float(distance.max())),
                        frame_px_at_720p=dict(
                            mean=float(distance.mean() * self.frame[0] / self.canvas[0]),
                            median=float(np.median(distance) * self.frame[0] / self.canvas[0]),
                            p90=float(np.percentile(distance, 90) * self.frame[0] / self.canvas[0])),
                        axis_px=dict(x_mean=float(np.abs(error[:, 0]).mean()),
                                     y_mean=float(np.abs(error[:, 1]).mean()),
                                     y_p90=float(np.percentile(np.abs(error[:, 1]), 90))))

        report['centre_at_best_f1'] = centre_errors(best['threshold'])
        # The checkpoint worth deploying: the best centre among thresholds that
        # still keep the presence recall up, because a missed hand has no centre.
        eligible = None
        for threshold in _threshold_grid(peaks):
            hit = peaks >= threshold
            recall = ((hit & truth).sum() / max(int(truth.sum()), 1))
            if recall < recall_floor:
                continue
            errors = centre_errors(threshold)
            if errors is None:
                continue
            value = errors['canvas_px']['median']
            if eligible is None or value < eligible['centre_canvas_px_median']:
                eligible = dict(threshold=float(threshold), recall=float(recall),
                                precision=float(((hit & truth).sum()
                                                 / max(int(hit.sum()), 1))),
                                centre_canvas_px_median=value, errors=errors)
        report['centre_at_recall_floor'] = eligible
        report['recall_floor'] = recall_floor
        return report


def format_position_report(result, title=''):
    """Render a position result as a short aligned text block."""
    lines = []
    if title:
        lines.append(title)
    auc = 'n/a (one class only)' if result['auc'] is None else f"{result['auc']:.4f}"
    lines.append(f"n={result['n']}  presence_true={result['presence_true']} "
                 f"({result['presence_rate']:.3f})  auc={auc}")
    best = result['presence_best_f1']
    lines.append(f"  presence at the best F1: threshold={best['threshold']:.3f}  "
                 f"precision={best['precision']:.4f}  recall={best['recall']:.4f}  "
                 f"f1={best['f1']:.4f}")
    errors = result.get('centre_at_best_f1')
    if errors:
        lines.append(f"  centre where both say hand (n={errors['n']}): "
                     f"median {errors['canvas_px']['median']:.2f} canvas px "
                     f"({errors['frame_px_at_720p']['median']:.1f} px in a 720p frame)  "
                     f"p90 {errors['canvas_px']['p90']:.2f} / "
                     f"{errors['frame_px_at_720p']['p90']:.1f}  mean {errors['canvas_px']['mean']:.2f}")
        lines.append(f"    per axis mean: x {errors['axis_px']['x_mean']:.2f} px  "
                     f"y {errors['axis_px']['y_mean']:.2f} px  "
                     f"(y p90 {errors['axis_px']['y_p90']:.2f})")
    eligible = result.get('centre_at_recall_floor')
    if eligible:
        lines.append(f"  centre at recall >= {result['recall_floor']:.2f}: "
                     f"threshold={eligible['threshold']:.3f}  recall={eligible['recall']:.4f}  "
                     f"precision={eligible['precision']:.4f}  median "
                     f"{eligible['centre_canvas_px_median']:.2f} canvas px")
    else:
        lines.append(f"  no threshold reached recall >= {result['recall_floor']:.2f}")
    return '\n'.join(lines)
