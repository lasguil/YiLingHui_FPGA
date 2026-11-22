"""Package the B-board model in Flash and run the guarded persistent JTAG flow.

All image validation and safety planning is local.  Hardware steps run only with
the explicit --program flag and an explicit FTDI URL.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
import zlib
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Sequence


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import program_jtag as jtag_validation  # noqa: E402
FLASH_BYTES = 8 * 1024 * 1024
CONFIG_BASE = 0
MODEL_BASE = 0x00400000
HEADER_MAGIC = 0x31444D47  # bytes "GMD1" in little endian
HEADER_VERSION = 1
HEADER_BYTES = 24
MODEL_HEADER = struct.Struct("<6I")
WEIGHTS_BYTES = 1_099_552
PARAMS_BYTES = 112_384
WEIGHTS_CRC32 = 0x992E868B
PARAMS_CRC32 = 0x3FF5E162
WEIGHTS_FLASH = 0x00401000
PARAMS_FLASH = 0x0050E000
MODEL_END = 0x00529700
DDR_WEIGHTS = 0x02000000
DDR_PARAMS = 0x0210D000
DDR_INPUT = 0x02129000
ERASE_UNITS = (4096, 65536)
BRIDGE_BIT = Path(r"C:\Efinity\2026.1\pgm\fli\titanium\u10660A79.bit")
EFINITY_SETUP = Path(r"C:\Efinity\2026.1\bin\setup.bat")
PGM_BATCH = Path(r"C:\Efinity\2026.1\pgm\bin\ftdi_pgm.bat")
PGM_MAXWAIT_BATCH = ROOT / "tools" / "program_flash_max_wait.bat"
FTDI_RE = re.compile(
    r"^(?:ftdi://(?:0x)?0403:(?:0x)?6011:[A-Za-z0-9._:-]+/[1-4]"
    r"|hiftdi://(?:0x)?0403:(?:0x)?6011/[0-3])$", re.I)
HEX_BYTE_RE = re.compile(r"^[0-9a-fA-F]{2}$")
ERASE_RE = re.compile(r"Erasing\s+(\d+)\s+KiB\s+from flash\s+@\s+0x([0-9a-fA-F]+)", re.I)
FLASH_ID_RE = re.compile(r"Flash device:\s+(.+?)\s+(\d+)\s+MiB\s+\(JEDEC ID:\s*0x([0-9a-fA-F]+)\)", re.I)


@dataclass(frozen=True)
class Step:
    name: str
    args: tuple[str, ...]
    timeout_seconds: int
    log_path: Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def round_up(value: int, unit: int) -> int:
    return (value + unit - 1) // unit * unit


def parse_byte_lines(path: Path) -> bytes:
    """Read the vendor bridge's one-byte-per-line hexadecimal format."""
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"cannot read byte-per-line HEX {path}: {exc}") from exc
    if not lines or any(not HEX_BYTE_RE.fullmatch(line.strip()) for line in lines):
        raise ValueError(f"invalid byte-per-line HEX: {path}")
    return bytes(int(line.strip(), 16) for line in lines)


def to_byte_lines(data: bytes) -> bytes:
    return "".join(f"{byte:02x}\n" for byte in data).encode("ascii")


