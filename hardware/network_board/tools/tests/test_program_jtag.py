import hashlib
import importlib.util
import json
import subprocess
import tempfile
import sys
import unittest
import zlib
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "program_jtag.py"
SPEC = importlib.util.spec_from_file_location("program_jtag", SCRIPT)
program = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = program
SPEC.loader.exec_module(program)


class ProgramJtagPlanTests(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory(prefix="jtag fixture ", dir=program.ROOT / "tmp")
        root = Path(temp.name)
        fw = root / "software" / "gesture_firmware"
        model = fw / "model"
        bundle = fw / "build" / "linux"
        rom = bundle / "rom"
        model.mkdir(parents=True)
        rom.mkdir(parents=True)

        weights = b"w" * 101
        params = b"p" * 53
        (model / "weights.bin").write_bytes(weights)
        (model / "params.bin").write_bytes(params)
        weight_crc, params_crc = zlib.crc32(weights), zlib.crc32(params)
        manifest = {
            "weights_file": "weights.bin", "weights_address": hex(0x02000000),
            "weights_bytes": len(weights), "weights_crc32": hex(weight_crc),
            "params_file": "params.bin", "params_address": hex(0x0210D000),
            "params_bytes": len(params), "params_crc32": hex(params_crc),
            "input_address": hex(0x02129000),
        }
        (model / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        (fw / "include").mkdir()
        (fw / "include" / "model_crc.h").write_text(
            f"#define MODEL_WEIGHTS_BYTES {len(weights)}u\n"
            f"#define MODEL_PARAMS_BYTES {len(params)}u\n"
            f"#define MODEL_WEIGHTS_CRC32 0x{weight_crc:08x}u\n"
            f"#define MODEL_PARAMS_CRC32 0x{params_crc:08x}u\n", encoding="ascii")

        flat = b"fixture firmware image"
        elf = bundle / "gesture_demo.elf"
        flat_bin = bundle / "gesture_demo.bin"
        elf.write_bytes(b"fixture ELF")
        flat_bin.write_bytes(flat)
        lane_hashes = {}
        for lane in range(4):
            data = program._rom_lane_text(flat, lane)
            (rom / f"gesture_demo_ram_symbol{lane}.bin").write_bytes(data)
            name = program._lane_filename(lane)
            (root / name).write_bytes(data)
            lane_hashes[name] = hashlib.sha256(data).hexdigest()

        bit = root / "outflow" / "fixture.bit"
        bit.parent.mkdir()
        bit_bytes = b"fixture bitstream"
        bit.write_bytes(bit_bytes)
        record = {
            "status": "FULL_BUILD_PASS_PGM_PASS; NOT_BOARD_TESTED",
            "bit": "outflow/fixture.bit", "bit_bytes": len(bit_bytes),
            "bit_sha256": hashlib.sha256(bit_bytes).hexdigest(),
            "firmware_elf": elf.relative_to(root).as_posix(),
            "firmware_rom_integration": "build/firmware_rom_integration.json",
            "source_input_hashes": lane_hashes,
        }
        (root / "CURRENT_BUILD.json").write_text(json.dumps(record), encoding="utf-8")
        integration = {
            "firmware_elf": record["firmware_elf"],
            "firmware_elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
            "firmware_bin_sha256": hashlib.sha256(flat).hexdigest(),
            "rom_lane_sha256": lane_hashes,
        }
        (root / "build").mkdir()
        (root / "build" / "firmware_rom_integration.json").write_text(json.dumps(integration), encoding="utf-8")
        (root / "tools").mkdir()
        return temp, root, elf, flat_bin

    def fixture_patches(self, root, elf, flat_bin):
        weight_data = (root / "software" / "gesture_firmware" / "model" / "weights.bin").read_bytes()
        param_data = (root / "software" / "gesture_firmware" / "model" / "params.bin").read_bytes()
        expected_weights = (0x02000000, len(weight_data), zlib.crc32(weight_data))
        expected_params = (0x0210D000, len(param_data), zlib.crc32(param_data))
        ide = root / "ide"
        toolbin = ide / "toolchain" / "bin"
        toolbin.mkdir(parents=True)
        nm = toolbin / "riscv-none-elf-nm.exe"
        objcopy = toolbin / "riscv-none-elf-objcopy.exe"
        nm.touch()
        objcopy.touch()

        def fake_run(command, **kwargs):
            batch_text = Path(command[-1]).read_text(encoding="ascii")
            if "objcopy" in batch_text:
                (root / "tmp" / "program_jtag" / "gesture_demo.verify.bin").write_bytes(flat_bin.read_bytes())
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout="f9003370 B gesture_model_ready\n", stderr="")

        stack = ExitStack()
        stack.enter_context(patch.object(program, "EXPECTED_WEIGHTS", expected_weights))
        stack.enter_context(patch.object(program, "EXPECTED_PARAMS", expected_params))
        stack.enter_context(patch.object(program, "NM_EXE", nm))
        stack.enter_context(patch.object(program, "IDE_ROOT", ide))
        stack.enter_context(patch.object(program.subprocess, "run", side_effect=fake_run))
        return stack

    def plan(self):
        temp, root, elf, flat_bin = self.fixture()
        stack = self.fixture_patches(root, elf, flat_bin)
        self.addCleanup(stack.close)
        self.addCleanup(temp.cleanup)
        return program.build_plan("ftdi://0x0403:0x6011:0:fd/1", "location", "1-4.2", root)

    def test_order_paths_and_no_flash(self):
        steps = self.plan()
        self.assertEqual([step.name for step in steps], [
            "volatile JTAG bit configuration",
            "DDR calibration, model upload, readback CRC, CPU gesture_model_ready confirmation",
        ])
        rendered = "\n".join(subprocess.list2cmdline(step.command) + "\n" + (step.batch_text or "") for step in steps)
        self.assertIn('C:\\Efinity\\2026.1\\bin\\setup.bat', rendered)
        self.assertIn('cd /d "' + str(program.IDE_ROOT), rendered)
        self.assertIn('call setup_standalone.bat <nul', rendered)
        self.assertIn("adapter usb location 1-4.2", rendered)
        self.assertIn("--jtag_clock_freq 3000000", rendered)
        self.assertNotRegex(rendered, r"(?i)\\b(active|passive|jtag_bridge|erase_flash|read_flash)\\b")
        self.assertIn("GESTURE_MODEL_READY_ADDR=0xf9003370", rendered)
        self.assertIn("GESTURE_MODEL_READY_ADDR=0xf9003370", rendered)

    def test_runner_stops_after_first_failure(self):
        steps = self.plan()
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=7)

        with self.assertRaises(subprocess.CalledProcessError):
            program.execute_steps(steps, runner)
        self.assertEqual(len(calls), 1)

    def test_mock_runner_accepts_paths_with_spaces(self):
        temp, root, elf, flat_bin = self.fixture()
        stack = self.fixture_patches(root, elf, flat_bin)
        self.addCleanup(stack.close)
        with temp:
            steps = program.build_plan("ftdi://0x0403:0x6011:0:fd/1", "location", "1-4.2", root)
            calls = []
            program.execute_steps(steps, lambda command, **kwargs: calls.append(command) or SimpleNamespace(returncode=0))
            self.assertEqual(len(calls), 2)
            rendered = "\n".join(subprocess.list2cmdline(step.command) + "\n" + (step.batch_text or "") for step in steps)
            self.assertIn('"' + str(root), rendered)

    def test_bad_bundle_and_bad_target_are_rejected(self):
        temp, root, elf, flat_bin = self.fixture()
        stack = self.fixture_patches(root, elf, flat_bin)
        self.addCleanup(stack.close)
        self.addCleanup(temp.cleanup)
        active_lane = root / program._lane_filename(2)
        active_lane.write_bytes(b"wrong lane")
        with self.assertRaisesRegex(ValueError, "firmware ELF/BIN/ROM bundle"):
            program.build_plan("ftdi://0x0403:0x6011:0:fd/1", "location", "1-4.2", root)
        with self.assertRaises(ValueError):
            program.build_plan("", "location", "1-4.2", root)

    def test_ready_symbol_must_be_a_global_aligned_ocr_data_symbol(self):
        self.assertEqual(program.parse_model_ready_symbol("f9000120 B gesture_model_ready\n"), 0xF9000120)
        for nm_output in (
            "f9000121 B gesture_model_ready\n", "f9004000 B gesture_model_ready\n",
            "f9000120 t gesture_model_ready\n", "",
        ):
            with self.assertRaises(ValueError):
                program.parse_model_ready_symbol(nm_output)

    def test_build_guard_accepts_board_tested_build_and_rejects_stale(self):
        temp, root, _elf, _flat_bin = self.fixture()
        self.addCleanup(temp.cleanup)
        build_path = root / "CURRENT_BUILD.json"
        record = json.loads(build_path.read_text(encoding="utf-8"))
        record["status"] = "FULL_BUILD_PASS_PGM_PASS; BOARD_TESTED"
        build_path.write_text(json.dumps(record), encoding="utf-8")
        self.assertEqual(program._read_build_bit(root)[0]["status"], record["status"])
        record["status"] = "FULL_BUILD_PASS_PGM_PASS; STALE_AFTER_SOURCE_CHANGE"
        build_path.write_text(json.dumps(record), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "current successful full PGM build"):
            program._read_build_bit(root)

    def test_deployment_tcl_requires_cpu_ready_after_ddr_readback(self):
        tcl = (program.ROOT / "tools" / "gesture_load_model.tcl").read_text(encoding="utf-8")
        self.assertIn('echo "DDR readback CRCs PASS; resuming firmware', tcl)
        self.assertIn("GESTURE_MODEL_READY_ADDR", tcl)
        self.assertIn("for {set i 0} {$i < 900}", tcl)
        self.assertIn("halt\n        set ready_words [read_memory", tcl)
        self.assertIn('echo "CPU gesture_model_ready=1; model initialization PASS"', tcl)


if __name__ == "__main__":
    unittest.main()
