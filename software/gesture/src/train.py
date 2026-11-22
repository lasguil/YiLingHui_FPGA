"""G4Net v1 training loop.

AdamW, linear warmup into cosine decay, and a fixed step budget expressed in
virtual epochs of 500 optimizer steps. Checkpoint selection keeps two
candidates: the best validation macro-F1 and the best false-positive/recall
trade-off at a configured target-recall floor. Overall accuracy is logged but
never selects a checkpoint, because `other` is about 82% of the data.

FP32 CUDA only: TF32 and AMP are disabled, and there is no CPU fallback.
"""
import hashlib
import json
import math
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from .data import GestureDataset
from .evaluate import evaluate_model
from .index import TRAIN_CONFIG, resolve_model_config
from .losses import build_loss
from .model import G4Net
from .sampler import StratifiedBatchSampler
from .spec import model_config_for, load_config


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, payload):
    """Atomic JSON write: a partial file is renamed into place."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n',
                         encoding='utf-8')
    temporary.replace(path)


def save_checkpoint(path, model, optimizer, step, config, metrics=None):
    """Atomic checkpoint write; the payload contract is the file itself."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(model=model.state_dict(), step=step, config=config,
                   metrics=metrics)
    if optimizer is not None:
        payload['optimizer'] = optimizer.state_dict()
    temporary = path.with_suffix('.pt.partial')
    torch.save(payload, temporary)
    temporary.replace(path)


def load_checkpoint(path, model, optimizer=None, device='cuda'):
    payload = torch.load(path, map_location=device, weights_only=False)
    model.load_state_dict(payload['model'])
    if optimizer is not None and 'optimizer' in payload:
        optimizer.load_state_dict(payload['optimizer'])
    return payload['step'], payload.get('metrics'), payload.get('config')


def load_model_from_checkpoint(path, device):
    """Build the model a checkpoint was trained with, then load it.

    The class map and the input geometry are both part of a checkpoint's
    identity: the model body is shared between versions but the meaning of the
    four outputs and the framing they were learned under are not. Taking either
    from the current default config would silently load one version's weights
    under another version's contract. Returns (model, step, metrics, config);
    the same config's `model_id` resolves the geometry via
    `spec.model_config_for`.
    """
    payload = torch.load(path, map_location=device, weights_only=False)
    config = payload.get('config') or {}
    model_id = config.get('model_id')
    config_path = model_config_for(model_id)
    model = G4Net(config_path).to(device)
    model.load_state_dict(payload['model'])
    return model, payload['step'], payload.get('metrics'), config


def learning_rate(step, spec):
    """Linear warmup over the first virtual epochs, then cosine to zero."""
    base = spec['optimizer']['lr']
    per_epoch = spec['schedule']['steps_per_virtual_epoch']
    warmup = spec['schedule']['warmup_virtual_epochs'] * per_epoch
    total = spec['schedule']['max_virtual_epochs'] * per_epoch
    if step < warmup:
        return base * (step + 1) / max(1, warmup)
    progress = min(1.0, (step - warmup) / max(1, total - warmup))
    return base * 0.5 * (1.0 + math.cos(math.pi * progress))


class _LimitedBatches:
    """Take exactly `count` batches from an infinite batch sampler."""

    def __init__(self, sampler, count):
        self.sampler = sampler
        self.count = count

    def __iter__(self):
        iterator = iter(self.sampler)
        for _ in range(self.count):
            yield next(iterator)

    def __len__(self):
        return self.count


def configure_determinism(spec, device):
    if device.type != 'cuda':
        raise RuntimeError('CUDA is required; CPU fallback is forbidden.')
    torch.manual_seed(spec['seed'])
    np.random.seed(spec['seed'])
    random.seed(spec['seed'])
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False


def prepare_run_dir(run_dir, resume=None):
    """Refuse to reuse a directory that already holds another run."""
    run_dir = Path(run_dir)
    if resume is None:
        if run_dir.exists() and any(run_dir.iterdir()):
            raise FileExistsError(f'run directory is not empty: {run_dir}')
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / 'checkpoints').mkdir(exist_ok=True)
    return run_dir