def load_model(project_root: Path = ROOT) -> tuple[dict, bytes, bytes]:
    fw = project_root / "software" / "gesture_firmware"
    model_dir = fw / "model"
    manifest = json.loads((model_dir / "manifest.json").read_text(encoding="utf-8"))
    header_text = (fw / "include" / "model_crc.h").read_text(encoding="ascii")
    expected = {
        "weights_file": ("weights_hw.bin", WEIGHTS_BYTES, WEIGHTS_CRC32, "MODEL_WEIGHTS_BYTES", "MODEL_WEIGHTS_CRC32"),
        "params_file": ("param_hw.bin", PARAMS_BYTES, PARAMS_CRC32, "MODEL_PARAMS_BYTES", "MODEL_PARAMS_CRC32"),
    }
    result: list[bytes] = []
    for key, (filename, size, crc, size_macro, crc_macro) in expected.items():
        if manifest.get(key) != filename:
            raise ValueError(f"model manifest {key} changed from the Flash loader contract")
        data = (model_dir / filename).read_bytes()
        declared_size = int(manifest["weights_bytes" if key == "weights_file" else "params_bytes"])
        declared_crc = int(manifest["weights_crc32" if key == "weights_file" else "params_crc32"], 0)
        size_match = re.search(rf"#define\s+{size_macro}\s+(\d+)u", header_text)
        crc_match = re.search(rf"#define\s+{crc_macro}\s+(0x[0-9a-fA-F]+)u", header_text)
        if (len(data), zlib.crc32(data), declared_size, declared_crc) != (size, crc, size, crc):
            raise ValueError(f"model size/CRC or manifest contract mismatch: {filename}")
        if not size_match or int(size_match.group(1)) != size or not crc_match or int(crc_match.group(1), 16) != crc:
            raise ValueError(f"{size_macro}/{crc_macro} disagrees with model manifest and Flash contract")
        result.append(data)

    fixed_manifest = {
        "weights_address": DDR_WEIGHTS,
        "params_address": DDR_PARAMS,
        "input_address": DDR_INPUT,
    }
    for key, value in fixed_manifest.items():
        if int(manifest[key], 0) != value:
            raise ValueError(f"model manifest {key} changed from the DDR loader contract")
    if MODEL_BASE + HEADER_BYTES > WEIGHTS_FLASH or WEIGHTS_FLASH + len(result[0]) > PARAMS_FLASH:
        raise ValueError("model Flash ranges overlap or contradict the fixed layout")
    if PARAMS_FLASH + len(result[1]) != MODEL_END:
        raise ValueError("parameter Flash end differs from the fixed image boundary")
    if DDR_WEIGHTS + len(result[0]) > DDR_PARAMS or DDR_PARAMS + len(result[1]) > DDR_INPUT:
        raise ValueError("DDR model ranges overlap or reach the input tensor")
    return manifest, result[0], result[1]


def make_model_image(weights: bytes, params: bytes) -> bytes:
    if len(weights) != WEIGHTS_BYTES or zlib.crc32(weights) != WEIGHTS_CRC32:
        raise ValueError("weights do not match the Flash header contract")
    if len(params) != PARAMS_BYTES or zlib.crc32(params) != PARAMS_CRC32:
        raise ValueError("parameters do not match the Flash header contract")
    header = MODEL_HEADER.pack(HEADER_MAGIC, HEADER_VERSION, len(weights), len(params),
                               zlib.crc32(weights), zlib.crc32(params))
    image = header.ljust(WEIGHTS_FLASH - MODEL_BASE, b"\xff") + weights
    image += b"\xff" * (PARAMS_FLASH - (MODEL_BASE + len(image)))
    image += params
    if MODEL_BASE + len(image) != MODEL_END:
        raise ValueError("constructed model image has an unexpected length")
    return image


