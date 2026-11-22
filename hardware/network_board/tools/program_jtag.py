from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


ROOT = Path(__file__).resolve().parents[1]
NM_EXE = Path(r"C:\Efinity\efinity-riscv-ide-2026.1\toolchain\bin\riscv-none-elf-nm.exe")
EFINITY_SETUP = Path(r"C:\Efinity\2026.1\bin\setup.bat")
PGM_BATCH = Path(r"C:\Efinity\2026.1\pgm\bin\ftdi_pgm.bat")
IDE_ROOT = Path(r"C:\Efinity\efinity-riscv-ide-2026.1")
IDE_SETUP = IDE_ROOT / "setup_standalone.bat"
OPENOCD = IDE_ROOT / "openocd" / "bin" / "openocd.exe"
EXPECTED_WEIGHTS = (0x02000000, 1_099_552, 0x992E868B)
EXPECTED_PARAMS = (0x0210D000, 112_384, 0x3FF5E162)
CAPTURE_RANGES = ((0x03000000, 0x03100000), (0x03100000, 0x03200000))
URL_RE = re.compile(r"^ftdi://(?:0x)?0403:(?:0x)?6011:[A-Za-z0-9._:-]+/[1-4]$", re.I)
LOCATION_RE = re.compile(r"^\d+-\d+(?:\.\d+)*$")
SERIAL_RE = re.compile(r"^[A-Za-z0-9._-]+$")


@dataclass(frozen=True)
class Step:
    name: str
    command: tuple[str, ...]
    timeout_seconds: int
    cwd: Path
    batch_path: Path | None = None
    batch_text: str | None = None


def _read_model_contract(project_root: Path = ROOT) -> tuple[dict, Path, Path]:
    fw = project_root / "software" / "gesture_firmware"
    manifest = json.loads((fw / "model" / "manifest.json").read_text(encoding="utf-8"))
    header = (fw / "include" / "model_crc.h").read_text(encoding="ascii")
    expected_header = {
        "MODEL_WEIGHTS_BYTES": EXPECTED_WEIGHTS[1],
        "MODEL_PARAMS_BYTES": EXPECTED_PARAMS[1],
        "MODEL_WEIGHTS_CRC32": EXPECTED_WEIGHTS[2],
        "MODEL_PARAMS_CRC32": EXPECTED_PARAMS[2],
    }
    for name, value in expected_header.items():
        match = re.search(rf"#define\s+{name}\s+(0x[0-9a-f]+|\d+)u", header, re.I)
        if not match or int(match.group(1), 0) != value:
            raise ValueError(f"{name} disagrees with loader contract")

    pairs = (
        ("weights_file", "weights_address", "weights_bytes", "weights_crc32", EXPECTED_WEIGHTS),
        ("params_file", "params_address", "params_bytes", "params_crc32", EXPECTED_PARAMS),
    )
    paths = []
    for filename_key, address_key, bytes_key, crc_key, expected in pairs:
        addr = int(manifest[address_key], 0)
        count = int(manifest[bytes_key])
        crc = int(manifest[crc_key], 0)
        if (addr, count, crc) != expected:
            raise ValueError(f"{filename_key} contract differs from the JTAG loader")
        path = (fw / "model" / manifest[filename_key]).resolve()
        if not path.is_file():
            raise ValueError(f"model file missing: {path}")
        data = path.read_bytes()
        if len(data) != count or zlib.crc32(data) != crc:
            raise ValueError(f"model size/CRC mismatch: {path}")
        paths.append(path)

    ranges = [(EXPECTED_WEIGHTS[0], EXPECTED_WEIGHTS[0] + EXPECTED_WEIGHTS[1]),
              (EXPECTED_PARAMS[0], EXPECTED_PARAMS[0] + EXPECTED_PARAMS[1])]
    for start, end in ranges:
        for cap_start, cap_end in CAPTURE_RANGES:
            if start < cap_end and cap_start < end:
                raise ValueError("model DDR range overlaps a capture buffer")
    if ranges[0][1] > ranges[1][0] or ranges[1][1] > int(manifest["input_address"], 0):
        raise ValueError("model ranges overlap each other or the documented input tensor")
    return manifest, paths[0], paths[1]


