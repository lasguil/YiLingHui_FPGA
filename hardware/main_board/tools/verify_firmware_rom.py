"""Check that the firmware BIN and every project-root readmemh lane agree."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOFTWARE = ROOT / "software"
BIN = SOFTWARE / "build" / "product_ui_24k.bin"
PADDED = SOFTWARE / "artifacts" / "product_ui_24k_ocr_padded.bin"
LANE_DIR = SOFTWARE / "artifacts"
IMAGE_BYTES = 24 * 1024
LANE_BYTES = IMAGE_BYTES // 4


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_binary_text(path: Path, expected_bytes: int) -> tuple[bytes, bytes]:
    encoded = path.read_bytes()
    rows = path.read_text(encoding="ascii").splitlines()
    if len(rows) != expected_bytes or any(
        len(row) != 8 or set(row) - {"0", "1"} for row in rows
    ):
        raise SystemExit(f"invalid byte-lane file: {path}")
    return bytes(int(row, 2) for row in rows), encoded


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", type=Path, help="mapped Verilog emitted by this run")
    parser.add_argument("--map-log", type=Path, help="fresh Efinity map log showing readmemh inputs")
    parser.add_argument("--pgm", type=Path, help="PGM output emitted by this run")
    args = parser.parse_args()

    raw = BIN.read_bytes()
    if len(raw) > IMAGE_BYTES:
        raise SystemExit(f"firmware BIN exceeds OCR: {len(raw)} > {IMAGE_BYTES}")
    image = raw.ljust(IMAGE_BYTES, b"\0")
    if PADDED.read_bytes() != image:
        raise SystemExit("padded OCR image does not match product_ui_24k.bin")

    source = (ROOT / "rtl" / "soc" / "soc.v").read_text(encoding="utf-8")
    sources = (ROOT / "sources.f").read_text(encoding="utf-8").splitlines()
    if "rtl/soc/soc.v" not in [line.strip().replace("\\", "/") for line in sources]:
        raise SystemExit("sources.f does not include rtl/soc/soc.v")

    lane_manifest = []
    lane_values: dict[str, bytes] = {}
    for lane in range(4):
        stem = f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}"
        full_expected = image[lane::4]
        if len(full_expected) != LANE_BYTES:
            raise SystemExit(f"internal OCR lane size error: lane {lane}")
        full, full_text = read_binary_text(ROOT / f"{stem}.bin", LANE_BYTES)
        low, low_text = read_binary_text(ROOT / f"{stem}_lo.bin", 4096)
        high, high_text = read_binary_text(ROOT / f"{stem}_hi.bin", 2048)
        if full != full_expected or low != full_expected[:4096] or high != full_expected[4096:]:
            raise SystemExit(f"project-root ROM lane {lane} differs from padded OCR image")
        # pack_24k_lanes.py keeps the unsplit 6144-byte mirrors under
        # software/artifacts; only the project-root readmemh files are split.
        artifact_path = LANE_DIR / f"{stem}.bin"
        artifact_value, _ = read_binary_text(artifact_path, LANE_BYTES)
        if artifact_value != full:
            raise SystemExit(f"artifact lane mirror differs: {artifact_path}")
        lane_values[f"{stem}.bin"] = full
        lane_manifest.extend([
            {"file": f"{stem}.bin", "bytes": len(full), "sha256": sha(full_text)},
            {"file": f"{stem}_lo.bin", "bytes": len(low), "sha256": sha(low_text)},
            {"file": f"{stem}_hi.bin", "bytes": len(high), "sha256": sha(high_text)},
        ])

    loaded = re.findall(r'\$readmemb\("([^"]+\.bin)"', source)
    expected_loaded = [
        f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}_{part}.bin"
        for part in ("lo", "hi") for lane in range(4)
    ]
    if sorted(loaded) != sorted(expected_loaded):
        raise SystemExit(f"soc.v readmemh inputs mismatch: {loaded}")

    generated = (SOFTWARE / "style_model_assets_generated.h").read_text(encoding="utf-8")
    count_match = re.search(r"#define STYLE_MODEL_ASSET_COUNT (\d+)u", generated)
    assets = json.loads((ROOT / "assets/catalog_manifest.json").read_text(encoding="utf-8"))
    expected_names = [model["display_name"] for model in assets["models"]]
    if not count_match or int(count_match.group(1)) != len(expected_names) or len(expected_names) != 29:
        raise SystemExit("generated model catalog count is not the expected 29")
    model_names = re.findall(r'^\s*\{"([A-Z0-9]+)"\s*, STYLE_MODEL_DDR_BASE', generated, re.M)
    if model_names != expected_names or any(name.encode("ascii") not in raw for name in model_names):
        raise SystemExit("built firmware BIN/catalog does not contain all 29 model directory names in order")

    if args.map:
        map_path = args.map if args.map.is_absolute() else ROOT / args.map
        if not map_path.is_file() or map_path.stat().st_mtime_ns < max(
            (ROOT / record["file"]).stat().st_mtime_ns for record in lane_manifest
        ):
            raise SystemExit("mapped output is missing or older than its ROM lane inputs")
        if not args.map_log:
            raise SystemExit("mapped verification requires the Efinity log proving which readmemh lanes were loaded")
        log_path = args.map_log if args.map_log.is_absolute() else ROOT / args.map_log
        if not log_path.is_file() or log_path.stat().st_mtime_ns < max(
            (ROOT / record["file"]).stat().st_mtime_ns for record in lane_manifest
        ):
            raise SystemExit("fresh Efinity map log is missing or predates the ROM lane inputs")
        map_log = log_path.read_text(encoding="utf-8", errors="ignore")
        for name in expected_loaded:
            if not re.search(
                rf"readmemb: reading from file ['\"]{re.escape(name)}['\"]",
                map_log,
            ):
                raise SystemExit(f"fresh Efinity log does not prove readmemh input {name}")
        mapped = map_path.read_text(encoding="utf-8", errors="ignore")
        for lane in range(4):
            for part in ("lo", "hi"):
                ident = f"ram_symbol{lane}_{part}"
                if ident not in mapped:
                    raise SystemExit(f"mapped netlist omits initialized OCR bank {ident}")
        if mapped.count(".INIT_") < 8:
            raise SystemExit("mapped netlist lacks RAM initialization parameters")

    if args.pgm:
        pgm_path = args.pgm if args.pgm.is_absolute() else ROOT / args.pgm
        if not pgm_path.is_file():
            raise SystemExit("PGM output is missing")
        map_path = args.map if args.map and args.map.is_absolute() else ROOT / args.map if args.map else None
        if map_path and pgm_path.stat().st_mtime_ns < map_path.stat().st_mtime_ns:
            raise SystemExit("PGM output predates the verified mapped output")

    record = {
        "raw_bin_bytes": len(raw),
        "raw_bin_sha256": sha(raw),
        "ocr_bytes": len(image),
        "ocr_sha256": sha(image),
        "lane_bytes": LANE_BYTES,
        "lane_rows": LANE_BYTES,
        "model_count": len(model_names),
        "model_names": model_names,
        "readmemh_files": loaded,
        "lanes": lane_manifest,
        "mapped_netlist": str(args.map) if args.map else None,
        "mapped_log": str(args.map_log) if args.map_log else None,
        "pgm": str(args.pgm) if args.pgm else None,
    }
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