def build_run_config(spec, index_summary, composition, train_config_path,
                     model_config_path):
    """Identity of the run; embedded in every checkpoint and in config.json."""
    model_config = load_config(model_config_path)
    return dict(
        model_id=model_config['model_id'],
        class_order=[c['key'] for c in model_config['classes']],
        class_names=[c['name'] for c in model_config['classes']],
        input_chw=[model_config['input']['channels'], model_config['input']['height'],
                   model_config['input']['width']],
        training_config_sha256=sha256_file(train_config_path),
        model_config_sha256=sha256_file(model_config_path),
        index_sha256=index_summary['index_sha256'],
        index_rows=index_summary['index_rows'],
        data_root=index_summary['data_root'],
        split_seed=spec['seed'],
        split_ratio=spec['split_ratio'],
        counts_by_split=index_summary['counts_by_split'],
        counts_by_split_and_source=index_summary['counts_by_split_and_source'],
        duplicates_dropped=index_summary['duplicates_dropped'],
        sampling=composition,
        augmentation=spec['augmentation'],
        optimizer=spec['optimizer'],
        schedule=spec['schedule'],
        loss=spec['loss'],
        precision='FP32 CUDA; no AMP/TF32',
        eval=spec['eval'],
        checkpoint=spec['checkpoint'],
    )


def _metric_summary(result):
    return dict(macro_f1=result['macro_f1'], accuracy=result['accuracy'],
                worst_target_recall=result['worst_target_recall'],
                target_false_positive_rate=result['target_false_positive_rate'])


def _position_summary(result):
    """The two numbers the position task is judged by."""
    best = result['presence_best_f1']
    eligible = result.get('centre_at_recall_floor')
    return dict(
        presence_auc=result['auc'],
        presence_f1=best['f1'], presence_precision=best['precision'],
        presence_recall=best['recall'], presence_threshold=best['threshold'],
        centre_median_canvas_px=(result['centre_at_best_f1']['canvas_px']['median']
                                 if result.get('centre_at_best_f1') else None),
        centre_median_frame_px=(result['centre_at_best_f1']['frame_px_at_720p']['median']
                                if result.get('centre_at_best_f1') else None),
        centre_at_recall_floor=None if eligible is None
        else dict(threshold=eligible['threshold'], recall=eligible['recall'],
                  precision=eligible['precision'],
                  median_canvas_px=eligible['centre_canvas_px_median']))