def validate_persistent_build(project_root: Path = ROOT) -> tuple[dict, Path, Path, bytes]:
    record = json.loads((project_root / "CURRENT_BUILD.json").read_text(encoding="utf-8"))
    status = str(record.get("status", "")).upper()
    build_status = record.get("build_status", {})
    stages_pass = (build_status.get("interface") == "PASS"
                   and build_status.get("map") == "PASS"
                   and build_status.get("pnr") == "PASS"
                   and build_status.get("strict_routed_sta") == "PASS"
                   and build_status.get("pgm") == "PASS"
                   and str(build_status.get("cdc_payload", "")).endswith("PASS")
                   and str(build_status.get("ddr_gray", "")).endswith("PASS"))
    recognized_status = ("FULL_BUILD_PASS_PGM_PASS" in status
                         or ("FULL_BUILD_STRICT_STA_CDC_PASS_JTAG_RUNTIME_PASS" in status
                             and stages_pass))
    if (not recognized_status
            or any(marker in status for marker in ("STALE", "FAIL", "ERROR"))):
        raise ValueError("CURRENT_BUILD.json is not a current successful full PGM build")
    persistent = record.get("persistent_model_boot")
    if not isinstance(persistent, dict):
        raise ValueError("CURRENT_BUILD.json lacks the signed-off persistent_model_boot metadata; old bitstreams are refused")
    required = {
        "version": HEADER_VERSION,
        "layout": "GMD1_LE32_HEADER_V1",
        "boot_reader_source": "rtl/flash_model_apb.sv",
        "loader_source": "software/gesture_firmware/src/gesture_flash_loader.c",
        "loader_symbol": "gesture_flash_try_load",
    }
    for key, value in required.items():
        if persistent.get(key) != value:
            raise ValueError(f"persistent_model_boot.{key} must be {value!r}")
    source_hashes = record.get("source_input_hashes", {})
    xml_rel = record.get("project", "ti60f225_oob.xml")
    xml_path = project_root / xml_rel
    xml_text = xml_path.read_text(encoding="utf-8")
    xml_hash = source_hashes.get(Path(xml_rel).as_posix())
    if not xml_hash or sha256(xml_path.read_bytes()) != xml_hash:
        raise ValueError("project XML is missing from source_input_hashes or differs from CURRENT_BUILD")
    for source in (required["boot_reader_source"], required["loader_source"]):
        source_path = project_root / source
        expected_hash = source_hashes.get(source)
        if not expected_hash or not source_path.is_file() or sha256(source_path.read_bytes()) != expected_hash:
            raise ValueError(f"persistent boot source is missing or differs from CURRENT_BUILD: {source}")
    if required["boot_reader_source"] not in xml_text:
        raise ValueError("Flash reader RTL is not referenced by the current project XML")

    bit = project_root / record["bit"]
    bit_data = bit.read_bytes()
    if len(bit_data) != int(record["bit_bytes"]) or sha256(bit_data) != record["bit_sha256"]:
        raise ValueError("current bitstream size/SHA-256 differs from CURRENT_BUILD.json")
    pgm_rel = record.get("pgm_hex")
    if not pgm_rel or record.get("pgm_hex_mode") != "active":
        raise ValueError("CURRENT_BUILD.json must identify the active configuration PGM HEX")
    config_hex = project_root / pgm_rel
    if config_hex.stem != bit.stem:
        raise ValueError("bitstream and PGM HEX do not share the same artifact stem/build identity")
    config = parse_byte_lines(config_hex)
    if len(config) != int(record.get("pgm_hex_bytes", -1)) or sha256(config) != record.get("pgm_hex_sha256"):
        raise ValueError("active configuration HEX size/SHA-256 differs from CURRENT_BUILD.json")
    if not config or round_up(len(config), max(ERASE_UNITS)) >= MODEL_BASE:
        raise ValueError("configuration HEX's conservative 64KiB erase range reaches the model slot")
    model_manifest, weights, params = load_model(project_root)
    _ = model_manifest
    _validate_firmware_bundle(record, project_root, required["loader_symbol"])
    return record, bit, config_hex, make_model_image(weights, params)


