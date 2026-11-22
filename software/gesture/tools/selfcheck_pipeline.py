"""Self-checks for the G4Net training pipeline.

No dataset and no long run: synthetic rows and a handful of tiny images cover
the invariants that would otherwise only fail hours into a training run. The
model wiring check runs on CUDA, because this project forbids CPU execution.

Run from the repository root, and again on the server after `server/sync.sh`:

  python gesture/tools/selfcheck_pipeline.py
  cd .../gesture_four_class_20261015 && python ml/tools/selfcheck_pipeline.py
"""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image

# The parent of tools/ is the package root in the repository (gesture/) and on
# the server (ml/), so the same file works in both layouts.
HERE = Path(__file__).resolve().parent
GESTURE = Path(os.environ.get('GESTURE_DIR') or HERE.parent)
sys.path.insert(0, str(GESTURE))

from src.data import GestureDataset                      # noqa: E402
from src.index import (assign_splits, build_index, load_train_config,  # noqa: E402
                       read_index, resolve_duplicates, resolve_model_config)
from src.losses import build_loss, softmax_cross_entropy, softmax_focal  # noqa: E402
from src.metrics import MetricAccumulator                # noqa: E402
from src.model import G4Net                              # noqa: E402
from src.preprocess import preprocess_image              # noqa: E402
from src.sampler import StratifiedBatchSampler, redistribute_quota  # noqa: E402
from src.spec import load_config                         # noqa: E402

PASSED, FAILED = [], []


def check(name, condition, detail=''):
    (PASSED if condition else FAILED).append(name)
    mark = 'ok  ' if condition else 'FAIL'
    print(f'  [{mark}] {name}' + (f'  {detail}' if detail else ''))


def synthetic_rows():
    """Rows shaped like the real index, with one empty `other` pool."""
    rows, position = [], 0
    layout = [
        (0, 'palm_front', 'palm', 'hagrid', 200),
        (0, 'palm_front', 'stop', 'hagrid', 180),
        (1, 'hand_back', 'stop_inverted', 'hagrid', 160),
        (2, 'fist', 'fist', 'hagrid', 150),
        (3, 'hagrid_hand', 'no_gesture', 'hagrid', 300),
        (3, 'hagrid_hand', 'peace', 'hagrid', 120),
        (3, 'external_negative', 'coco', 'style_transfer/coco', 260),
        (3, 'external_negative', 'div2k', 'style_transfer/div2k', 90),
    ]
    for class_id, pool, subclass, source, count in layout:
        for i in range(count):
            rows.append(dict(sample_id=f'{subclass}/{i}', path=f'{subclass}/{i}.jpg',
                             class_id=class_id, semantic_pool=pool,
                             source_subclass=subclass, source_dataset=source))
            position += 1
    return rows


def check_config():
    print('config')
    spec = load_train_config()
    check('class quota sums to batch size',
          sum(spec['sampling']['class_quota'].values()) == spec['sampling']['batch_size'],
          str(spec['sampling']['class_quota']))
    check('other pool quota sums to the other class quota',
          sum(spec['sampling']['other_pool_quota'].values())
          == spec['sampling']['class_quota']['3'])
    check('split ratio sums to one',
          abs(sum(spec['split_ratio'].values()) - 1.0) < 1e-9)
    broken = json.loads(json.dumps(spec))
    broken['sampling']['class_quota']['3'] = 27
    try:
        load_train_config(broken)
        check('rejects a quota that does not sum to batch size', False)
    except ValueError:
        check('rejects a quota that does not sum to batch size', True)
    # Input geometry rides with the model, so a train config that names a model
    # whose classes disagree must not load: the four outputs would mean
    # different things between the run and its weights.
    mismatched = json.loads(json.dumps(spec))
    mismatched['class_order'] = ['palm_front', 'hand_back', 'fist', 'other']
    try:
        load_train_config(mismatched)
        check('rejects a model_config whose classes contradict class_order', False)
    except ValueError:
        check('rejects a model_config whose classes contradict class_order', True)
    missing = json.loads(json.dumps(spec))
    missing['model_config'] = 'g4net_does_not_exist.json'
    try:
        load_train_config(missing)
        check('rejects a model_config that is not on disk', False)
    except FileNotFoundError:
        check('rejects a model_config that is not on disk', True)
    # A config without the field is a legacy one, paired by file name.
    legacy = json.loads(json.dumps(spec))
    legacy.pop('model_config')
    resolved = resolve_model_config(legacy, 'configs/g4net_v3_train.json')
    check('a legacy train config pairs by its file name',
          resolved.name == 'g4net_v3.json', resolved.name)
    return spec