def _read_build_manifest(project_root: Path = ROOT) -> dict:
    return json.loads((project_root / "CURRENT_BUILD.json").read_text(encoding="utf-8"))


def _read_build_bit(project_root: Path = ROOT) -> tuple[dict, Path]:
    build = _read_build_manifest(project_root)
    status = str(build.get("status", "")).upper()
    stages = build.get("build_status", {})
    legacy_stages_pass = (stages.get("interface") == "PASS"
                          and stages.get("map") == "PASS"
                          and stages.get("pnr") == "PASS"
                          and stages.get("strict_routed_sta") == "PASS"
                          and stages.get("pgm") == "PASS"
                          and str(stages.get("cdc_payload", "")).endswith("PASS")
                          and str(stages.get("ddr_gray", "")).endswith("PASS"))
    current_candidate_stages_pass = (
        status in ("INTERFACE_MAP_PNR_STA_PGM_PASS_NOT_PROGRAMMED",
                   "INTERFACE_MAP_PNR_STA_PGM_PASS_JTAG_RUNTIME_PASS")
        and stages.get("interface") == "PASS"
        and stages.get("map") == "PASS"
        and stages.get("pnr") == "PASS"
        and stages.get("pgm") == "PASS"
        and stages.get("strict_routed_sta") == "PASS_CURRENT_BUILD"
        and float(build.get("setup_wns_ns", -1)) > 0
        and float(build.get("hold_whs_ns", -1)) > 0
        and stages.get("cdc_payload") == "PASS_538_538_CURRENT_BUILD"
        and stages.get("ddr_gray") == "PASS_36_36_CURRENT_BUILD"
        and stages.get("hdmi_mjpeg_gray") == "PASS_72_72_CURRENT_BUILD"
    )
    stages_pass = legacy_stages_pass or current_candidate_stages_pass
    recognized_status = ("FULL_BUILD_PASS_PGM_PASS" in status
                         or ("FULL_BUILD_STRICT_STA_CDC_PASS_JTAG_RUNTIME_PASS" in status
                             and legacy_stages_pass)
                         or current_candidate_stages_pass)
    if (not recognized_status
            or any(marker in status for marker in ("STALE", "FAIL", "ERROR"))):
        raise ValueError("CURRENT_BUILD.json does not identify a current successful full PGM build")
    bit = (project_root / build["bit"]).resolve()
    if not bit.is_file():
        raise ValueError(f"current bitstream is missing: {bit}")
    data = bit.read_bytes()
    if len(data) != int(build["bit_bytes"]):
        raise ValueError("current bitstream byte count differs from CURRENT_BUILD.json")
    if hashlib.sha256(data).hexdigest() != build["bit_sha256"]:
        raise ValueError("current bitstream SHA-256 differs from CURRENT_BUILD.json")
    return build, bit


def parse_model_ready_symbol(nm_output: str) -> int:
    matches = re.findall(r"(?m)^([0-9a-fA-F]+)\s+([A-Za-z])\s+gesture_model_ready\s*$", nm_output)
    if len(matches) != 1 or matches[0][1] not in "BbDd":
        raise ValueError("firmware ELF must contain exactly one gesture_model_ready data symbol")
    address = int(matches[0][0], 16)
    if address & 3 or not 0xF9000000 <= address <= 0xF9003FFC:
        raise ValueError(f"gesture_model_ready address is outside aligned OCR RAM: 0x{address:08x}")
    return address


def _lane_filename(lane: int) -> str:
    return f"EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin"


def _rom_lane_text(flat_bin: bytes, lane: int) -> bytes:
    if len(flat_bin) > 14 * 1024:
        raise ValueError("firmware flat BIN exceeds the 14 KiB OCR image limit")
    padded = flat_bin.ljust(16 * 1024, b"\0")
    return "".join(f"{byte:08b}\n" for byte in padded[lane::4]).encode("ascii")


