"""Pool-aware stratified batch sampling for G4Net v1.

Every batch satisfies the configured class quota exactly, and the `other` class
is split further across semantic pools. Inside a pool, source subclasses are
drawn round-robin, so one large source cannot monopolise the quota: HaGRID
`no_gesture` alone is 27,823 of the 125,768 `other` images.

A pool that has no training rows is treated as absent, and its quota is
redistributed proportionally over the pools that do exist. The effective quota
is exposed for the run log, because the measured composition is what the model
actually sees.
"""
import random
from collections import defaultdict

OTHER_CLASS_ID = 3


def redistribute_quota(configured, available_pools):
    """Move quota from empty pools to existing ones, keeping the total fixed."""
    total = sum(configured.values())
    live = {name: weight for name, weight in configured.items()
            if weight > 0 and name in available_pools}
    if not live:
        raise RuntimeError('every `other` pool is empty')
    weight_sum = sum(live.values())
    exact = {name: total * weight / weight_sum for name, weight in live.items()}
    quota = {name: int(value) for name, value in exact.items()}
    leftover = total - sum(quota.values())
    # Largest-remainder seats; ties break on name so the split is deterministic.
    order = sorted(exact, key=lambda name: (-(exact[name] - quota[name]), name))
    for name in order[:leftover]:
        quota[name] += 1
    if sum(quota.values()) != total:
        raise AssertionError('quota redistribution lost samples')
    return dict(sorted(quota.items()))


class _Cycle:
    """Round-robin draw across subgroups, without replacement until exhausted."""

    def __init__(self, groups, rng):
        self.rng = rng
        self.names = sorted(groups)
        self.originals = {name: list(groups[name]) for name in self.names}
        self.pools = {name: list(values) for name, values in self.originals.items()}
        for name in self.names:
            rng.shuffle(self.pools[name])
        self.cursor = 0
        self.refills = 0

    def __len__(self):
        return sum(len(values) for values in self.originals.values())

    def draw(self):
        for _ in range(2 * len(self.names)):
            name = self.names[self.cursor % len(self.names)]
            self.cursor += 1
            if not self.pools[name]:
                self.refills += 1
                self.pools[name] = list(self.originals[name])
                self.rng.shuffle(self.pools[name])
            if self.pools[name]:
                return self.pools[name].pop()
        raise RuntimeError('sample group is empty')


class StratifiedBatchSampler:
    """Infinite iterator of index batches honouring the class and pool quotas."""

    def __init__(self, rows, spec, seed=None):
        sampling = spec['sampling']
        self.batch_size = sampling['batch_size']
        self.class_quota = {int(k): int(v) for k, v in sampling['class_quota'].items()}
        configured = {k: int(v) for k, v in sampling['other_pool_quota'].items()}
        rng = random.Random(spec['seed'] if seed is None else seed)

        by_class = defaultdict(lambda: defaultdict(list))
        by_pool = defaultdict(lambda: defaultdict(list))
        for position, row in enumerate(rows):
            by_class[row['class_id']][row['source_subclass']].append(position)
            if row['class_id'] == OTHER_CLASS_ID:
                by_pool[row['semantic_pool']][row['source_subclass']].append(position)

        missing = sorted(set(self.class_quota) - set(by_class))
        if missing:
            raise RuntimeError(f'classes with no training rows: {missing}')
        self.class_cycles = {class_id: _Cycle(groups, rng)
                             for class_id, groups in by_class.items()
                             if class_id != OTHER_CLASS_ID}

        available = {name: groups for name, groups in by_pool.items()
                     if sum(len(v) for v in groups.values())}
        self.configured_pool_quota = dict(sorted(configured.items()))
        self.empty_pools = sorted(set(configured) - set(available))
        self.effective_pool_quota = redistribute_quota(configured, available)
        if sum(self.effective_pool_quota.values()) != self.class_quota[OTHER_CLASS_ID]:
            raise AssertionError('pool quota does not match the `other` class quota')
        self.pool_cycles = {name: _Cycle(available[name], rng)
                            for name in self.effective_pool_quota}

    def __iter__(self):
        while True:
            batch = []
            for class_id in sorted(self.class_quota):
                if class_id == OTHER_CLASS_ID:
                    for pool in sorted(self.effective_pool_quota):
                        cycle = self.pool_cycles[pool]
                        for _ in range(self.effective_pool_quota[pool]):
                            batch.append(cycle.draw())
                else:
                    cycle = self.class_cycles[class_id]
                    for _ in range(self.class_quota[class_id]):
                        batch.append(cycle.draw())
            if len(batch) != self.batch_size:
                raise AssertionError(f'batch has {len(batch)} != {self.batch_size}')
            yield batch

    def composition(self):
        """Configured vs effective composition, for the run log."""
        return dict(
            batch_size=self.batch_size,
            class_quota=self.class_quota,
            configured_other_pool_quota=self.configured_pool_quota,
            effective_other_pool_quota=self.effective_pool_quota,
            empty_other_pools=self.empty_pools,
            pool_sizes={name: len(cycle) for name, cycle in self.pool_cycles.items()},
            class_sizes={class_id: len(cycle)
                         for class_id, cycle in self.class_cycles.items()},
        )
