"""Reject CPU SR false-path patterns that match synchronous mapped FFs.

Run after map: python -I -B tools/check_sdc_cpu_async_sr.py outflow/ti60f225_oob.map.v
This checks the normalized SDC against the actual netlist, not a fixed cell list.
"""
import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('netlist', type=Path)
    parser.add_argument('--sdc', type=Path, default=Path(__file__).resolve().parents[1] / 'ti60f225_oob.sdc')
    args = parser.parse_args()
    text = args.netlist.read_text(encoding='utf-8', errors='strict')
    inventory = dict(re.findall(r"defparam\s+\\(g_accelerated\.u_cpu_control/[^\s]+)\s+\.SR_SYNC\s*=\s*1'b([01]);", text))
    if not inventory:
        raise SystemExit('FAIL: no mapped CPU FF SR_SYNC attributes found')
    patterns = []
    for line in args.sdc.read_text(encoding='utf-8').splitlines():
        if line.strip().startswith('set_false_path'):
            patterns += re.findall(r'g_accelerated\.u_cpu_control/[^\s{}]+\|SR', line)
    if not patterns:
        raise SystemExit('FAIL: no CPU SR exceptions found')
    selected = set()
    for pattern in patterns:
        # SDC register brackets are literal here; '*'/'?' are wildcards.
        regex = re.escape(pattern[:-3]).replace(r'\*', '.*').replace(r'\?', '.')
        hits = {name for name in inventory if re.fullmatch(regex, name)}
        if not hits:
            raise SystemExit(f'FAIL: stale CPU SR pattern: {pattern}')
        bad = sorted(name for name in hits if inventory[name] != '0')
        if bad:
            raise SystemExit(f'FAIL: synchronous SR cut by {pattern}: {bad}')
        selected.update(hits)
    synchronous = {name for name, value in inventory.items() if value == '1'}
    if not synchronous:
        raise SystemExit('FAIL: expected synchronous CPU SR paths absent; inspect netlist')
    print(f'PASS: {len(patterns)} patterns select {len(selected)} asynchronous SRs; '
          f'{len(synchronous)} synchronous SRs remain timed')


if __name__ == '__main__':
    main()
