"""Program and independently read back the active configuration image via HiFTDI.

The checked range is the configuration region at address zero. The model bundle
at 0x400000 is preserved. The bundled HiFTDI SDK requires a process-local
configure adapter for its empty GPIO-init structure; no vendor files are changed.
"""
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import hashlib
import json
import re
import runpy
import sys
import traceback

ROOT = Path(__file__).resolve().parents[1]
RECORD = ROOT / "CURRENT_PROJECT.json"
ASSET_MANIFEST = ROOT / "assets/catalog_manifest.json"
MODEL_BUNDLE = ROOT / "assets/model_bundle_29x16k_lut12.bin"
BIT = ROOT / "outflow/ti60f225_oob.bit"
HEX = ROOT / "outflow/ti60f225_oob.hex"
BRIDGE = Path(r"C:\Efinity\2026.1\pgm\fli\titanium\u10660A79.bit")
URL = "hiftdi://0x0403:0x6011/0"
FPGA_ID = "0x10660A79"
JEDEC = bytes((0xEF, 0x60, 0x17))
MODEL_BASE = 0x400000
ERASE_SIZE = 4096
JTAG_HZ = 3_000_000
EXPECTED_OLD_CONFIG_SHA256 = "b8adbb23332e599660dbf7b93e4b1fc315f5b4f2864b999347806f85e0b9a926"
EVIDENCE = ROOT / "support/flash_persistent_vflip_20261025"
LOGS = EVIDENCE / "logs_program_20261025"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def model_bundle_info():
    manifest = json.loads(ASSET_MANIFEST.read_text(encoding="utf-8"))
    bundle = MODEL_BUNDLE.read_bytes()
    if len(bundle) != manifest.get("bundle_bytes"):
        raise RuntimeError("complete model/LUT boot image length differs from catalog manifest")
    if sha(bundle) != manifest.get("bundle_sha256"):
        raise RuntimeError("complete model/LUT boot image SHA256 differs from catalog manifest")
    if manifest.get("bundle_crc16_ccitt_false") != f"{crc16_ccitt_false(bundle):04x}":
        raise RuntimeError("complete model/LUT boot image CRC16 differs from catalog manifest")
    return manifest, bundle


