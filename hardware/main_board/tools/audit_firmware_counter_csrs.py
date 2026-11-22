"""Reject firmware disassembly that reads unsupported architectural counters."""
from pathlib import Path
import argparse
import re
import sys


UNSUPPORTED = re.compile(
    r"\b(?:m?cycleh?|mtimeh?|timeh?|m?instreth?|mhpmcounter\d+|hpmcounter\d+)\b",
    re.IGNORECASE,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("objdump", type=Path, help="RISC-V objdump -d output for the firmware being embedded")
    args = parser.parse_args()
    if not args.objdump.is_file():
        parser.error(f"objdump file does not exist: {args.objdump}")
    hits = []
    for line in args.objdump.read_text(encoding="utf-8", errors="replace").splitlines():
        if "\t" in line and UNSUPPORTED.search(line.rsplit("\t", 1)[-1]):
            hits.append(line.strip())
    if hits:
        print("FAIL firmware references unsupported counter/time CSR instruction:", file=sys.stderr)
        print("\n".join(hits), file=sys.stderr)
        return 1
    print(f"PASS unsupported counter CSR scan: {args.objdump} contains no cycle/time/instret/HPM CSR instructions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
