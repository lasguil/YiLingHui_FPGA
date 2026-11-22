"""Program the generated model+LUT bundle at its fixed external-Flash region.

Dry-run is the default. The destructive path requires --program, an explicit
HiFTDI target, and CURRENT_PROJECT.json binding the active bit to this exact
bundle. It never touches the configuration image at address zero.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "CURRENT_PROJECT.json"
ASSET_MANIFEST = ROOT / "assets/catalog_manifest.json"
BUNDLE = ROOT / "assets/model_bundle_29x16k_lut12.bin"
LOG_DIR = ROOT / "tmp/model_bundle_flash"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def crc16(data: bytes) -> int:
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ 0x1021) & 0xFFFF if value & 0x8000 else (value << 1) & 0xFFFF
    return value


def image() -> tuple[dict, dict, bytes, int]:
    record = json.loads(MANIFEST.read_text(encoding="utf-8"))
    manifest = json.loads(ASSET_MANIFEST.read_text(encoding="utf-8"))
    bundle = BUNDLE.read_bytes()
    layout = manifest["bundle_layout"]
    base = int(layout["flash_base"], 16)
    expected_crc = f"{crc16(bundle):04x}"
    if (base != 0x00400000 or len(bundle) != 29 * 16384 + 12 * 768 or
            len(manifest["models"]) != 29 or len(manifest["lut_order"]) != 12):
        raise RuntimeError("bundle address/length does not match the 29-model+12-LUT layout")
    if len(bundle) != manifest.get("bundle_bytes") or sha(bundle) != manifest.get("bundle_sha256"):
        raise RuntimeError("bundle length or SHA-256 differs from catalog manifest")
    if expected_crc != manifest.get("bundle_crc16_ccitt_false"):
        raise RuntimeError("bundle CRC-16/CCITT-FALSE differs from catalog manifest")
    return record, manifest, bundle, base


def binding_check(record: dict, manifest: dict, record_sha: str) -> None:
    if "TIMING_FAILED" in str(record.get("latest_status", "")).upper():
        raise RuntimeError("refusing to program a bundle paired with a TIMING_FAILED configuration candidate")
    binding = record.get("asset_bundle")
    if not isinstance(binding, dict):
        raise RuntimeError("CURRENT_PROJECT.json has no asset_bundle binding for the active bit")
    expected = {
        "bytes": manifest["bundle_bytes"],
        "sha256": manifest["bundle_sha256"],
        "crc16_ccitt_false": manifest["bundle_crc16_ccitt_false"],
        "flash_base": manifest["bundle_layout"]["flash_base"],
        "model_count": len(manifest["models"]),
        "lut_count": len(manifest["lut_order"]),
        "validated_for_bit_sha256": record_sha,
    }
    for key, value in expected.items():
        if binding.get(key) != value:
            raise RuntimeError(f"active bit / bundle binding mismatch at asset_bundle.{key}")
    bit_path = (ROOT / record["latest_bit"]).resolve()
    bit_path.relative_to(ROOT.resolve())
    if not bit_path.is_file() or sha(bit_path.read_bytes()) != record_sha:
        raise RuntimeError("latest bit is absent or differs from CURRENT_PROJECT.json")


def write_byte_hex(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{byte:02X}\n" for byte in payload), encoding="ascii", newline="\n")


def load_programmer(log_dir: Path):
    source = ROOT / "tools/program_flash_hiftdi.py"
    spec = importlib.util.spec_from_file_location("style_flash_programmer", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the project's tested HiFTDI adapter")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.LOGS = log_dir
    module.LOGS.mkdir(parents=True, exist_ok=True)
    module.install_hiftdi_adapter()
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--dry-run", action="store_true", help="validate and print the exact package plan (default)")
    group.add_argument("--program", action="store_true", help="erase/write/read back only the model bundle range")
    parser.add_argument("--target", help="explicit HiFTDI URL required with --program")
    args = parser.parse_args()
    record, manifest, bundle, base = image()
    end = base + len(bundle)
    bit_sha = record.get("bit_sha256")
    binding_error = None
    try:
        binding_check(record, manifest, bit_sha)
    except RuntimeError as exc:
        binding_error = str(exc)
    if args.program:
        if not args.target:
            raise RuntimeError("--program requires an explicit --target HiFTDI URL")
        if binding_error:
            raise RuntimeError(binding_error)
    print(json.dumps({
        "mode": "program" if args.program else "dry_run",
        "bundle": str(BUNDLE.relative_to(ROOT)),
        "bytes": len(bundle),
        "sha256": sha(bundle),
        "crc16_ccitt_false": f"{crc16(bundle):04x}",
        "flash_range_exclusive": [base, end],
        "erase_range_exclusive": [base, ((end + 4095) // 4096) * 4096],
        "models": len(manifest["models"]),
        "lut_tables": len(manifest["lut_order"]),
        "active_bit_sha256": bit_sha,
        "bound_to_active_bit": binding_error is None,
        "binding_error": binding_error,
        "target": args.target,
    }, indent=2))
    if not args.program:
        return 0

    record, _, _, _ = image()
    bit_path = (ROOT / record["latest_bit"]).resolve()
    hex_path = LOG_DIR / "model_bundle_29x16k_lut12.hex"
    before_path = LOG_DIR / "flash_model_region_before.hex"
    readback_path = LOG_DIR / "model_bundle_readback.hex"
    write_byte_hex(hex_path, bundle)
    programmer = load_programmer(LOG_DIR)
    programmer.URL = args.target
    try:
        code, output = programmer.invoke("bridge_load", ["-m", "jtag", "-u", args.target,
            "--jtag_clock_freq", str(programmer.JTAG_HZ), str(programmer.BRIDGE)])
        if code or programmer.FPGA_ID.lower() not in output.lower():
            raise RuntimeError("JTAG-to-SPI bridge load or FPGA ID check failed")
        erase_end = ((end + 4095) // 4096) * 4096
        code, output = programmer.invoke("read_model_region_before", ["-m", "jtag_bridge", "-u", args.target,
            "--jtag_clock_freq", str(programmer.JTAG_HZ), "--jtag_bridge_mode", "read",
            "--address", f"0x{base:08x}", "--num_bytes", str(erase_end - base), "-o",
            before_path, str(hex_path)])
        if code or "Finished read" not in output:
            raise RuntimeError("pre-write read of the full erase-aligned bundle range failed")
        before_lines = before_path.read_text(encoding="ascii").splitlines()
        if len(before_lines) != erase_end - base or any(not re.fullmatch(r"[0-9A-Fa-f]{2}", line) for line in before_lines):
            raise RuntimeError("pre-write Flash readback has unexpected length/encoding")
        before = bytes(int(line, 16) for line in before_lines)
        # A NOR erase reaches the 4 KiB boundary. Preserve any pre-existing
        # bytes in that final partial sector instead of silently erasing them.
        flash_payload = bundle + before[len(bundle):]
        write_byte_hex(hex_path, flash_payload)
        code, output = programmer.invoke("program_model_bundle", ["-m", "jtag_bridge", "-u", args.target,
            "--jtag_clock_freq", str(programmer.JTAG_HZ), "--jtag_bridge_mode", "all",
            "--verify_method", "none", "--address", f"0x{base:08x}", str(hex_path)])
        if code or "JTAG2SPI programming...done" not in output:
            raise RuntimeError("model bundle Flash programming did not complete")
        code, output = programmer.invoke("bridge_reload_for_readback", ["-m", "jtag", "-u", args.target,
            "--jtag_clock_freq", str(programmer.JTAG_HZ), str(programmer.BRIDGE)])
        if code or programmer.FPGA_ID.lower() not in output.lower():
            raise RuntimeError("bridge reload before independent readback failed")
        code, output = programmer.invoke("model_bundle_readback", ["-m", "jtag_bridge", "-u", args.target,
            "--jtag_clock_freq", str(programmer.JTAG_HZ), "--jtag_bridge_mode", "read",
            "--address", f"0x{base:08x}", "--num_bytes", str(len(flash_payload)), "-o", readback_path, str(hex_path)])
        if code or "Finished read" not in output:
            raise RuntimeError("model bundle independent readback failed")
        lines = readback_path.read_text(encoding="ascii").splitlines()
        if len(lines) != len(flash_payload) or any(not re.fullmatch(r"[0-9A-Fa-f]{2}", line) for line in lines):
            raise RuntimeError("model bundle readback has unexpected length/encoding")
        readback = bytes(int(line, 16) for line in lines)
        if readback != flash_payload or readback[:len(bundle)] != bundle or crc16(readback[:len(bundle)]) != crc16(bundle):
            raise RuntimeError("model bundle or preserved sector-tail readback differs from expected bytes")
        status = {"status": "PASS", "bytes": len(bundle), "sha256": sha(readback),
                  "bundle_sha256": sha(readback[:len(bundle)]),
                  "bundle_crc16_ccitt_false": f"{crc16(readback[:len(bundle)]):04x}",
                  "flash_range_exclusive": [base, end], "erase_aligned_range_exclusive": [base, erase_end],
                  "preserved_tail_bytes": len(flash_payload) - len(bundle),
                  "preserved_tail_sha256": sha(flash_payload[len(bundle):]), "bit_sha256": bit_sha}
        (LOG_DIR / "result.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(status, indent=2))
        return 0
    finally:
        code, output = programmer.invoke("restore_runtime_bit", ["-m", "jtag", "-u", args.target,
            "--jtag_clock_freq", str(programmer.JTAG_HZ), str(bit_path)])
        if code or programmer.FPGA_ID.lower() not in output.lower():
            raise RuntimeError("failed to restore the recorded runtime bit after Flash operation")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
