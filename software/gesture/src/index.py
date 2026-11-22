"""Build the G4Net v1 training index: enumerate, hash, deduplicate and split.

The index is one JSONL row per usable image plus a summary JSON carrying the
counts, the split seed and content fingerprints. Row paths are relative to the
data root and always use forward slashes.

`sample_id` and `path` hold the same value today; they are kept apart so the
identifier survives a future re-layout of the image tree.
"""
import hashlib
import json
import random
from pathlib import Path

from .spec import CONFIG_DIR, DEFAULT_CONFIG, load_config

IMAGE_EXTS = ('.jpeg', '.jpg', '.png', '.bmp', '.webp')
TRAIN_CONFIG = Path(__file__).resolve().parents[1] / 'configs/g4net_v4_train.json'


def resolve_model_config(spec, train_config_path=None):
    """Resolve the model spec a training config trains.

    Input geometry is part of a checkpoint's identity, so a training config has
    to name its model. Newer configs carry an explicit `model_config`; the older
    ones predate the field but are named `<model_id>_train.json`, which encodes
    the same pairing, so their sibling `<model_id>.json` is the right answer for
    them too. What this avoids is a silent fall back to the module default, which
    would go on training the old framing from a new default without saying so.
    """
    path = None
    name = spec.get('model_config')
    if name:
        path = Path(name)
        if not path.is_absolute():
            path = CONFIG_DIR / path
    elif train_config_path is not None:
        stem = Path(train_config_path).stem
        if stem.endswith('_train'):
            candidate = CONFIG_DIR / f'{stem[:-len("_train")]}.json'
            path = candidate if candidate.is_file() else None
    if path is None:
        path = DEFAULT_CONFIG
    if not path.is_file():
        raise FileNotFoundError(f'model config not found: {path}')
    return path


def load_train_config(config=None):
    """Load and validate the training config; accepts a dict, a path or None."""
    if isinstance(config, dict):
        spec = json.loads(json.dumps(config))
        config_path = None
    else:
        config_path = Path(config or TRAIN_CONFIG)
        spec = json.loads(config_path.read_text(encoding='utf-8'))
    if spec['schema_version'] != 1:
        raise ValueError('Unsupported training config schema.')
    ratio = spec['split_ratio']
    if abs(sum(ratio.values()) - 1.0) > 1e-9 or set(ratio) != {'train', 'val', 'test'}:
        raise ValueError('split_ratio must cover train/val/test and sum to 1.')
    order = spec.get('class_order')
    if not isinstance(order, list) or len(order) != 4 or len(set(order)) != 4:
        raise ValueError('class_order must list four distinct class keys')
    overrides = spec.get('overrides', [])
    if not isinstance(overrides, list) or not all(isinstance(n, str) for n in overrides):
        raise ValueError('overrides must be a list of table file names')
    quota = spec['sampling']['class_quota']
    if sorted(int(k) for k in quota) != [0, 1, 2, 3]:
        raise ValueError('class_quota must cover class ids 0..3.')
    if sum(quota.values()) != spec['sampling']['batch_size']:
        raise ValueError('class_quota must sum to batch_size.')
    pools = spec['sampling']['other_pool_quota']
    if sum(pools.values()) != quota['3']:
        raise ValueError('other_pool_quota must sum to the class 3 quota.')
    seen = set()
    for entry in spec['dataset_roots']:
        if entry['root'] in seen:
            raise ValueError(f'duplicate dataset root: {entry["root"]}')
        seen.add(entry['root'])
        if not 0 <= entry['class_id'] <= 3:
            raise ValueError(f'bad class_id in {entry}')
        if entry.get('semantic_pool') not in set(pools) | set(spec['class_order']):
            raise ValueError(f'unknown semantic pool in {entry}')
        excluded = entry.get('exclude_subdirs', [])
        dropped = entry.get('drop_subdirs', [])
        for field, values in (('exclude_subdirs', excluded), ('drop_subdirs', dropped)):
            if not isinstance(values, list) or not all(isinstance(n, str) for n in values):
                raise ValueError(f'{field} must be a list of directory names: {entry}')
        overlap = sorted(set(excluded) & set(dropped))
        if overlap:
            raise ValueError(
                f'{entry["root"]} both excludes and drops {overlap}. Excluding means '
                f'another root claims those images, dropping means nobody does, so '
                f'the same name cannot mean both.')
    model_path = resolve_model_config(spec, config_path)
    model_spec = load_config(model_path)
    model_order = [c['key'] for c in model_spec['classes']]
    if model_order != list(spec['class_order']):
        raise ValueError(f'{model_path.name} declares classes {model_order}, but '
                         f'class_order is {spec["class_order"]}; the two have to '
                         f'agree or the four outputs mean different things.')
    # Normalised so that every consumer, including legacy configs, can read the
    # pairing straight off the loaded spec.
    spec['model_config'] = model_path.name
    return spec


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def _iter_images(directory):
    for path in sorted(directory.rglob('*')):
        if path.is_file() and path.suffix.lower() in IMAGE_EXTS:
            yield path