def train(spec, rows, data_root, index_summary, run_dir, device,
          train_config_path=None, model_config_path=None, max_steps=None,
          log_every=25, eval_every=None, num_workers=None, eval_limit=None,
          resume=None):
    """Run training; returns the final progress record."""
    run_dir = prepare_run_dir(run_dir, resume)
    train_rows = [r for r in rows if r['split'] == 'train']
    val_rows = [r for r in rows if r['split'] == 'val']
    if not train_rows or not val_rows:
        raise RuntimeError('index has an empty train or val split')

    # The geometry every tensor in this run is built for. Resolved once, from the
    # training config's own pairing, and then handed to everything that resize
    # or pads an image so nothing can quietly fall back to the module default.
    model_config_path = (Path(model_config_path) if model_config_path
                         else resolve_model_config(spec, train_config_path))
    model_config = load_config(model_config_path)
    input_hw = (model_config['input']['height'], model_config['input']['width'])
    position_task = 'position_head' in model_config
    print(f'model   : {model_config_path.name}  input {input_hw[1]}x{input_hw[0]}  '
          f'{"hand-centre heatmap" if position_task else "classes"} '
          f'{[] if position_task else [c["key"] for c in model_config["classes"]]}',
          flush=True)

    per_epoch = spec['schedule']['steps_per_virtual_epoch']
    total_steps = int(max_steps or per_epoch * spec['schedule']['max_virtual_epochs'])
    eval_every = int(eval_every or spec['eval']['every_steps'])
    num_workers = int(num_workers if num_workers is not None
                      else spec['loader']['num_workers'])
    data_root = Path(data_root)

    configure_determinism(spec, device)

    model = G4Net(model_config_path).to(device).train()
    if position_task:
        from .position import centre_loss
        position_cfg = spec['loss'].get('position', {})
        alpha = float(position_cfg.get('alpha', 2.0))
        beta = float(position_cfg.get('beta', 4.0))
        criterion = None
        loss_info = dict(name='heatmap_focal', alpha=alpha, beta=beta)
    else:
        criterion, loss_info = build_loss(spec)
    optimizer = torch.optim.AdamW(model.parameters(),
                                  lr=spec['optimizer']['lr'],
                                  weight_decay=spec['optimizer']['weight_decay'])
    batch_sampler = StratifiedBatchSampler(train_rows, spec)
    dataset = GestureDataset(train_rows, data_root, spec, train=True,
                             model_config=model_config_path)

    composition = batch_sampler.composition()
    composition['loss'] = loss_info
    run_config = build_run_config(spec, index_summary, composition,
                                  train_config_path or TRAIN_CONFIG,
                                  model_config_path)
    write_json(run_dir / 'config.json', run_config)
    log_path = run_dir / 'train.jsonl'

    step = 0
    if resume is not None:
        step, _, _ = load_checkpoint(resume, model, optimizer, device)
        print(f'resumed from {resume} at step {step}', flush=True)

    # A position run selects on presence and centre error; a class run on the
    # recall floor and the false-positive trade-off. Only the latter reads this.
    recall_floor = spec['checkpoint'].get('target_recall_floor')
    best = dict(macro_f1={}, deploy={})
    eval_count = 0
    last_eval_step = -1
    started = time.time()
    loss_total = 0.0
    loss_count = 0

    with log_path.open('a', encoding='utf-8', buffering=1) as log:
        while step < total_steps:
            epoch_index = step // per_epoch
            take = min(per_epoch - (step % per_epoch), total_steps - step)
            dataset.set_epoch(epoch_index)
            loader = DataLoader(dataset,
                                batch_sampler=_LimitedBatches(batch_sampler, take),
                                num_workers=num_workers, pin_memory=True,
                                prefetch_factor=spec['loader']['prefetch_factor'])
            for batch in loader:
                current_lr = learning_rate(step, spec)
                for group in optimizer.param_groups:
                    group['lr'] = current_lr
                if position_task:
                    images, _, _, heat_targets = batch
                    heatmap = model(images.to(device, non_blocking=True))
                    loss = centre_loss(heatmap, heat_targets.to(device, non_blocking=True),
                                       alpha, beta)
                else:
                    images, targets, _ = batch
                    logits = model(images.to(device, non_blocking=True))
                    loss = criterion(logits, targets.to(device, non_blocking=True))
                if not torch.isfinite(loss):
                    raise RuntimeError(f'non-finite loss at step {step + 1}')
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                optimizer.step()
                step += 1
                loss_total += float(loss.detach())
                loss_count += 1

                if step % log_every == 0:
                    row = dict(step=step, virtual_epoch=epoch_index, lr=current_lr,
                               mean_loss=loss_total / max(1, loss_count),
                               samples_seen=step * composition['batch_size'],
                               seconds=round(time.time() - started, 2))
                    print(json.dumps(row), flush=True)
                    log.write(json.dumps(row) + '\n')
                    loss_total, loss_count = 0.0, 0

                if step % eval_every == 0 or step == total_steps:
                    if step == last_eval_step:
                        continue
                    last_eval_step = step
                    result = evaluate_model(model, val_rows, data_root, spec, device,
                                            batch_size=spec['eval']['batch_size'],
                                            num_workers=spec['eval']['num_workers'],
                                            limit=eval_limit,
                                            model_config=model_config_path)
                    summary = (_position_summary(result) if position_task
                               else _metric_summary(result))
                    eval_count += 1
                    checkpoint = run_dir / 'checkpoints' / f'step_{step:06d}.pt'
                    save_checkpoint(checkpoint, model, optimizer, step, run_config,
                                    summary)
                    write_json(run_dir / 'latest_val_metrics.json', result)
                    row = dict(step=step, virtual_epoch=epoch_index,
                               checkpoint=checkpoint.name, **summary)
                    print(json.dumps(row), flush=True)
                    log.write(json.dumps(row) + '\n')
                    if position_task:
                        _update_position_candidates(run_dir, best, step, summary,
                                                    checkpoint, spec, model, optimizer,
                                                    run_config)
                    else:
                        _update_candidates(run_dir, best, step, summary, checkpoint,
                                           recall_floor, model, optimizer, run_config)
            write_json(run_dir / 'progress.json',
                       dict(step=step, total_steps=total_steps,
                            virtual_epoch=epoch_index, evals=eval_count,
                            seconds=round(time.time() - started, 2),
                            elapsed_hours=round((time.time() - started) / 3600, 3),
                            latest_val=best.get('latest'),
                            candidates={key: value.get('step')
                                        for key, value in best.items()
                                        if key != 'latest'}))

    elapsed = time.time() - started
    write_json(run_dir / 'COMPLETE.json',
               dict(step=step, total_steps=total_steps, evals=eval_count,
                    seconds=round(elapsed, 2), elapsed_hours=round(elapsed / 3600, 3),
                    candidates={k: v.get('step') for k, v in best.items()}))
    print(f'done: step {step}/{total_steps}, {eval_count} evals, '
          f'{elapsed / 3600:.2f} h', flush=True)
    return dict(step=step, evals=eval_count, seconds=elapsed,
                candidates={key: value for key, value in best.items()
                            if key != 'latest'})