def _validate_firmware_bundle(record: dict, project_root: Path, loader_symbol: str) -> int:
    """Check the recorded bundle, then verify the actual ELF with nm/objcopy."""
    integration_rel = record.get("firmware_rom_integration", "build/firmware_rom_integration.json")
    integration_path = project_root / integration_rel
    integration = json.loads(integration_path.read_text(encoding="utf-8"))
    elf_rel = record.get("firmware_elf")
    bin_rel = record.get("firmware_bin")
    if not elf_rel or not bin_rel or (project_root / elf_rel).resolve() != (project_root / integration.get("firmware_elf", "")).resolve():
        raise ValueError("CURRENT_BUILD and firmware ROM integration identify different ELF files")
    if (project_root / bin_rel).resolve() != (project_root / integration.get("firmware_bin", "")).resolve():
        raise ValueError("CURRENT_BUILD and firmware ROM integration identify different flat BIN files")
    elf = (project_root / elf_rel).read_bytes()
    flat_bin = (project_root / bin_rel).read_bytes()
    elf_hash, bin_hash = sha256(elf), sha256(flat_bin)
    if elf_hash != record.get("firmware_elf_sha256"):
        raise ValueError("firmware ELF hash differs from CURRENT_BUILD.json")
    if bin_hash != record.get("firmware_bin_sha256") or bin_hash != integration.get("firmware_bin_sha256"):
        raise ValueError("firmware flat BIN hash differs from the build integration record")
    if (record.get("firmware_loader_symbol") != loader_symbol
            or integration.get("loader_symbol") != loader_symbol):
        raise ValueError(f"firmware integration does not export the expected {loader_symbol} symbol")
    loader_address = int(integration.get("loader_address", "0"), 0)
    if not 0xF9000000 <= loader_address <= 0xF9003FFF:
        raise ValueError("firmware loader symbol address is outside OCR RAM")

    source_hashes = record.get("source_input_hashes", {})
    record_lane_hashes = record.get("firmware_rom_lane_sha256", {})
    integration_lane_hashes = integration.get("rom_lane_sha256", {})
    fw_root = project_root / "software" / "gesture_firmware"
    candidates: list[tuple[Path, Path]] = []
    for bundle_dir, lane_dir in ((fw_root / "build", fw_root / "build"),
                                 (fw_root / "build" / "linux", fw_root / "build" / "linux" / "rom")):
        if (bundle_dir / "gesture_demo.elf").resolve() == (project_root / elf_rel).resolve():
            candidates.append((bundle_dir, lane_dir))
    if len(candidates) != 1:
        raise ValueError("could not identify exactly one firmware build bundle matching CURRENT_BUILD")
    _bundle_dir, lane_dir = candidates[0]
    for lane in range(4):
        filename = jtag_validation._lane_filename(lane)
        active = project_root / filename
        candidate = lane_dir / filename.replace("EfxSapphireSoc.v_toplevel_system_ramA_logic_", "gesture_demo_")
        if not candidate.is_file() or not active.is_file():
            raise ValueError(f"firmware ROM lane is missing: {filename}")
        data = candidate.read_bytes()
        digest = sha256(data)
        if (data != active.read_bytes() or digest != source_hashes.get(filename)
                or digest != record_lane_hashes.get(filename)
                or digest != integration_lane_hashes.get(filename)
                or data != jtag_validation._rom_lane_text(flat_bin, lane)):
            raise ValueError(f"firmware ELF/BIN/ROM lane bundle does not match {filename}")
    # Run these tools outside the sandbox if the local toolchain is blocked;
    # never weaken the artifact checks to work around an execution denial.
    jtag_validation._read_model_ready_addr(project_root)
    nm = jtag_validation._run_efinity_tool(
        jtag_validation.NM_EXE, ["-g", "--defined-only", "-n", str(project_root / elf_rel)], project_root)
    if nm.returncode:
        raise ValueError(f"could not inspect firmware loader symbol: {(nm.stderr or nm.stdout).strip()}")
    matches = re.findall(rf"(?m)^([0-9a-fA-F]+)\s+T\s+{re.escape(loader_symbol)}\s*$", nm.stdout)
    if len(matches) != 1 or int(matches[0], 16) != loader_address:
        raise ValueError("actual ELF loader symbol disagrees with the integration record")
    return loader_address