def load_overrides(paths, data_root):
    """Read JSONL override tables: one row per image, keyed by its data-root path.

    An override can replace any of class_id / semantic_pool / source_subclass /
    label_review_status for a single image, which directory-level rules cannot
    express. The table file is the record of why: it carries the measurement
    that triggered the move.
    """
    overrides = {}
    files = []
    for name in paths:
        path = Path(name)
        if not path.is_absolute():
            path = Path(data_root) / path
        if not path.is_file():
            raise FileNotFoundError(f'missing override table: {path}')
        for line in path.read_text(encoding='utf-8').splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if 'path' not in row:
                raise ValueError(f'override row without a path in {path}')
            if row['path'] in overrides:
                raise ValueError(f'{row["path"]} is listed in more than one '
                                 f'override table')
            overrides[row['path']] = row
        files.append(path)
    return overrides, files


def apply_overrides(rows, overrides):
    """Reassign the listed images. A path that is not in the dataset fails the build."""
    if not overrides:
        return 0
    index = {row['path']: row for row in rows}
    missing = sorted(set(overrides) - set(index))
    if missing:
        raise RuntimeError(f'{len(missing)} override paths are not in the dataset, '
                           f'first: {missing[:3]}')
    fields = ('class_id', 'semantic_pool', 'source_subclass', 'label_review_status')
    for path, override in overrides.items():
        row = index[path]
        for field in fields:
            if field in override:
                row[field] = override[field]
    return len(overrides)


def enumerate_rows(data_root, spec, progress=None):
    """Walk every configured root and return unsplit, undeduplicated rows.

    A root may exclude named subdirectories. That is how a gesture is moved out
    of `other` and into a target class: the shared parent root skips it and a
    dedicated entry claims it, so no image is enumerated twice.

    A root may also *drop* named subdirectories: those are enumerated by nobody
    and are deliberately absent from the index. A drop is checked twice, because
    the failure it guards against is silent. The name has to exist on disk, the
    same as an exclusion, and no row may end up under it — which is what catches
    a drop that a dedicated root is quietly claiming back.
    """
    data_root = Path(data_root)
    rows = []
    dropped_prefixes = []
    for entry in spec['dataset_roots']:
        root = data_root / entry['root']
        if not root.is_dir():
            raise FileNotFoundError(f'missing dataset root: {root}')
        excluded = set(entry.get('exclude_subdirs', ()))
        dropped = set(entry.get('drop_subdirs', ()))
        if entry.get('source_subclass_from_dir'):
            children = [d for d in sorted(root.iterdir()) if d.is_dir()]
            names = {d.name for d in children}
            missing = sorted((excluded | dropped) - names)
            if missing:
                raise RuntimeError(
                    f'{root} excludes or drops {missing}, which does not exist; a '
                    f'stale rule would silently put those images back in this class')
            group_dirs = [d for d in children if d.name not in excluded | dropped]
            for name in sorted(dropped):
                dropped_prefixes.append(
                    (root / name).relative_to(data_root).as_posix() + '/')
        else:
            if excluded or dropped:
                raise ValueError(f'{entry["root"]} declares exclude_subdirs or '
                                 f'drop_subdirs but is not a per-subdirectory root')
            group_dirs = [root]
        if not group_dirs:
            raise FileNotFoundError(f'no subdirectories under {root}')
        for group in group_dirs:
            for image in _iter_images(group):
                rel = image.relative_to(data_root).as_posix()
                rows.append(dict(
                    sample_id=rel,
                    path=rel,
                    class_id=entry['class_id'],
                    source_dataset=(group.name if entry.get('source_dataset_from_dir')
                                    else entry['source_dataset']),
                    source_subclass=(group.name if entry.get('source_subclass_from_dir')
                                     else entry.get('source_subclass', group.name)),
                    semantic_pool=entry['semantic_pool'],
                    label_review_status=entry['label_review_status'],
                ))
                if progress is not None and len(rows) % 20000 == 0:
                    progress(len(rows))
    if not rows:
        raise RuntimeError(f'no images found under {data_root}')
    paths = [row['path'] for row in rows]
    if len(paths) != len(set(paths)):
        seen, duplicates = set(), []
        for path in paths:
            if path in seen:
                duplicates.append(path)
            seen.add(path)
        raise RuntimeError(f'{len(duplicates)} images are claimed by more than one '
                           f'dataset root, first: {duplicates[:3]}')
    for prefix in dropped_prefixes:
        offenders = [row['path'] for row in rows if row['path'].startswith(prefix)]
        if offenders:
            raise RuntimeError(
                f'{prefix} is declared dropped but {len(offenders)} of its images '
                f'are in the index anyway (first: {offenders[0]}); another dataset '
                f'root is claiming it back')
    return rows