def _run_efinity_tool(executable: Path, args: Sequence[str], project_root: Path) -> subprocess.CompletedProcess:
    batch = project_root / "tmp" / "program_jtag" / "run_efinity_tool.bat"
    batch.parent.mkdir(parents=True, exist_ok=True)
    command = subprocess.list2cmdline([str(executable), *args])
    batch.write_text("\r\n".join((
        "@echo off", "setlocal EnableExtensions",
        f'cd /d "{IDE_ROOT}"', "if errorlevel 1 exit /b %errorlevel%",
        'call setup_standalone.bat <nul', 'ver >nul',
        command, "exit /b %errorlevel%", "",
    )), encoding="ascii", newline="")
    try:
        return subprocess.run(["cmd.exe", "/d", "/c", "call", str(batch)], cwd=str(project_root),
                              capture_output=True, text=True, check=False)
    finally:
        batch.unlink(missing_ok=True)


def _verify_elf_matches_bin(elf: Path, flat_bin: Path, project_root: Path) -> None:
    if not NM_EXE.is_file():
        raise ValueError("riscv-none-elf-nm is missing")
    objcopy = IDE_ROOT / "toolchain" / "bin" / "riscv-none-elf-objcopy.exe"
    if not objcopy.is_file():
        raise ValueError("riscv-none-elf-objcopy is missing")
    probe_dir = project_root / "tmp" / "program_jtag"
    probe_dir.mkdir(parents=True, exist_ok=True)
    probe_bin = probe_dir / "gesture_demo.verify.bin"
    try:
        result = _run_efinity_tool(objcopy, ["-O", "binary", str(elf), str(probe_bin)], project_root)
        if result.returncode:
            detail = (result.stderr or result.stdout).strip()
            raise ValueError(f"objcopy failed for firmware ELF (exit {result.returncode}): {detail}")
        if not probe_bin.is_file() or probe_bin.read_bytes() != flat_bin.read_bytes():
            raise ValueError("firmware ELF does not produce the selected flat BIN")
    finally:
        probe_bin.unlink(missing_ok=True)


def _read_model_ready_addr(project_root: Path = ROOT) -> int:
    fw = project_root / "software" / "gesture_firmware"
    build_record, _ = _read_build_bit(project_root)
    source_hashes = build_record.get("source_input_hashes") or {}
    integration_rel = (build_record.get("firmware_rom_integration")
                       or build_record.get("rom_integration")
                       or build_record.get("evidence", {}).get("rom_integration")
                       or "build/firmware_rom_integration.json")
    integration_path = (project_root / integration_rel).resolve()
    try:
        integration = json.loads(integration_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"firmware ROM integration record is missing or invalid: {integration_path}") from exc
    declared_elf = (build_record.get("firmware_elf")
                    or build_record.get("firmware")
                    or integration.get("firmware_elf"))
    if not declared_elf:
        raise ValueError("CURRENT_BUILD.json does not identify the firmware ELF for this bit")
    expected_elf = (project_root / declared_elf).resolve()
    integrated_elf = integration.get("firmware_elf")
    if integrated_elf and (project_root / integrated_elf).resolve() != expected_elf:
        raise ValueError("CURRENT_BUILD.json and firmware ROM integration identify different ELF files")
    matches: list[tuple[Path, Path]] = []
    for bundle_dir in (fw / "build", fw / "build" / "hand_marker", fw / "build" / "linux"):
        elf, flat_bin = bundle_dir / "gesture_demo.elf", bundle_dir / "gesture_demo.bin"
        rom_dir = bundle_dir / "rom" if (bundle_dir / "rom").is_dir() else bundle_dir
        if elf.resolve() != expected_elf or not elf.is_file() or not flat_bin.is_file():
            continue
        if integration.get("firmware_elf_sha256") and hashlib.sha256(elf.read_bytes()).hexdigest() != integration["firmware_elf_sha256"]:
            continue
        integration_bin_sha = integration.get("firmware_bin_sha256") or integration.get("firmware_sha256")
        if integration_bin_sha and hashlib.sha256(flat_bin.read_bytes()).hexdigest() != integration_bin_sha:
            continue
        lane_hashes = integration.get("rom_lane_sha256") or integration.get("new_lane_sha256", {})
        for lane in range(4):
            filename = _lane_filename(lane)
            candidate_lane = rom_dir / f"gesture_demo_ram_symbol{lane}.bin"
            active_lane = project_root / filename
            if not candidate_lane.is_file() or not active_lane.is_file():
                break
            candidate_data = candidate_lane.read_bytes()
            digest = hashlib.sha256(candidate_data).hexdigest()
            if (candidate_data != active_lane.read_bytes()
                    or digest != source_hashes.get(filename, lane_hashes.get(filename))
                    or digest != lane_hashes.get(filename)
                    or candidate_data != _rom_lane_text(flat_bin.read_bytes(), lane)):
                break
        else:
            matches.append((elf, flat_bin))
    if len(matches) != 1:
        raise ValueError("could not identify exactly one firmware ELF/BIN/ROM bundle matching the active four ROM lanes and CURRENT_BUILD hashes")
    elf, flat_bin = matches[0]
    _verify_elf_matches_bin(elf, flat_bin, project_root)
    result = _run_efinity_tool(NM_EXE, ["-a", "--defined-only", "-n", str(elf)], project_root)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise ValueError(f"nm failed for firmware ELF (exit {result.returncode}): {detail}")
    return parse_model_ready_symbol(result.stdout)


