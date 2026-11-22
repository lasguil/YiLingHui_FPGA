"""End-to-end smoke test of the G4Net v1 training loop on tiny synthetic data.

Exercises what the unit checks cannot: DataLoader plus the infinite batch
sampler, per-virtual-epoch worker respawn, evaluation, atomic checkpointing,
candidate selection and the JSONL log. Needs CUDA and about a minute.

Run from the repository root:
  python gesture/tools/smoke_train_g4net.py
"""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
GESTURE = Path(os.environ.get('GESTURE_DIR') or HERE.parent)
sys.path.insert(0, str(GESTURE))

from src.index import (TRAIN_CONFIG, build_index, load_train_config,  # noqa: E402
                       read_index, resolve_model_config)
from src.train import load_checkpoint, train                     # noqa: E402

TREE = [
    ('手掌/palm', 24, (200, 40, 40)),
    ('手掌/stop', 24, (30, 200, 60)),
    ('手背/stop_inverted', 24, (40, 60, 200)),
    ('握拳/fist', 24, (90, 90, 220)),
    ('其它/no_gesture', 40, (120, 120, 120)),
    ('其它/peace', 20, (140, 100, 80)),
    ('external_negatives/coco', 40, (60, 140, 100)),
]


def make_tree(root):
    import random
    rng = random.Random(7)
    for relative, count, base in TREE:
        directory = root / relative
        directory.mkdir(parents=True, exist_ok=True)
        for i in range(count):
            color = tuple(min(255, max(0, channel + rng.randint(-25, 25)))
                          for channel in base)
            size = rng.choice([(512, 512), (640, 480), (480, 640)])
            Image.new('RGB', size, color).save(directory / f'{i:04d}.jpg',
                                               format='JPEG', quality=90)


def main():
    spec = load_train_config()
    spec = json.loads(json.dumps(spec))
    spec['dataset_roots'] = [
        dict(root='手掌/palm', class_id=0, source_dataset='hagrid',
             source_subclass='palm', semantic_pool='palm_front',
             label_review_status='auto'),
        dict(root='手掌/stop', class_id=0, source_dataset='hagrid',
             source_subclass='stop', semantic_pool='palm_front',
             label_review_status='auto'),
        dict(root='手背/stop_inverted', class_id=1, source_dataset='hagrid',
             source_subclass='stop_inverted', semantic_pool='hand_back',
             label_review_status='auto'),
        dict(root='握拳/fist', class_id=2, source_dataset='hagrid',
             source_subclass='fist', semantic_pool='fist',
             label_review_status='auto'),
        dict(root='其它', class_id=3, source_dataset='hagrid',
             source_subclass_from_dir=True, semantic_pool='hagrid_hand',
             label_review_status='auto'),
        dict(root='external_negatives', class_id=3, source_dataset_from_dir=True,
             source_subclass_from_dir=True, semantic_pool='external_negative',
             label_review_status='source_attested'),
    ]
    spec['loader']['num_workers'] = 2
    spec['loader']['prefetch_factor'] = 2
    spec['eval']['num_workers'] = 2
    spec['eval']['batch_size'] = 16
    spec['schedule']['steps_per_virtual_epoch'] = 2
    # A 9-row validation split cannot clear the real 0.9 recall floor, so the
    # deploy candidate would never be written. Drop the floor here to exercise
    # that code path; the shipped config keeps 0.9.
    spec['checkpoint']['target_recall_floor'] = 0.0

    root = Path(tempfile.mkdtemp(prefix='gesture_smoke_'))
    try:
        data_root = root / 'datasets'
        make_tree(data_root)
        rows, summary = build_index(data_root, spec, root / 'index')
        print(f'index: {len(rows)} rows, splits '
              f'{ {k: sum(v.values()) for k, v in summary["counts_by_split"].items()} }')

        import torch
        if not torch.cuda.is_available():
            raise SystemExit('CUDA unavailable; CPU fallback is forbidden.')
        device = torch.device('cuda:0')
        print(f'device: {torch.cuda.get_device_name(device)}')

        result = train(spec, read_index(root / 'index/index.jsonl'), data_root,
                       summary, root / 'runs/smoke', device,
                       train_config_path=TRAIN_CONFIG,
                       max_steps=6, log_every=2, eval_every=2, num_workers=2,
                       eval_limit=16)

        run_dir = root / 'runs/smoke'
        expected = ['config.json', 'train.jsonl', 'progress.json', 'COMPLETE.json',
                    'latest_val_metrics.json', 'checkpoints/step_000002.pt',
                    'checkpoints/step_000004.pt', 'checkpoints/step_000006.pt',
                    'checkpoints/best_macro_f1.pt', 'checkpoints/best_deploy.pt']
        missing = [name for name in expected if not (run_dir / name).exists()]
        if missing:
            raise SystemExit(f'missing run artifacts: {missing}')

        config = json.loads((run_dir / 'config.json').read_text(encoding='utf-8'))
        assert config['index_sha256'] == summary['index_sha256']
        assert config['precision'] == 'FP32 CUDA; no AMP/TF32'
        assert config['sampling']['effective_other_pool_quota']
        assert 'same_domain' in config['sampling']['empty_other_pools']

        from src.model import G4Net
        model = G4Net(resolve_model_config(spec))
        step, metrics, _ = load_checkpoint(run_dir / 'checkpoints/best_macro_f1.pt',
                                           model, None, device)
        # A candidate file holds the step where its metric last improved, which
        # need not be the final step. It must agree with the run's bookkeeping.
        assert step == result['candidates']['macro_f1']['step'], \
            (step, result['candidates'])
        assert metrics and 'macro_f1' in metrics
        deploy_step, deploy_metrics, _ = load_checkpoint(
            run_dir / 'checkpoints/best_deploy.pt', model, None, device)
        assert deploy_step == result['candidates']['deploy']['step'], \
            (deploy_step, result['candidates'])
        assert deploy_metrics['worst_target_recall'] >= 0.0

        rows_log = [json.loads(line) for line
                    in (run_dir / 'train.jsonl').read_text(encoding='utf-8').splitlines()
                    if line.strip()]
        losses = [r['mean_loss'] for r in rows_log if 'mean_loss' in r]
        if len(losses) < 2:
            raise SystemExit('expected at least two loss rows')
        print()
        print(f'smoke ok: {len(rows_log)} log rows, losses {losses[:3]} ...')
        print(f'  candidates: { {k: v["step"] for k, v in result["candidates"].items()} }')
        print(f'  seconds   : {result["seconds"]:.1f} for 6 steps')
        print(f'  artifacts : {len(expected)} checked, all present')
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