def check_loss():
    print('loss')
    torch.manual_seed(0)
    logits = torch.randn(16, 4, dtype=torch.float64)
    targets = torch.randint(0, 4, (16,))
    ce = softmax_cross_entropy(logits, targets)
    reference = torch.nn.functional.cross_entropy(logits, targets)
    check('CE matches torch cross_entropy', torch.allclose(ce, reference),
          f'{ce.item():.6f}')

    focal1 = softmax_focal(logits, targets, gamma=1.0)
    focal2 = softmax_focal(logits, targets, gamma=2.0)
    check('focal with gamma>0 is below CE', focal1 < ce and focal2 < focal1,
          f'ce={ce.item():.4f} g1={focal1.item():.4f} g2={focal2.item():.4f}')

    # A confident, correct sample must be suppressed far more than a wrong one.
    easy = torch.tensor([[8.0, 0.0, 0.0, 0.0]], dtype=torch.float64)
    hard = torch.tensor([[0.1, 0.1, 0.1, 0.1]], dtype=torch.float64)
    label = torch.tensor([0])
    ratio_easy = (softmax_focal(easy, label, 2.0) / softmax_cross_entropy(easy, label))
    ratio_hard = (softmax_focal(hard, label, 2.0) / softmax_cross_entropy(hard, label))
    check('focal down-weights easy samples more than hard ones',
          ratio_easy < ratio_hard, f'easy={ratio_easy.item():.4f} hard={ratio_hard.item():.4f}')

    params = torch.tensor([[-0.5, 0.0, 0.0, 0.0]], dtype=torch.float64, requires_grad=True)
    softmax_focal(params, label, 2.0).backward()
    focal_grad = params.grad.clone()
    params.grad = None
    softmax_cross_entropy(params, label).backward()
    ce_grad = params.grad.clone()
    check('the focal modulating factor participates in the gradient',
          not torch.allclose(focal_grad, ce_grad),
          f'{focal_grad.abs().sum().item():.6f} vs {ce_grad.abs().sum().item():.6f}')

    _, info = build_loss(load_train_config())
    check('build_loss reports the loss identity', 'name' in info, str(info))


