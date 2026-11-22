"""Convert the flat OCR firmware binary into four Sapphire ROM lane files."""

from hashlib import sha256
import argparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMAGE_BYTES = 16 * 1024
STACK_RESERVE = 2048


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", default="build/gesture_demo.bin")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build")
    args = parser.parse_args()
    source = Path(args.source)
    if not source.is_absolute():
        source = ROOT / source
    image = source.read_bytes()
    if len(image) > IMAGE_BYTES - STACK_RESERVE:
        raise SystemExit(
            f"OCR firmware binary is {len(image)} bytes; limit is {IMAGE_BYTES - STACK_RESERVE}"
        )
    padded = image.ljust(IMAGE_BYTES, b"\0")
    digest = sha256(padded).hexdigest()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for lane in range(4):
        target = args.output_dir / f"gesture_demo_ram_symbol{lane}.bin"
        with target.open("w", encoding="ascii", newline="\n") as output:
            output.write("".join(f"{byte:08b}\n" for byte in padded[lane::4]))
    print(
        f"OCR ROM image: flat={len(image)} bytes, padded={IMAGE_BYTES} bytes, "
        f"lane=4096 words, SHA256={digest}; output={args.output_dir}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