def make_plan(ftdi_url: str, project_root: Path = ROOT,
              output_dir: Path | None = None) -> tuple[list[Step], dict]:
    if not FTDI_RE.fullmatch(ftdi_url):
        raise ValueError("--ftdi-url must explicitly identify FTDI 0403:6011 interface 1..4")
    record, bit, config_hex, model_image = validate_persistent_build(project_root)
    now = datetime.now()
    date = now.strftime("%Y%m%d")
    run_id = now.strftime("%H%M%S_%f")
    output_dir = output_dir or project_root / "support" / f"flash_persistent_{date}" / f"run_{run_id}"
    work_dir = project_root / "tmp" / "flash_persistent" / date / f"run_{run_id}"
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "model_image.hex").write_bytes(to_byte_lines(model_image))
    before_hex = work_dir / "flash_before.hex"
    after_hex = work_dir / "flash_after.hex"

    def pgm(*args: str) -> tuple[str, ...]:
        return ("call", str(PGM_BATCH), "-m", "jtag_bridge", "-u", ftdi_url,
                "--jtag_clock_freq", "3000000", *args)

    def pgm_maxwait(*args: str) -> tuple[str, ...]:
        # All writes enter through the project shim, which guards the allowed
        # Flash regions and selects the vendor maximum page wait before the
        # first erase/program operation. Read-only bridge calls stay native.
        shim = PGM_MAXWAIT_BATCH
        return ("call", str(shim), "-m", "jtag_bridge", "-u", ftdi_url,
                "--jtag_clock_freq", "3000000", *args)

    steps = [
        Step("load Ti60 bridge for device ID 0x10660A79",
             ("call", str(PGM_BATCH), "-m", "jtag", "-u", ftdi_url,
              "--jtag_clock_freq", "3000000", str(BRIDGE_BIT)), 180, output_dir / "bridge.log"),
        Step("backup complete 8MiB Flash and confirm JEDEC capacity",
             pgm("--jtag_bridge_mode", "read", "--address", "0x0", "--num_bytes", str(FLASH_BYTES),
                 "-o", str(before_hex), str(config_hex)), 180, output_dir / "backup.log"),
        Step("program active FPGA configuration at Flash address 0",
             pgm_maxwait("--jtag_bridge_mode", "all", "--verify_method", "hostx1", "--address", "0x0",
                 str(config_hex)), 180, output_dir / "program_config.log"),
        Step("program GMD1 model image at Flash address 0x400000",
             pgm_maxwait("--jtag_bridge_mode", "all", "--verify_method", "hostx1", "--address", "0x400000",
                 str(work_dir / "model_image.hex")), 180, output_dir / "program_model.log"),
        Step("read complete Flash for byte-level comparison",
             pgm("--jtag_bridge_mode", "read", "--address", "0x0", "--num_bytes", str(FLASH_BYTES),
                 "-o", str(after_hex), str(config_hex)), 180, output_dir / "readback.log"),
    ]
    summary = {
        "date": date, "output_dir": str(output_dir), "work_dir": str(work_dir),
        "bit_sha256": record["bit_sha256"], "config_hex_sha256": record["pgm_hex_sha256"],
        "config_bytes": len(parse_byte_lines(config_hex)), "config_erase_max_end": f"0x{round_up(len(parse_byte_lines(config_hex)), 65536):x}",
        "model_base": f"0x{MODEL_BASE:x}", "model_bytes": len(model_image),
        "model_sha256": sha256(model_image),
        "model_end": f"0x{MODEL_END:x}", "model_erase_max_end": f"0x{MODEL_BASE + round_up(len(model_image), 65536):x}",
        "flash_bytes": FLASH_BYTES,
    }
    return steps, summary


