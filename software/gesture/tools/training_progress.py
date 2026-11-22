"""Print a compact progress table from a training log.

Column names are taken from the log itself, so the tool does not need editing
when the class set changes.

Usage: python tools/training_progress.py <train log> [total steps] [recall floor]

The same file is used on the training server, where the log lives under
`logs/`. `total steps` defaults to the budget in the run's own config when the
log carries a virtual-epoch count, otherwise 40,000.
"""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('total', type=int, nargs='?', default=40000)
    parser.add_argument('floor', type=float, nargs='?', default=0.8,
                        help='target recall floor, for the deploy readout')
    args = parser.parse_args()

    losses, evals = [], []
    for line in args.log.read_text(encoding='utf-8', errors='replace').splitlines():
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if 'mean_loss' in row:
            losses.append(row)
        elif 'checkpoint' in row:
            evals.append(row)

    if losses:
        first, last = losses[0], losses[-1]
        span = last['seconds'] - first['seconds']
        rate = (last['step'] - first['step']) / span if span else 0.0
        print(f"step {last['step']:,d}/{args.total:,d}  "
              f"({last['step'] / args.total:.1%})  "
              f"virtual epoch {last['virtual_epoch']}  lr {last['lr']:.3g}")
        if rate:
            print(f"elapsed {last['seconds'] / 60:.1f} min   rate {rate:.2f} step/s"
                  f"   remaining {(args.total - last['step']) / rate / 3600:.2f} h")
        print(f"samples seen {last['samples_seen']:,d}")
        stride = max(1, len(losses) // 8)
        trace = losses[::stride]
        if trace[-1] is not last:
            trace.append(last)
        print('loss: ' + '  '.join(f"{r['step']:,d}:{r['mean_loss']:.4f}"
                                   for r in trace))
        print()

    if not evals:
        print('no evaluations logged yet')
        return

    columns = list(evals[0]['target_false_positive_rate'])
    width = max(8, max(len(c) for c in columns))
    header = f"{'step':>7} {'macroF1':>8} {'acc':>7} {'worstRec':>9}  " + \
             ' '.join(f'{c:>{width}}' for c in columns)
    print(header)
    for row in evals:
        rates = row['target_false_positive_rate']
        print(f"{row['step']:>7,d} {row['macro_f1']:>8.4f} {row['accuracy']:>7.4f} "
              f"{row['worst_target_recall']:>9.4f}  "
              + ' '.join(f'{rates[c]:>{width}.4f}' for c in columns))

    best = max(evals, key=lambda r: r['macro_f1'])
    print()
    print(f"best macro-F1  {best['macro_f1']:.4f} at step {best['step']:,d}")
    print(f"best worstRec  {max(r['worst_target_recall'] for r in evals):.4f}")
    eligible = [r for r in evals if r['worst_target_recall'] >= args.floor]
    if eligible:
        pick = min(eligible,
                   key=lambda r: r['target_false_positive_rate']['any_target'])
        print(f"deploy candidate  step {pick['step']:,d}  "
              f"any-FPR {pick['target_false_positive_rate']['any_target']:.4f}  "
              f"({len(eligible)}/{len(evals)} evals met the {args.floor} floor)")
    else:
        print(f"no eval has met the {args.floor} worst-recall floor yet")


if __name__ == '__main__':
    main()