def check_metrics():
    print('metrics')
    keys = ('palm_front', 'hand_back', 'fist', 'other')
    accumulator = MetricAccumulator(keys)
    targets = [0, 0, 1, 2, 3, 3, 3, 3]
    preds = [0, 1, 1, 2, 3, 0, 3, 3]
    sources = ['hagrid'] * 8
    accumulator.update(preds, targets, sources)
    result = accumulator.result()

    expected_conf = np.array([[1, 1, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [1, 0, 0, 3]])
    check('confusion matrix', np.array_equal(np.asarray(result['confusion_matrix']),
                                            expected_conf))
    by_key = {row['key']: row for row in result['per_class']}
    check('palm_front recall', abs(by_key['palm_front']['recall'] - 0.5) < 1e-12)
    check('hand_back precision', abs(by_key['hand_back']['precision'] - 0.5) < 1e-12)
    check('hand_back f1', abs(by_key['hand_back']['f1'] - 2 / 3) < 1e-12)
    check('macro f1', abs(result['macro_f1'] - 0.7559523809523809) < 1e-12,
          f"{result['macro_f1']:.6f}")
    check('worst target recall', abs(result['worst_target_recall'] - 0.5) < 1e-12)
    rates = result['target_false_positive_rate']
    check('false positive rate on true other',
          abs(rates['palm_front'] - 0.25) < 1e-12 and rates['hand_back'] == 0.0
          and abs(rates['any_target'] - 0.25) < 1e-12, str(rates))
    check('per-source breakdown present', 'hagrid' in result['by_source'])

    split = MetricAccumulator(keys)
    split.update(preds[:4], targets[:4], sources[:4])
    split.update(preds[4:], targets[4:], sources[4:])
    check('accumulating in two calls equals one call',
          np.array_equal(np.asarray(split.result()['confusion_matrix']), expected_conf))


def check_redistribution():
    print('pool quota redistribution')
    configured = {'hagrid_hand': 14, 'same_domain': 8, 'external_negative': 6}
    effective = redistribute_quota(configured, {'hagrid_hand', 'external_negative'})
    check('empty pool quota is redistributed and the total is preserved',
          sum(effective.values()) == 28, str(effective))
    check('redistribution splits proportionally 14:6',
          effective == {'external_negative': 8, 'hagrid_hand': 20}, str(effective))
    full = redistribute_quota(configured, set(configured))
    check('with no empty pool the configured quota is untouched', full == configured)
    try:
        redistribute_quota(configured, set())
        check('rejects an all-empty pool set', False)
    except RuntimeError:
        check('rejects an all-empty pool set', True)


def check_sampler(spec):
    print('sampler')
    rows = synthetic_rows()
    sampler = StratifiedBatchSampler(rows, spec)
    composition = sampler.composition()
    check('same_domain is reported as empty',
          composition['empty_other_pools'] == ['same_domain'],
          str(composition['empty_other_pools']))
    check('effective other quota sums to 28',
          sum(composition['effective_other_pool_quota'].values()) == 28,
          str(composition['effective_other_pool_quota']))

    iterator = iter(sampler)
    batches = [next(iterator) for _ in range(50)]
    check('every batch has exactly batch_size indices',
          all(len(b) == 64 for b in batches))
    check('every batch honours the class quota',
          all(sum(1 for i in b if rows[i]['class_id'] == c) == spec['sampling']['class_quota'][str(c)]
              for b in batches for c in range(4)))
    quota = composition['effective_other_pool_quota']
    pools_ok = True
    for batch in batches:
        counts = {}
        for i in batch:
            if rows[i]['class_id'] == 3:
                counts[rows[i]['semantic_pool']] = counts.get(rows[i]['semantic_pool'], 0) + 1
        if counts != quota:
            pools_ok = False
    check('every batch honours the effective pool quota', pools_ok)

    # 50 batches draw 50*20 = 1000 samples from a 420-row HaGRID pool. A
    # round-robin over subclasses must keep the two groups near-balanced; a
    # plain pool-wide shuffle would let the larger group dominate.
    counts = {'no_gesture': 0, 'peace': 0}
    iterator = iter(sampler)
    for _ in range(50):
        for i in next(iterator):
            row = rows[i]
            if row['semantic_pool'] == 'hagrid_hand':
                counts[row['source_subclass']] += 1
    ratio = counts['no_gesture'] / max(1, counts['peace'])
    pool_ratio = 300 / 120
    check('subclasses are drawn round-robin, not proportional to pool size',
          ratio < pool_ratio / 1.5, f'drawn {ratio:.2f} vs pool {pool_ratio:.2f}')


def make_image(path, size, color):
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new('RGB', size, color).save(path, format='JPEG', quality=92)


def check_dataset(spec, root, model_config_path):
    print('dataset and augmentation')
    geometry_spec = load_config(model_config_path)
    height = geometry_spec['input']['height']
    width = geometry_spec['input']['width']
    make_image(root / 'a.jpg', (640, 480), (200, 40, 40))
    rows = [dict(sample_id='a.jpg', path='a.jpg', class_id=0,
                 semantic_pool='palm_front', source_subclass='palm',
                 source_dataset='hagrid')]
    plain = GestureDataset(rows, root, spec, train=False,
                           model_config=model_config_path)
    tensor, class_id, index = plain[0]
    check(f'item shape is 3x{height}x{width}',
          tuple(tensor.shape) == (3, height, width), str(tuple(tensor.shape)))
    check('item carries the class id and the row index',
          class_id == 0 and index == 0)

    reference, _ = preprocess_image(Image.open(root / 'a.jpg').convert('RGB'),
                                    model_config_path)
    check('unaugmented dataset output matches preprocess_image exactly',
          np.array_equal(tensor.numpy(), reference))

    augmented = GestureDataset(rows, root, spec, train=True,
                               model_config=model_config_path)
    augmented.set_epoch(3)
    first = augmented[0][0]
    second = augmented[0][0]
    check('augmentation for one (epoch, sample) is reproducible',
          torch.equal(first, second))
    reference_noaug, _ = preprocess_image(Image.open(root / 'a.jpg').convert('RGB'),
                                          model_config_path)
    check('augmentation actually changes the image',
          not np.array_equal(first.numpy(), reference_noaug))

    differ = 0
    for epoch in range(6):
        augmented.set_epoch(epoch)
        value = augmented[0][0]
        if not torch.equal(value, first):
            differ += 1
    check('augmentation varies across virtual epochs', differ >= 3,
          f'{differ}/6 epochs differ from epoch 3')

    augmented.set_epoch(3)
    check('re-seeding by epoch returns the original image',
          torch.equal(augmented[0][0], first))

    val = GestureDataset(rows, root, spec, train=False,
                         model_config=model_config_path)
    val.set_epoch(7)
    check('validation data is never augmented',
          np.array_equal(val[0][0].numpy(), reference))

    if height == width:
        # The point of a square geometry: a square source reaches the canvas with
        # no pillow at all. The training data is square, so under a 16:9 canvas
        # every sample carried grey flanks that the live camera never reproduced.
        _, square_geometry = preprocess_image(
            Image.new('RGB', (640, 640), (10, 200, 90)), model_config_path)
        check('a square source fills the square canvas with no padding',
              square_geometry['resized_wh'] == [width, height]
              and square_geometry['pad_left_top'] == [0, 0],
              str(square_geometry))

        # Rotation with expand=True and the two-axis zoom both keep a square
        # square, so augmentation cannot reintroduce the pillow.
        probe_rows = [dict(rows[0], sample_id=f'aug{sample}') for sample in range(24)]
        probe = GestureDataset(probe_rows, root, spec, train=True,
                               model_config=model_config_path)
        padded = 0
        for sample, row in enumerate(probe_rows):
            probe.set_epoch(sample)
            augmented_image = probe._augment(
                Image.new('RGB', (512, 512), (10, 200, 90)), probe._rng(row))
            if preprocess_image(augmented_image,
                                model_config_path)[1]['pad_left_top'] != [0, 0]:
                padded += 1
        check('augmenting a square source never introduces padding',
              padded == 0, f'{padded}/24 augmented samples padded')


def check_model_and_index(spec, root, model_config_path):
    print('model wiring and index')
    if not torch.cuda.is_available():
        raise SystemExit('CUDA unavailable; this project forbids CPU fallback.')
    device = torch.device('cuda:0')
    model = G4Net(model_config_path).to(device)
    check('class keys come from the model config',
          tuple(model.class_keys) == tuple(spec['class_order']),
          str(model.class_keys))
    criterion, _ = build_loss(spec)
    geometry_spec = load_config(model_config_path)
    input_chw = (geometry_spec['input']['channels'], geometry_spec['input']['height'],
                 geometry_spec['input']['width'])
    logits = model(torch.zeros(2, *input_chw, device=device))
    check('forward gives four logits per sample', tuple(logits.shape) == (2, 4))
    check('loss accepts raw logits',
          torch.isfinite(criterion(logits, torch.tensor([0, 3], device=device))))

    data_root = root / 'tree'
    make_image(data_root / '手掌/palm/a.jpg', (512, 512), (10, 120, 200))
    make_image(data_root / '手掌/palm/b.jpg', (512, 512), (10, 120, 200))
    make_image(data_root / '手掌/stop/c.jpg', (512, 512), (200, 120, 10))
    # Same bytes as a.jpg but a different class: this is the conflicted case.
    make_image(data_root / '握拳/fist/d.jpg', (512, 512), (10, 120, 200))
    make_image(data_root / '其它/no_gesture/e.jpg', (512, 512), (90, 90, 90))
    make_image(data_root / '其它/peace/f.jpg', (512, 512), (60, 60, 60))
    # `four` is claimed by class 0 and excluded from the `其它` root.
    make_image(data_root / '其它/four/h.jpg', (512, 512), (170, 90, 30))
    make_image(data_root / 'external_negatives/coco/g.jpg', (512, 512), (140, 20, 140))

    index_spec = json.loads(json.dumps(spec))
    # The real config points at an override table that only exists next to the
    # real data root; the synthetic tree declares its own, further down.
    index_spec['overrides'] = []
    index_spec['dataset_roots'] = [
        dict(root='手掌/palm', class_id=0, source_dataset='hagrid',
             source_subclass='palm', semantic_pool='palm_front',
             label_review_status='auto'),
        dict(root='手掌/stop', class_id=0, source_dataset='hagrid',
             source_subclass='stop', semantic_pool='palm_front',
             label_review_status='auto'),
        dict(root='其它/four', class_id=0, source_dataset='hagrid',
             source_subclass='four', semantic_pool='palm_front',
             label_review_status='auto'),
        dict(root='握拳/fist', class_id=2, source_dataset='hagrid',
             source_subclass='fist', semantic_pool='fist',
             label_review_status='auto'),
        dict(root='其它', class_id=3, source_dataset='hagrid',
             source_subclass_from_dir=True, semantic_pool='hagrid_hand',
             exclude_subdirs=['four'], label_review_status='auto'),
        dict(root='external_negatives', class_id=3, source_dataset_from_dir=True,
             source_subclass_from_dir=True, semantic_pool='external_negative',
             label_review_status='source_attested'),
    ]
    rows, summary = build_index(data_root, index_spec, root / 'out')
    check('duplicate bytes collapse to one row',
          summary['duplicates_dropped'] == 2, str(summary['duplicates_dropped']))
    check('a cross-class duplicate is reported as a conflict',
          len(summary['duplicate_conflicts']) == 1,
          str(summary['duplicate_conflicts'])[:160])
    check('rows are written and readable', len(read_index(root / 'out/index.jsonl')) == len(rows))
    check('splits cover every row',
          sum(sum(v.values()) for v in summary['counts_by_split'].values()) == len(rows))
    roots = {row['source_dataset'] for row in rows}
    check('external source names come from the directory',
          'coco' in roots, str(sorted(roots)))
    pools = {row['semantic_pool'] for row in rows}
    check('both other pools are represented',
          pools >= {'hagrid_hand', 'external_negative'}, str(sorted(pools)))

    repeat, _ = build_index(data_root, index_spec, root / 'out2')
    check('index build is deterministic',
          [r['path'] + r['split'] for r in rows] == [r['path'] + r['split'] for r in repeat])

    four_rows = [r for r in rows if r['path'].startswith('其它/four/')]
    check('an excluded gesture is claimed by its target class',
          len(four_rows) == 1 and four_rows[0]['class_id'] == 0
          and four_rows[0]['source_subclass'] == 'four'
          and four_rows[0]['semantic_pool'] == 'palm_front',
          str(four_rows))
    check('the excluded gesture does not also appear in `other`',
          not any(r['path'].startswith('其它/four/') and r['class_id'] == 3
                  for r in rows))

    stale = json.loads(json.dumps(index_spec))
    for entry in stale['dataset_roots']:
        if entry['root'] == '其它':
            entry['exclude_subdirs'] = ['not_a_real_dir']
    try:
        build_index(data_root, stale, root / 'out3')
        check('a stale exclusion is rejected', False)
    except RuntimeError as error:
        check('a stale exclusion is rejected', 'does not exist' in str(error))

    doubled = json.loads(json.dumps(index_spec))
    for entry in doubled['dataset_roots']:
        if entry['root'] == '其它':
            entry.pop('exclude_subdirs')
    try:
        build_index(data_root, doubled, root / 'out4')
        check('images claimed by two roots are rejected', False)
    except RuntimeError as error:
        check('images claimed by two roots are rejected',
              'more than one' in str(error), str(error)[:80])

    # `drop_subdirs` is the other half of the exclusion mechanism: those images
    # are enumerated by nobody on purpose. Four checks, because a drop that
    # silently fails just puts the images back and the counts still look sane.
    drop_spec = json.loads(json.dumps(index_spec))
    drop_spec['dataset_roots'] = [
        entry for entry in drop_spec['dataset_roots']
        if entry['root'] != '其它/four']
    for entry in drop_spec['dataset_roots']:
        if entry['root'] == '其它':
            entry.pop('exclude_subdirs')
            entry['drop_subdirs'] = ['four']
    dropped_rows, dropped_summary = build_index(data_root, drop_spec, root / 'out5')
    check('a dropped subdirectory is absent from the index',
          not any(r['path'].startswith('其它/four/') for r in dropped_rows)
          and len(dropped_rows) == len(rows) - 1,
          f'{len(rows)} rows before, {len(dropped_rows)} after')
    check('the dropped subdirectory is recorded in the summary',
          dropped_summary['dropped_subdirs'] == [dict(root='其它', subdir='four')],
          str(dropped_summary['dropped_subdirs']))

    claimed_back = json.loads(json.dumps(index_spec))
    for entry in claimed_back['dataset_roots']:
        if entry['root'] == '其它':
            entry.pop('exclude_subdirs')
            entry['drop_subdirs'] = ['four']
    try:
        build_index(data_root, claimed_back, root / 'out6')
        check('a drop that another root claims is rejected', False)
    except RuntimeError as error:
        check('a drop that another root claims is rejected',
              'claiming it back' in str(error), str(error)[:90])

    # The ambiguity check lives in load_train_config, so it has to be exercised
    # with a spec that passes every earlier validation: the real config, with
    # `four` put in both lists at once.
    ambiguous = json.loads(json.dumps(spec))
    for entry in ambiguous['dataset_roots']:
        if entry['root'] == '其它':
            entry['exclude_subdirs'] = list(entry['exclude_subdirs']) + ['four']
            entry['drop_subdirs'] = ['four']
    try:
        load_train_config(ambiguous)
        check('a name cannot be both excluded and dropped', False)
    except ValueError as error:
        check('a name cannot be both excluded and dropped',
              'cannot mean both' in str(error), str(error)[:90])

    stale_drop = json.loads(json.dumps(drop_spec))
    for entry in stale_drop['dataset_roots']:
        if entry['root'] == '其它':
            entry['drop_subdirs'] = ['not_a_real_dir']
    try:
        build_index(data_root, stale_drop, root / 'out7')
        check('a stale drop is rejected', False)
    except RuntimeError as error:
        check('a stale drop is rejected', 'does not exist' in str(error))

    # A per-image override demotes one image without touching its directory,
    # which is how too-small-to-read hands leave the target classes.
    table = data_root / 'overrides.jsonl'
    table.write_text(json.dumps(dict(
        path='其它/four/h.jpg', class_id=3, semantic_pool='hagrid_hand',
        source_subclass='small_hand', label_review_status='size_derived',
        area_max=0.0091, reason='test')) + '\n', encoding='utf-8')
    demoted = json.loads(json.dumps(index_spec))
    demoted['overrides'] = ['overrides.jsonl']
    moved_rows, moved_summary = build_index(data_root, demoted, root / 'out5')
    moved = [r for r in moved_rows if r['path'] == '其它/four/h.jpg']
    check('an override moves one image without touching its directory',
          len(moved) == 1 and moved[0]['class_id'] == 3
          and moved[0]['source_subclass'] == 'small_hand'
          and moved[0]['label_review_status'] == 'size_derived',
          str(moved))
    check('the override count and file digest are recorded',
          moved_summary['overrides_applied'] == 1
          and len(moved_summary['override_files']) == 1
          and len(moved_summary['override_files'][0]['sha256']) == 64,
          str(moved_summary['override_files']))

    table.write_text(json.dumps(dict(path='不存在/ghost.jpg', class_id=3)) + '\n',
                     encoding='utf-8')
    try:
        build_index(data_root, demoted, root / 'out6')
        check('a stale override path is rejected', False)
    except RuntimeError as error:
        check('a stale override path is rejected',
              'not in the dataset' in str(error), str(error)[:80])
    table.unlink()

    mixed = synthetic_rows()
    for row in mixed:
        row['sha256'] = row['path']
    kept, dropped, conflicts = resolve_duplicates(mixed)
    check('dedup keeps one row per distinct hash', dropped == 0 and len(kept) == len(mixed))
    assign_splits(kept, {'train': 0.9, 'val': 0.05, 'test': 0.05}, 1234)
    by_class_split = {}
    for row in kept:
        by_class_split.setdefault(row['class_id'], {}).setdefault(row['split'], 0)
        by_class_split[row['class_id']][row['split']] += 1
    check('every class appears in every split',
          all(set(v) == {'train', 'val', 'test'} for v in by_class_split.values()),
          str(by_class_split))


def main():
    spec = check_config()
    # The geometry every check below builds tensors for, resolved the same way
    # `train` resolves it: from the training config's own pairing, never from the
    # module default.
    model_config_path = resolve_model_config(spec)
    model_spec = load_config(model_config_path)
    model_keys = [c['key'] for c in model_spec['classes']]
    print('model pairing')
    check('the training config names its model config',
          model_config_path.name == spec['model_config'],
          f"{spec['model_config']} -> input "
          f"{model_spec['input']['width']}x{model_spec['input']['height']}")
    check('the named model agrees with class_order',
          model_keys == list(spec['class_order']), str(model_keys))
    check_loss()
    check_metrics()
    check_redistribution()
    check_sampler(spec)
    root = Path(tempfile.mkdtemp(prefix='gesture_selfcheck_'))
    try:
        check_dataset(spec, root / 'images', model_config_path)
        check_model_and_index(spec, root, model_config_path)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    print()
    print(f'passed {len(PASSED)}  failed {len(FAILED)}')
    if FAILED:
        print('failures:')
        for name in FAILED:
            print(f'  {name}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