def _selector_args(kind: str, value: str) -> tuple[str, str]:
    if kind == "location" and LOCATION_RE.fullmatch(value):
        return ("-c", f"adapter usb location {value}")
    if kind == "serial" and SERIAL_RE.fullmatch(value):
        return ("-c", f"adapter serial {value}")
    raise ValueError(f"invalid explicit OpenOCD {kind} selector: {value!r}")


def build_plan(ftdi_url: str, selector_kind: str, selector: str, project_root: Path = ROOT) -> list[Step]:
    if not URL_RE.fullmatch(ftdi_url):
        raise ValueError("--ftdi-url must explicitly identify FT4232 0403:6011 and interface 1..4")
    _, bit = _read_build_bit(project_root)
    _read_model_contract(project_root)
    model_ready_addr = _read_model_ready_addr(project_root)

    tmp = project_root / "tmp" / "program_jtag"
    efx_home = tmp / "efinity_user"
    efx_ini = tmp / "efinity_user_dir.ini"
    efx_script = "\r\n".join((
        "@echo off", "setlocal EnableExtensions",
        f'call "{EFINITY_SETUP}"', "if errorlevel 1 exit /b %errorlevel%",
        f'if not exist "{efx_home}" mkdir "{efx_home}"', "if errorlevel 1 exit /b %errorlevel%",
        f'set "EFINITY_USER_DIR_INI={efx_ini}"',
        f'set "EFINITY_USER_DIR={efx_home}"',
        f'echo [General]>"{efx_ini}"', "if errorlevel 1 exit /b %errorlevel%",
        f'echo EFINITY_USER_DIR={efx_home}>>"{efx_ini}"', "if errorlevel 1 exit /b %errorlevel%",
        'set "QT_QPA_PLATFORM=offscreen"',
        f'call "{PGM_BATCH}" -m jtag -u "{ftdi_url}" --jtag_clock_freq 3000000 "{bit}"',
        "exit /b %errorlevel%", "",
    ))
    openocd_selector = _selector_args(selector_kind, selector)
    load_tcl = (project_root / "tools" / "gesture_load_model.tcl").as_posix()
    openocd_script = "\r\n".join((
        "@echo off", "setlocal EnableExtensions",
        f'cd /d "{IDE_ROOT}"', "if errorlevel 1 exit /b %errorlevel%",
        'call setup_standalone.bat <nul', 'ver >nul',
        'set "GESTURE_DDR_LOAD=YES"',
        f'set "GESTURE_DDR_LOAD_TARGET={selector_kind}:{selector}"',
        f'set "GESTURE_MODEL_READY_ADDR=0x{model_ready_addr:08x}"',
        f'cd /d "{project_root / "tools"}"', "if errorlevel 1 exit /b %errorlevel%",
        f'"{OPENOCD}" -f "{project_root / "tools" / "gesture_ftdi.cfg"}" '
        f'{openocd_selector[0]} "{openocd_selector[1]}" '
        f'-f "{project_root / "tools" / "gesture_debug_target.cfg"}" '
        f'-c init -c "source {{{load_tcl}}}"',
        "exit /b %errorlevel%", "",
    ))
    return [
        Step("volatile JTAG bit configuration", ("cmd.exe", "/d", "/c", "call program_bit_step.bat"), 180, tmp, tmp / "program_bit_step.bat", efx_script),
        Step("DDR calibration, model upload, readback CRC, CPU gesture_model_ready confirmation", ("cmd.exe", "/d", "/c", "call program_model_step.bat"), 360, tmp, tmp / "program_model_step.bat", openocd_script),
    ]


