"""Classification losses for the four-class gesture model.

Only the two forms the training strategy compares are implemented: plain
softmax cross-entropy and single-label softmax focal loss. The multi-label
sigmoid focal variant is deliberately absent.
"""
import torch
import torch.nn.functional as F


def softmax_cross_entropy(logits, targets):
    """Unweighted softmax CE with no label smoothing."""
    return F.cross_entropy(logits, targets, weight=None, label_smoothing=0.0)


def softmax_focal(logits, targets, gamma, alpha=1.0):
    """Single-label focal loss from the target log-probability.

    `p_y` comes from `log_softmax`, so the probability chain stays numerically
    stable, and the modulating factor is not detached: it contributes gradient
    exactly as in the original formulation.
    """
    if gamma <= 0:
        raise ValueError('gamma must be positive; gamma = 0 is plain CE.')
    log_p = F.log_softmax(logits, dim=1).gather(1, targets.view(-1, 1)).squeeze(1)
    p = log_p.exp()
    loss = -(1.0 - p).pow(gamma) * log_p
    if isinstance(alpha, (list, tuple)):
        weights = torch.as_tensor(alpha, dtype=logits.dtype, device=logits.device)
        loss = loss * weights[targets]
    elif alpha != 1.0:
        loss = loss * alpha
    return loss.mean()


def build_loss(spec):
    """Return a callable `(logits, targets) -> scalar` from the training config."""
    cfg = spec['loss']
    if cfg['name'] == 'cross_entropy':
        return softmax_cross_entropy, dict(name='cross_entropy', label_smoothing=0.0)
    if cfg['name'] == 'focal':
        gamma, alpha = cfg['focal_gamma'], cfg['focal_alpha']
        return (lambda logits, targets: softmax_focal(logits, targets, gamma, alpha),
                dict(name='focal', gamma=gamma, alpha=alpha))
    raise ValueError(f'unsupported loss: {cfg["name"]}')