def _update_position_candidates(run_dir, best, step, summary, checkpoint, spec,
                                model, optimizer, run_config):
    """Keep the best presence AUC and the best centre error seen so far.

    Presence first because a missed hand has no centre at all: `best_centre` only
    competes among evaluations whose presence recall at the threshold is at or
    above the floor, which is the same threshold the board will use.
    """
    best['latest'] = summary
    if summary['presence_auc'] is not None and \
            summary['presence_auc'] > best.get('presence', {}).get('value', -1.0):
        best['presence'] = dict(value=summary['presence_auc'], step=step)
        save_checkpoint(run_dir / 'checkpoints' / 'best_presence.pt', model,
                        optimizer, step, run_config, summary)
    eligible = summary.get('centre_at_recall_floor')
    if eligible is None:
        return
    if not best.get('deploy'):
        best['deploy'] = dict(value=float('inf'))
    if eligible['median_canvas_px'] < best['deploy']['value']:
        best['deploy'] = dict(value=eligible['median_canvas_px'], step=step,
                              recall=eligible['recall'],
                              threshold=eligible['threshold'])
        save_checkpoint(run_dir / 'checkpoints' / 'best_centre.pt', model,
                        optimizer, step, run_config, summary)


def _update_candidates(run_dir, best, step, summary, checkpoint, recall_floor,
                       model, optimizer, run_config):
    """Keep the best macro-F1 and the best deploy trade-off seen so far."""
    best['latest'] = summary
    if summary['macro_f1'] > best['macro_f1'].get('value', -1.0):
        best['macro_f1'] = dict(value=summary['macro_f1'], step=step)
        save_checkpoint(run_dir / 'checkpoints' / 'best_macro_f1.pt', model,
                        optimizer, step, run_config, summary)
    eligible = summary['worst_target_recall'] >= recall_floor
    if eligible:
        value = summary['target_false_positive_rate']['any_target']
        if value < best['deploy'].get('value', 2.0):
            best['deploy'] = dict(value=value, step=step,
                                  false_positive_rate=value)
            save_checkpoint(run_dir / 'checkpoints' / 'best_deploy.pt', model,
                            optimizer, step, run_config, summary)