def _batch_text(step: Step, project_root: Path) -> str:
    local_tmp = project_root / "tmp" / "flash_persistent"
    user_dir = local_tmp / "efinity_user"
    ini_path = local_tmp / "efinity_user_dir.ini"
    command = subprocess.list2cmdline(step.args)
    log = str(step.log_path)
    return "\r\n".join((
        "@echo off", "setlocal EnableExtensions", f'cd /d "{project_root}"',
        "if errorlevel 1 exit /b %errorlevel%", f'call "{EFINITY_SETUP}"',
        "if errorlevel 1 exit /b %errorlevel%", f'if not exist "{user_dir}" mkdir "{user_dir}"',
        "if errorlevel 1 exit /b %errorlevel%", f'set "EFINITY_USER_DIR_INI={ini_path}"',
        f'set "EFINITY_USER_DIR={user_dir}"', f'echo [General]>"{ini_path}"',
        f'echo EFINITY_USER_DIR={user_dir}>>"{ini_path}"', 'set "QT_QPA_PLATFORM=offscreen"',
        f'{command} > "{log}" 2>&1', "exit /b %errorlevel%", ""))


def parse_flash_identity(log_text: str) -> tuple[str, str]:
    matches = FLASH_ID_RE.findall(log_text)
    if not matches:
        raise ValueError("programmer log did not identify the physical Flash JEDEC ID and capacity")
    identities = {(name.strip(), int(size), value.upper()) for name, size, value in matches}
    if len(identities) != 1:
        raise ValueError("programmer logs report inconsistent Flash identities")
    name, size, jedec = next(iter(identities))
    if size != 8:
        raise ValueError(f"physical Flash reports {size} MiB; expected 8 MiB")
    return name, jedec


def parse_erase_size(log_text: str, address: int, image_bytes: int) -> int:
    matches = [(int(kib) * 1024, int(addr, 16)) for kib, addr in ERASE_RE.findall(log_text)]
    if not matches:
        raise ValueError("programming log has no erase record; refusing to assume the erase boundary")
    sizes = {size for size, _ in matches}
    if len(sizes) != 1 or any(start != address for _, start in matches):
        raise ValueError("programming log contains an unexpected erase address or inconsistent retries")
    size = sizes.pop()
    allowed = {round_up(image_bytes, unit) for unit in ERASE_UNITS}
    if size not in allowed or size < image_bytes or size > round_up(image_bytes, 65536):
        raise ValueError(f"programmer erased {size} bytes at 0x{address:x}; expected 4KiB or 64KiB sector rounding")
    return size


def verify_flash_images(before: bytes, after: bytes, config: bytes, model: bytes,
                        config_erase: int, model_erase: int) -> None:
    if len(before) != FLASH_BYTES or len(after) != FLASH_BYTES:
        raise ValueError("Flash before/after images must each contain exactly 8MiB")
    if config_erase not in {round_up(len(config), unit) for unit in ERASE_UNITS}:
        raise ValueError("configuration erase extent is invalid")
    if (MODEL_BASE + model_erase > FLASH_BYTES
            or model_erase not in {round_up(len(model), unit) for unit in ERASE_UNITS}):
        raise ValueError("model erase extent is invalid")
    if after[CONFIG_BASE:CONFIG_BASE + len(config)] != config:
        raise ValueError("configuration Flash readback does not match active PGM HEX")
    if after[MODEL_BASE:MODEL_BASE + len(model)] != model:
        raise ValueError("model Flash readback does not match GMD1 image")
    permitted = bytearray(FLASH_BYTES)
    permitted[CONFIG_BASE:CONFIG_BASE + config_erase] = b"\x01" * config_erase
    permitted[MODEL_BASE:MODEL_BASE + model_erase] = b"\x01" * model_erase
    for idx, (old, new, allowed) in enumerate(zip(before, after, permitted)):
        if old != new and not allowed:
            raise ValueError(f"Flash changed outside erase ranges at 0x{idx:06x}")