def _run_with_tree_timeout(command: Sequence[str], **kwargs: object) -> object:
    timeout = int(kwargs.pop("timeout"))
    kwargs.pop("check", None)
    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    process = subprocess.Popen(command, creationflags=creationflags, **kwargs)
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], capture_output=True, check=False)
        else:
            process.kill()
        process.wait()
        raise
    return subprocess.CompletedProcess(command, code)


def execute_steps(steps: Sequence[Step], runner: Callable[..., object] = _run_with_tree_timeout) -> None:
    for index, step in enumerate(steps, 1):
        print(f"[{index}/{len(steps)}] {step.name}", flush=True)
        result = runner(step.command, cwd=str(step.cwd), check=False, timeout=step.timeout_seconds)
        code = getattr(result, "returncode", 0)
        if code:
            raise subprocess.CalledProcessError(code, step.command)


def execute_real(steps: Sequence[Step]) -> None:
    if len(steps) != 2:
        raise ValueError("unexpected programming plan shape")
    for step in steps[:2]:
        if step.batch_path is None or step.batch_text is None:
            raise ValueError("batch stage is missing its project-local script")
        step.batch_path.write_text(step.batch_text, encoding="ascii", newline="")
    execute_steps(steps)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load the second-board bit and gesture model in one volatile JTAG operation.")
    parser.add_argument("--ftdi-url", help="explicit Efinity FT4232 URI, e.g. ftdi://0x0403:0x6011:0:fd/1")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--location", help="explicit OpenOCD USB bus-port location, e.g. 1-4.2")
    group.add_argument("--serial", help="explicit OpenOCD FTDI serial")
    parser.add_argument("--plan", action="store_true", help="validate inputs and print steps without touching hardware")
    args = parser.parse_args(argv)
    if not args.plan and (not args.ftdi_url or not (args.location or args.serial)):
        parser.error("execution requires --ftdi-url and exactly one of --location/--serial")
    if args.plan and any((args.location, args.serial)) and not (args.ftdi_url and (args.location or args.serial)):
        parser.error("a populated plan must include --ftdi-url and one selector")
    return args


def main(argv: Sequence[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    if not args.ftdi_url:
        print("Provide --ftdi-url and --location (or --serial) to produce a concrete plan.")
        return 0 if args.plan else 2
    kind, selector = ("location", args.location) if args.location else ("serial", args.serial or "")
    try:
        steps = build_plan(args.ftdi_url, kind, selector)
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if args.plan:
        print(f"Project: {ROOT}")
        print(f"Mode: volatile JTAG; no Flash command is present")
        for index, step in enumerate(steps, 1):
            print(f"{index}. {step.name}: {subprocess.list2cmdline(step.command)}")
            if step.batch_text:
                for line in step.batch_text.splitlines():
                    print(f"   {line}")
        return 0
    try:
        execute_real(steps)
    except subprocess.CalledProcessError as exc:
        print(f"ERROR: step failed ({exc.returncode}); later steps were not run: {exc.cmd[0]}", file=sys.stderr)
        return exc.returncode or 1
    except (subprocess.TimeoutExpired, TimeoutError) as exc:
        print(f"ERROR: hard timeout: {exc}", file=sys.stderr)
        return 124
    print("PASS: bit configured, DDR model readback CRCs passed, CPU set gesture_model_ready=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