def crc16_ccitt_false(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xFFFF
    return crc


def payload_from(path):
    lines = path.read_text(encoding="ascii").splitlines()
    if not lines or any(not re.fullmatch(r"[0-9A-Fa-f]{2}", line) for line in lines):
        raise RuntimeError(f"unexpected HEX encoding in {path}")
    return bytes(int(line, 16) for line in lines)


def plan():
    global BIT, HEX
    record = json.loads(RECORD.read_text(encoding="utf-8"))
    if "TIMING_FAILED" in str(record.get("latest_status", "")).upper():
        raise RuntimeError("refusing to program a TIMING_FAILED configuration candidate")
    bit_path = (ROOT / record["latest_bit"]).resolve()
    bit_path.relative_to(ROOT.resolve())
    BIT = bit_path
    HEX = bit_path.with_suffix(".hex")
    bit = BIT.read_bytes()
    raw_hex = HEX.read_bytes()
    payload = payload_from(HEX)
    if sha(bit) != record["bit_sha256"]:
        raise RuntimeError("BIT SHA256 differs from CURRENT_PROJECT.json")
    if sha(raw_hex) != record["hex_sha256"]:
        raise RuntimeError("HEX SHA256 differs from CURRENT_PROJECT.json")
    if not record.get("bit_matches_source"):
        raise RuntimeError("active BIT is not recorded as source-matched")
    end = (len(payload) + ERASE_SIZE - 1) // ERASE_SIZE * ERASE_SIZE
    if end > MODEL_BASE:
        raise RuntimeError(f"configuration erase range overlaps model region: 0x{end:X}")
    return record, payload, end


def print_plan():
    record, payload, end = plan()
    asset_manifest, model = model_bundle_info()
    print(json.dumps({
        "dry_run": True,
        "bit": str(BIT.relative_to(ROOT)),
        "bit_sha256": record["bit_sha256"],
        "hex": str(HEX.relative_to(ROOT)),
        "hex_sha256": record["hex_sha256"],
        "payload_bytes": len(payload),
        "flash_address": 0,
        "erase_range_exclusive": [0, end],
        "model_region_base": MODEL_BASE,
        "model_bundle": str(MODEL_BUNDLE.relative_to(ROOT)),
        "model_bundle_bytes": len(model),
        "model_bundle_sha256": sha(model),
        "model_bundle_crc16_ccitt_false": asset_manifest["bundle_crc16_ccitt_false"],
        "model_bundle_flash_range_exclusive": [
            int(asset_manifest["bundle_layout"]["flash_base"], 16),
            int(asset_manifest["bundle_layout"]["flash_end_exclusive"], 16),
        ],
        "target": URL,
        "expected_fpga_id": FPGA_ID,
        "expected_jedec": JEDEC.hex(),
        "page_wait": "maximum from first erase/write",
        "independent_readback": True,
    }, indent=2))


def install_hiftdi_adapter():
    sys.path.insert(0, r"C:\Efinity\2026.1\debugger\bin")
    sys.path.insert(0, r"C:\Efinity\2026.1\pgm\bin")
    from efx_pgm.hiftdi.jtag import JtagEngine
    original_configure = JtagEngine.configure

    def configure_compat(self, url, init=None):
        if init and (init.val or init.dir):
            raise RuntimeError("unexpected nonempty HiFTDI board-profile GPIO init")
        return original_configure(self, url)

    JtagEngine.configure = configure_compat
    # Efinity routes the JTAG-to-SPI flash bridge through JTAGFINEGRAIN even
    # though its bridge commands only need TAP state changes and DR shifts.
    # HiFTDI exposes those primitives, so adapt the fine-grain convenience
    # methods in this process instead of touching the installed SDK.
    from efx_pgm.hiftdi.bits import BitSequence
    from efx_pgm.hiftdi.bits import BitZSequence
    from efx_pgm.efx_hw_common import manager

    class HiFtdiFineGrainCompat(JtagEngine):
        pipe_len = 512 * 8

        @staticmethod
        def _compat_bits(value):
            if isinstance(value, (bytes, bytearray)):
                return BitSequence(bytes_=value)
            bits = list(value)
            if any(bit in (None, 0xFF) for bit in bits):
                return BitZSequence(["Z" if bit in (None, 0xFF) else bool(bit) for bit in bits])
            return BitSequence([bool(bit) for bit in bits])

        def write(self, out, use_last=False):
            return self.controller.write(self._compat_bits(out), use_last=use_last)

        def write_ir(self, instruction):
            self.change_state("shift_ir")
            self.controller.write(self._compat_bits(instruction))
            self.change_state("update_ir")

        def write_dr(self, data):
            self.change_state("shift_dr")
            self.controller.write(self._compat_bits(data))
            self.change_state("update_dr")

        def change_state(self, statename):
            path = self.state_machine.find_path(statename)
            events = self.state_machine.get_events(path)
            if len(events) == 0:
                events.append("0")
            self.controller.write_tms(events)
            self.state_machine.handle_events(events)

        def change_state2(self, statename, sync=False):
            self.change_state(statename)

        def go_idle2(self, cycle=1, sync=False):
            for _ in range(cycle):
                if self.state_machine.state_of("idle"):
                    self.controller.write_tms(BitSequence(False))
                    self.state_machine.handle_events(BitSequence(False))
                else:
                    self.change_state("run_test_idle")

        def write_dr_bytes(self, hdr, tdr, data, sync=False):
            self.change_state("shift_dr")
            if len(hdr) > 0:
                self.controller.write(BitSequence(bytes_=data), False)
                self.controller.write(hdr, True)
            else:
                self.controller.write(BitSequence(bytes_=data), True)
            self.change_state("update_dr")

        def read_dr2(self, length):
            self.change_state("shift_dr")
            result = self.controller.read(length)
            self.change_state("update_dr")
            return result

    original_get_controller = manager.EfxFTDIHwConnectionManager.get_controller

    def get_controller_compat(url, conn_type, **kwargs):
        if (conn_type == manager.EfxFTDIHwConnectionManager.ConnectionType.JTAGFINEGRAIN
                and url.startswith("hiftdi://")
                and __import__("os").environ.get("EFX_HIFTDI_ENABLE") == "1"):
            return HiFtdiFineGrainCompat(**kwargs)
        return original_get_controller(url, conn_type, **kwargs)

    manager.EfxFTDIHwConnectionManager.get_controller = staticmethod(get_controller_compat)
    from efx_pgm.jtag2SpiFlash import SerialFlashDetector
    original_get = SerialFlashDetector.get_flash_device

    def guarded_get(driver):
        flash = original_get(driver)
        jedec = bytes(getattr(flash, "_jedec", b""))
        erase_size = int(flash.get_erase_size())
        if jedec != JEDEC or erase_size != ERASE_SIZE:
            raise RuntimeError(f"unexpected Flash: JEDEC={jedec.hex()}, erase={erase_size}")
        flash.change_wait_time(False)
        if getattr(flash._wait_for_completion, "__name__", "") != "_wait_for_completion_slow":
            raise RuntimeError("maximum page wait was not enabled")
        return flash

    SerialFlashDetector.get_flash_device = staticmethod(guarded_get)


def invoke(name, args):
    buffer = StringIO()
    sys.argv = [r"C:\Efinity\2026.1\pgm\bin\efx_pgm\ftdi_program.py", *map(str, args)]
    code = 0
    try:
        with redirect_stdout(buffer), redirect_stderr(buffer):
            runpy.run_module("efx_pgm.ftdi_program", run_name="__main__")
    except SystemExit as exc:
        code = int(exc.code or 0)
    except Exception:
        code = 1
        traceback.print_exc(file=buffer)
    output = buffer.getvalue()
    (LOGS / f"{name}.log").write_text(output, encoding="utf-8")
    print(output, end="")
    return code, output


def run(read_only=False):
    record, payload, erase_end = plan()
    asset_manifest, model = model_bundle_info()
    LOGS.mkdir(parents=True, exist_ok=False)
    install_hiftdi_adapter()
    status = {
        "bit_sha256": record["bit_sha256"],
        "hex_sha256": record["hex_sha256"],
        "payload_bytes": len(payload),
        "erase_range_exclusive": [0, erase_end],
        "model_region_base": MODEL_BASE,
        "model_bundle_bytes": len(model),
        "model_bundle_sha256": sha(model),
        "model_bundle_crc16_ccitt_false": asset_manifest["bundle_crc16_ccitt_false"],
        "model_bundle_flash_range_exclusive": [
            int(asset_manifest["bundle_layout"]["flash_base"], 16),
            int(asset_manifest["bundle_layout"]["flash_end_exclusive"], 16),
        ],
        "target": URL,
        "fpga_id": FPGA_ID,
        "jedec_id": JEDEC.hex(),
        "page_wait": "maximum",
        "flash_write": "NOT_STARTED",
    }
    try:
        code, output = invoke("bridge_before", ["-m", "jtag", "-u", URL,
                              "--jtag_clock_freq", str(JTAG_HZ), str(BRIDGE)])
        if code or FPGA_ID.lower() not in output.lower():
            raise RuntimeError(f"bridge load/FPGA ID check failed ({code})")

        old_bytes = 1_098_873  # Previous seed7 image length, recorded readback evidence.
        code, output = invoke("read_before", ["-m", "jtag_bridge", "-u", URL,
                              "--jtag_clock_freq", str(JTAG_HZ), "--jtag_bridge_mode", "read",
                              "--address", "0", "--num_bytes", str(old_bytes), "-o",
                              EVIDENCE / "flash_before.hex", HEX])
        if code or "Finished read" not in output:
            raise RuntimeError(f"pre-write Flash read failed ({code})")
        old_payload = payload_from(EVIDENCE / "flash_before.hex")
        if len(old_payload) != old_bytes:
            raise RuntimeError(f"unexpected pre-write read length {len(old_payload)}")
        status["pre_write_flash_readback"] = {
            "bytes": len(old_payload), "sha256": sha(old_payload),
            "hex_sha256": sha((EVIDENCE / "flash_before.hex").read_bytes()),
        }
        if sha(old_payload) != EXPECTED_OLD_CONFIG_SHA256:
            raise RuntimeError("current Flash config differs from the previously verified seed7 image")

        if read_only:
            status["flash_write"] = "NOT_STARTED_READ_ONLY_CHECK"
            status["pre_write_status"] = "PASS"
        else:
            code, output = invoke("program", ["-m", "jtag_bridge", "-u", URL,
                           "--jtag_clock_freq", str(JTAG_HZ), "--jtag_bridge_mode", "all",
                           "--verify_method", "none", "--address", "0", HEX])
            if code or "JTAG2SPI programming...done" not in output:
                raise RuntimeError(f"Flash programming did not complete ({code})")
            status["flash_write"] = "PASS"

        if not read_only:
            code, output = invoke("bridge_for_readback", ["-m", "jtag", "-u", URL,
                              "--jtag_clock_freq", str(JTAG_HZ), str(BRIDGE)])
            if code or FPGA_ID.lower() not in output.lower():
                raise RuntimeError(f"readback bridge load failed ({code})")
            code, output = invoke("readback", ["-m", "jtag_bridge", "-u", URL,
                              "--jtag_clock_freq", str(JTAG_HZ), "--jtag_bridge_mode", "read",
                              "--address", "0", "--num_bytes", str(len(payload)), "-o",
                              EVIDENCE / "flash_readback.hex", HEX])
            if code or "Finished read" not in output:
                raise RuntimeError(f"independent Flash readback failed ({code})")
            actual = payload_from(EVIDENCE / "flash_readback.hex")
            readback_ok = actual == payload
            status["readback"] = {
                "bytes": len(actual), "expected_bytes": len(payload),
                "sha256": sha(actual), "expected_sha256": sha(payload),
                "exact_match": readback_ok,
                "hex_sha256": sha((EVIDENCE / "flash_readback.hex").read_bytes()),
            }
            if not readback_ok:
                raise RuntimeError("independent Flash readback differs from the active HEX payload")
            status["readback_status"] = "PASS"
    finally:
        code, output = invoke("restore_runtime_bit", ["-m", "jtag", "-u", URL,
                                 "--jtag_clock_freq", str(JTAG_HZ), str(BIT)])
        status["runtime_restore"] = {
            "exit_code": code,
            "device_id_seen": FPGA_ID.lower() in output.lower(),
            "bit_sha256": sha(BIT.read_bytes()),
        }
        if code == 0 and FPGA_ID.lower() in output.lower():
            status["runtime_restore"]["status"] = "PASS"
        else:
            status["runtime_restore"]["status"] = "FAIL"
    status["cold_boot_test"] = "PENDING_USER_POWER_CYCLE"
    (EVIDENCE / "record.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(status, indent=2))
    return 0 if status.get("readback_status") == "PASS" and status["runtime_restore"]["status"] == "PASS" else 1


if __name__ == "__main__":
    try:
        if "--dry-run" in sys.argv[1:]:
            print_plan()
        elif "--read-only" in sys.argv[1:]:
            raise SystemExit(run(read_only=True))
        elif "--program" in sys.argv[1:]:
            raise SystemExit(run())
        else:
            raise SystemExit("specify --dry-run or --program")
    except Exception as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