def attach_hashes(rows, data_root, progress=None):
    """Add sha256 to every row; duplicates are resolved later."""
    data_root = Path(data_root)
    for i, row in enumerate(rows, 1):
        row['sha256'] = sha256_file(data_root / row['path'])
        if progress is not None and i % 20000 == 0:
            progress(i)
    return rows


def resolve_duplicates(rows):
    """Collapse identical content to one row and report cross-class conflicts.

    The kept row is the lexicographically first path so the result does not
    depend on directory iteration order.
    """
    by_hash = {}
    for row in sorted(rows, key=lambda r: r['path']):
        by_hash.setdefault(row['sha256'], []).append(row)
    kept, conflicts = [], []
    for digest in sorted(by_hash):
        group = by_hash[digest]
        classes = {r['class_id'] for r in group}
        if len(classes) > 1:
            conflicts.append(dict(sha256=digest,
                                  paths=[r['path'] for r in group],
                                  class_ids=sorted(classes)))
        winner = group[0]
        winner['duplicate_group'] = digest[:16] if len(group) > 1 else None
        kept.append(winner)
    dropped = len(rows) - len(kept)
    return kept, dropped, conflicts


def assign_splits(rows, ratio, seed):
    """Class-stratified deterministic split; mutates and returns the rows."""
    for class_id in sorted({r['class_id'] for r in rows}):
        members = sorted((r for r in rows if r['class_id'] == class_id),
                         key=lambda r: r['path'])
        rng = random.Random(seed + class_id)
        rng.shuffle(members)
        n_val = round(ratio['val'] * len(members))
        n_test = round(ratio['test'] * len(members))
        for i, row in enumerate(members):
            if i < n_val:
                row['split'] = 'val'
            elif i < n_val + n_test:
                row['split'] = 'test'
            else:
                row['split'] = 'train'
    return rows


def count_by(rows, key):
    counts = {}
    for row in rows:
        counts[row[key]] = counts.get(row[key], 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: str(kv[0])))


def summarize(rows, spec, data_root, dropped, conflicts, overrides=0,
              override_files=()):
    """Counts and provenance that travel with the index into every checkpoint."""
    summary = dict(
        schema_version=1,
        data_root=str(data_root),
        seed=spec['seed'],
        split_ratio=spec['split_ratio'],
        class_order=list(spec['class_order']),
        # Declared, so a row count that looks low has a written reason rather
        # than whatever the reader guesses.
        dropped_subdirs=[dict(root=entry['root'], subdir=name)
                         for entry in spec['dataset_roots']
                         for name in entry.get('drop_subdirs', [])],
        total_after_dedup=len(rows),
        duplicates_dropped=dropped,
        duplicate_conflicts=conflicts,
        overrides_applied=overrides,
        override_files=[dict(name=path.name, sha256=sha256_file(path))
                        for path in override_files],
        counts_total=count_by(rows, 'class_id'),
        counts_by_split={},
        counts_by_split_and_source={},
        counts_by_pool={},
    )
    for split in ('train', 'val', 'test'):
        subset = [r for r in rows if r['split'] == split]
        summary['counts_by_split'][split] = count_by(subset, 'class_id')
        summary['counts_by_split_and_source'][split] = count_by(subset, 'source_dataset')
    summary['counts_by_pool'] = count_by(rows, 'semantic_pool')
    summary['counts_by_source_total'] = count_by(rows, 'source_dataset')
    summary['counts_by_subclass_total'] = count_by(rows, 'source_subclass')
    return summary


def write_index(out_dir, rows, summary):
    """Write index.jsonl and index_summary.json; returns the summary."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(row, ensure_ascii=False, sort_keys=False) for row in rows]
    text = '\n'.join(lines) + '\n'
    (out_dir / 'index.jsonl').write_text(text, encoding='utf-8')
    summary['index_sha256'] = sha256_text(text)
    summary['index_rows'] = len(rows)
    (out_dir / 'index_summary.json').write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return summary


def read_index(path):
    """Read index.jsonl into a list of rows."""
    path = Path(path)
    return [json.loads(line) for line in
            path.read_text(encoding='utf-8').splitlines() if line.strip()]


def build_index(data_root, spec, out_dir, progress=None):
    rows = enumerate_rows(data_root, spec, progress)
    overrides, override_files = load_overrides(spec.get('overrides', []), data_root)
    applied = apply_overrides(rows, overrides)
    attach_hashes(rows, data_root, progress)
    rows, dropped, conflicts = resolve_duplicates(rows)
    assign_splits(rows, spec['split_ratio'], spec['seed'])
    rows.sort(key=lambda r: (r['class_id'], r['path']))
    summary = summarize(rows, spec, data_root, dropped, conflicts, applied,
                        override_files)
    return rows, write_index(out_dir, rows, summary)