def _read_log(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ValueError(f"missing step log {path}: {exc}") from exc


def _record_validation_failure(record: dict, record_path: Path, phase: str, exc: Exception) -> None:
    record["status"] = f"FAILED_VALIDATION: {phase}"
    record["error"] = str(exc)
    record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


def _execute(steps: Sequence[Step], project_root: Path,
             runner: Callable[..., object], record: dict | None = None,
             record_path: Path | None = None) -> None:
    script = project_root / "tmp" / "flash_persistent" / "run_step.bat"
    script.parent.mkdir(parents=True, exist_ok=True)
    for index, step in enumerate(steps, 1):
        step.log_path.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(_batch_text(step, project_root), encoding="ascii", newline="")
        print(f"[{index}/{len(steps)}] {step.name}", flush=True)
        if record is not None and record_path is not None:
            record["status"] = f"RUNNING: {step.name}"
            record["current_step_log"] = str(step.log_path)
            record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        try:
            result = runner(["cmd.exe", "/d", "/c", "call", str(script)],
                            cwd=str(project_root), check=False, timeout=step.timeout_seconds)
        except subprocess.TimeoutExpired as exc:
            if record is not None and record_path is not None:
                record["status"] = f"FAILED_TIMEOUT: {step.name}"
                record["error"] = str(exc)
                record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
            raise
        code = getattr(result, "returncode", 0)
        if code:
            if record is not None and record_path is not None:
                record["status"] = f"FAILED_EXIT_{code}: {step.name}"
                record["exit_code"] = code
                record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
            raise subprocess.CalledProcessError(code, step.args)
        if record is not None and record_path is not None:
            record.setdefault("completed_steps", []).append(step.name)
            record["status"] = f"STEP_PASS: {step.name}"
            record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


def run_program(ftdi_url: str, project_root: Path = ROOT,
                runner: Callable[..., object] | None = None) -> dict:
    runner = runner or jtag_validation._run_with_tree_timeout
    steps, summary = make_plan(ftdi_url, project_root)
    output_dir = Path(summary["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=False)
    before_bin_path = output_dir / "flash_before.bin"
    record_path = output_dir / "record.json"
    record = {
        **summary, "status": "RUNNING", "flash_bytes": FLASH_BYTES,
        "steps": [{"name": step.name, "args": list(step.args), "timeout_seconds": step.timeout_seconds,
                   "log": str(step.log_path)} for step in steps],
    }
    record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

    # The first two steps are performed as a pair. The backup and JEDEC checks
    # must pass before either programming step is allowed to run.
    _execute(steps[:2], project_root, runner, record, record_path)
    try:
        backup_hex = Path(summary["work_dir"]) / "flash_before.hex"
        before = parse_byte_lines(backup_hex)
        if len(before) != FLASH_BYTES:
            raise ValueError(f"full Flash backup has {len(before)} bytes; expected {FLASH_BYTES}")
        before_bin_path.write_bytes(before)
        record.update({"backup_bytes": len(before), "backup_sha256": sha256(before),
                       "status": "BACKUP_CAPTURED; CHECKING_JEDEC"})
        record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        backup_log = _read_log(steps[1].log_path)
        part_name, jedec = parse_flash_identity(backup_log)
        build = json.loads((project_root / "CURRENT_BUILD.json").read_text(encoding="utf-8"))
        config = parse_byte_lines(project_root / build["pgm_hex"])
        (output_dir / "config_image.bin").write_bytes(config)
        model = (Path(summary["work_dir"]) / "model_image.hex").read_bytes()
        model_bytes = bytes(int(line, 16) for line in model.decode("ascii").splitlines())
        (output_dir / "model_image.bin").write_bytes(model_bytes)
    except Exception as exc:
        _record_validation_failure(record, record_path, "full Flash backup / JEDEC check", exc)
        raise
    record.update({"backup_bytes": len(before), "backup_sha256": sha256(before),
                   "flash_part": part_name, "jedec_id": jedec,
                   "status": "BACKUP_VERIFIED; READY_TO_PROGRAM"})
    record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

    _execute(steps[2:3], project_root, runner, record, record_path)
    try:
        config_erase = parse_erase_size(_read_log(steps[2].log_path), CONFIG_BASE, len(config))
        if config_erase > MODEL_BASE:
            raise ValueError("configuration erase range reaches model header")
    except Exception as exc:
        _record_validation_failure(record, record_path, "configuration erase range log inspection", exc)
        raise

    _execute(steps[3:4], project_root, runner, record, record_path)
    try:
        model_erase = parse_erase_size(_read_log(steps[3].log_path), MODEL_BASE, len(model_bytes))
        if MODEL_BASE + model_erase > FLASH_BYTES:
            raise ValueError("model erase range exceeds the physical Flash capacity")
    except Exception as exc:
        _record_validation_failure(record, record_path, "model erase range log inspection", exc)
        raise
    _execute(steps[4:], project_root, runner, record, record_path)
    try:
        after = parse_byte_lines(Path(summary["work_dir"]) / "flash_after.hex")
        verify_flash_images(before, after, config, model_bytes, config_erase, model_erase)
    except Exception as exc:
        _record_validation_failure(record, record_path, "complete Flash readback", exc)
        raise
    (output_dir / "flash_after.bin").write_bytes(after)
    final = {
        **record, "status": "FLASH_PROGRAM_READBACK_PASS; POWER_CYCLE_USER_CONFIRMATION_PENDING",
        "config_bytes": len(config), "config_sha256": sha256(config),
        "config_readback_match": True, "config_erase_end_exclusive": f"0x{config_erase:x}",
        "model_base": MODEL_BASE, "model_bytes": len(model_bytes),
        "model_sha256": sha256(model_bytes), "model_readback_match": True,
        "model_erase_end_exclusive": f"0x{MODEL_BASE + model_erase:x}",
        "flash_after_sha256": sha256(after), "outside_erased_sectors_unchanged": True,
        "power_cycle_test": {"status": "PENDING_USER_CONFIRMATION"},
    }
    record_path.write_text(json.dumps(final, indent=2) + "\n", encoding="utf-8")
    return final


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Safely persist B-board configuration and GMD1 model in Flash.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true", help="validate local artifacts and print steps; never accesses hardware")
    group.add_argument("--program", action="store_true", help="run the persistent Flash sequence; requires an explicit FTDI URL")
    parser.add_argument("--ftdi-url", help="explicit Efinity FT4232 URL, e.g. ftdi://0x0403:0x6011:0:fd/1")
    args = parser.parse_args(argv)
    if args.program and not args.ftdi_url:
        parser.error("--program requires --ftdi-url; board selection is never guessed")
    if args.plan and args.ftdi_url and not FTDI_RE.fullmatch(args.ftdi_url):
        parser.error("invalid --ftdi-url")
    return args


def main(argv: Sequence[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    try:
        # Plan also validates the model and build, and prints the precise path
        # and command templates without importing or invoking USB libraries.
        url = args.ftdi_url or "ftdi://0x0403:0x6011:0:fd/1"
        steps, summary = make_plan(url)
        if args.plan:
            print(f"Build bit SHA256: {summary['bit_sha256']}")
            print(f"Config: {summary['config_bytes']} bytes; conservative erase end {summary['config_erase_max_end']}")
            print(f"Model: {summary['model_bytes']} bytes at {summary['model_base']}; conservative erase end {summary['model_erase_max_end']}")
            for index, step in enumerate(steps, 1):
                print(f"{index}. {step.name}")
                print("   " + subprocess.list2cmdline(step.args))
                print(f"   log: {step.log_path}")
            print("PLAN ONLY: no USB or hardware access was performed.")
            return 0
        result = run_program(args.ftdi_url)
    except subprocess.CalledProcessError as exc:
        print(f"ERROR: step failed ({exc.returncode}); later steps were not run", file=sys.stderr)
        return exc.returncode or 1
    except subprocess.TimeoutExpired as exc:
        print(f"ERROR: step exceeded its {exc.timeout}s timeout; later steps were not run", file=sys.stderr)
        return 124
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(f"PASS: persistent Flash readback verified; JEDEC {result['jedec_id']} ({result['flash_part']})")
    print("Power-cycle boot and model-ready behavior still require user board confirmation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
