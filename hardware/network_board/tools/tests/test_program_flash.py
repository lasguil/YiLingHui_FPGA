from __future__ import annotations

import hashlib
import json
import shutil
import sys
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import program_flash as flash


class PersistentFlashTests(unittest.TestCase):
    def setUp(self) -> None:
        ready = patch.object(flash.jtag_validation, "_read_model_ready_addr", return_value=0xf9002000)
        nm = patch.object(flash.jtag_validation, "_run_efinity_tool",
                          return_value=SimpleNamespace(returncode=0, stdout="f9001000 T gesture_flash_try_load\n", stderr=""))
        ready.start()
        nm.start()
        self.addCleanup(ready.stop)
        self.addCleanup(nm.stop)

    @classmethod
    def setUpClass(cls) -> None:
        cls.real_root = flash.ROOT

    def fixture_project(self) -> tuple[tempfile.TemporaryDirectory, Path, bytes, bytes]:
        tmp_root = self.real_root / "tmp"
        tmp_root.mkdir(exist_ok=True)
        holder = tempfile.TemporaryDirectory(prefix="board 2 flash project ", dir=tmp_root)
        root = Path(holder.name) / "project with spaces"
        fw = root / "software" / "gesture_firmware"
        (fw / "model").mkdir(parents=True)
        (fw / "include").mkdir()
        shutil.copy2(self.real_root / "software/gesture_firmware/model/weights_hw.bin", fw / "model/weights_hw.bin")
        shutil.copy2(self.real_root / "software/gesture_firmware/model/param_hw.bin", fw / "model/param_hw.bin")
        shutil.copy2(self.real_root / "software/gesture_firmware/model/manifest.json", fw / "model/manifest.json")
        shutil.copy2(self.real_root / "software/gesture_firmware/include/model_crc.h", fw / "include/model_crc.h")
        reader = root / "rtl/flash_model_apb.sv"
        reader.parent.mkdir(parents=True)
        reader.write_text("module flash_model_apb; endmodule\n", encoding="ascii")
        loader = root / "software/gesture_firmware/src/gesture_flash_loader.c"
        loader.parent.mkdir(parents=True)
        loader.write_text("int gesture_flash_try_load(void) { return 0; }\n", encoding="ascii")
        (root / "ti60f225_oob.xml").write_text(
            '<project><file>rtl/flash_model_apb.sv</file><file>software/gesture_firmware/src/gesture_flash_loader.c</file></project>',
            encoding="utf-8")
        bit = root / "outflow/ti60f225_oob.bit"
        bit.parent.mkdir()
        bit_data = b"unit-test-persistent-bit"
        bit.write_bytes(bit_data)
        elf = fw / "build" / "gesture_demo.elf"
        elf.parent.mkdir()
        elf_data = b"mock ELF"
        elf.write_bytes(elf_data)
        flat_bin = b"mock firmware flat image"
        bin_path = elf.with_suffix(".bin")
        bin_path.write_bytes(flat_bin)
        lane_hashes = {}
        for lane in range(4):
            lane_data = flash.jtag_validation._rom_lane_text(flat_bin, lane)
            candidate_lane = elf.parent / f"gesture_demo_ram_symbol{lane}.bin"
            candidate_lane.write_bytes(lane_data)
            lane_name = flash.jtag_validation._lane_filename(lane)
            (root / lane_name).write_bytes(lane_data)
            lane_hashes[lane_name] = hashlib.sha256(lane_data).hexdigest()
        integration = {
            "firmware_elf": "software/gesture_firmware/build/gesture_demo.elf",
            "firmware_bin": "software/gesture_firmware/build/gesture_demo.bin",
            "firmware_bin_sha256": hashlib.sha256(flat_bin).hexdigest(),
            "loader_symbol": "gesture_flash_try_load", "loader_address": "0xf9001000",
            "rom_lane_sha256": lane_hashes,
        }
        (root / "build").mkdir()
        (root / "build/firmware_rom_integration.json").write_text(json.dumps(integration), encoding="utf-8")
        config = bytes((i * 17 + 5) & 0xFF for i in range(16384))
        pgm = root / "outflow/ti60f225_oob.hex"
        pgm.write_bytes(flash.to_byte_lines(config))
        record = {
            "status": "FULL_BUILD_PASS_PGM_PASS; BOARD_TESTED",
            "project": "ti60f225_oob.xml", "bit": "outflow/ti60f225_oob.bit",
            "bit_sha256": hashlib.sha256(bit_data).hexdigest(), "bit_bytes": len(bit_data),
            "bit_header_mode": "active", "pgm_hex": "outflow/ti60f225_oob.hex",
            "pgm_hex_mode": "active", "pgm_hex_sha256": hashlib.sha256(config).hexdigest(),
            "pgm_hex_bytes": len(config), "firmware_elf": "software/gesture_firmware/build/gesture_demo.elf",
            "firmware_elf_sha256": hashlib.sha256(elf_data).hexdigest(),
            "firmware_bin": "software/gesture_firmware/build/gesture_demo.bin",
            "firmware_bin_sha256": hashlib.sha256(flat_bin).hexdigest(),
            "firmware_rom_integration": "build/firmware_rom_integration.json",
            "firmware_rom_lane_sha256": lane_hashes,
            "firmware_loader_symbol": "gesture_flash_try_load",
            "persistent_model_boot": {
                "version": 1, "layout": "GMD1_LE32_HEADER_V1",
                "boot_reader_source": "rtl/flash_model_apb.sv",
                "loader_source": "software/gesture_firmware/src/gesture_flash_loader.c",
                "loader_symbol": "gesture_flash_try_load",
            },
            "source_input_hashes": {
                "ti60f225_oob.xml": hashlib.sha256((root / "ti60f225_oob.xml").read_bytes()).hexdigest(),
                "rtl/flash_model_apb.sv": hashlib.sha256(reader.read_bytes()).hexdigest(),
                "software/gesture_firmware/src/gesture_flash_loader.c": hashlib.sha256(loader.read_bytes()).hexdigest(),
                **lane_hashes,
            },
        }
        (root / "CURRENT_BUILD.json").write_text(json.dumps(record), encoding="utf-8")
        return holder, root, config, bit_data

    def test_header_and_image_offsets_match_contract(self) -> None:
        manifest, weights, params = flash.load_model(self.real_root)
        image = flash.make_model_image(weights, params)
        header = flash.MODEL_HEADER.unpack_from(image)
        self.assertEqual(header, (flash.HEADER_MAGIC, 1, 1_099_552, 112_384,
                                  0x992E868B, 0x3FF5E162))
        self.assertEqual(image[:4], b"GMD1")
        self.assertEqual(image[flash.WEIGHTS_FLASH - flash.MODEL_BASE:
                               flash.WEIGHTS_FLASH - flash.MODEL_BASE + len(weights)], weights)
        self.assertEqual(image[flash.PARAMS_FLASH - flash.MODEL_BASE:], params)
        self.assertEqual(flash.MODEL_BASE + len(image), 0x529700)
        self.assertEqual(int(manifest["input_address"], 0), 0x02129000)

    def test_tool_failure_cannot_bypass_loader_verification(self) -> None:
        holder, root, _, _ = self.fixture_project()
        self.addCleanup(holder.cleanup)
        with patch.object(flash.jtag_validation, "_run_efinity_tool",
                          return_value=SimpleNamespace(returncode=1, stdout="", stderr="Access denied")):
            with self.assertRaisesRegex(ValueError, "could not inspect firmware"):
                flash.validate_persistent_build(root)

    def test_actual_loader_symbol_must_match_record(self) -> None:
        holder, root, _, _ = self.fixture_project()
        self.addCleanup(holder.cleanup)
        with patch.object(flash.jtag_validation, "_run_efinity_tool",
                          return_value=SimpleNamespace(returncode=0, stdout="f9001004 T gesture_flash_try_load\n", stderr="")):
            with self.assertRaisesRegex(ValueError, "actual ELF loader symbol"):
                flash.validate_persistent_build(root)

    def test_plan_preserves_paths_with_spaces_and_checks_build_identity(self) -> None:
        holder, root, config, bit_data = self.fixture_project()
        self.addCleanup(holder.cleanup)
        steps, summary = flash.make_plan("ftdi://0x0403:0x6011:0:fd/1", root)
        self.assertEqual(len(steps), 5)
        self.assertIn("project with spaces", summary["output_dir"])
        self.assertTrue(any("project with spaces" in arg for step in steps for arg in step.args))
        self.assertTrue(all(any("program_flash_max_wait.bat" in arg for arg in step.args)
                            for step in steps if step.name.startswith("program ")))
        self.assertFalse(any(any("program_flash_max_wait.bat" in arg for arg in step.args)
                             for step in steps if step.name.startswith("read ") or step.name.startswith("backup ")))
        self.assertEqual(summary["config_bytes"], len(config))
        self.assertEqual(summary["bit_sha256"], hashlib.sha256(bit_data).hexdigest())
        self.assertRegex(summary["output_dir"], r"flash_persistent_\d{8}\\run_\d{6}_\d{6}$")
        record = json.loads((root / "CURRENT_BUILD.json").read_text(encoding="utf-8"))
        record.pop("persistent_model_boot")
        (root / "CURRENT_BUILD.json").write_text(json.dumps(record), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "old bitstreams are refused"):
            flash.validate_persistent_build(root)

    def test_sector_log_and_full_flash_preservation_ranges(self) -> None:
        amount = 1_100_000
        erase = flash.round_up(amount, 4096)
        log = f"Flash device: Winbond W25Q64 8 MiB (JEDEC ID: 0xEF6017)\nErasing {erase // 1024} KiB from flash @ 0x00400000"
        self.assertEqual(flash.parse_flash_identity(log), ("Winbond W25Q64", "EF6017"))
        self.assertEqual(flash.parse_erase_size(log, flash.MODEL_BASE, amount), erase)
        with self.assertRaisesRegex(ValueError, "expected 4KiB or 64KiB"):
            flash.parse_erase_size("Erasing 2048 KiB from flash @ 0x00400000", flash.MODEL_BASE, amount)
        image = bytes([0xA5]) * 128
        original = bytes(flash.FLASH_BYTES)
        after = bytearray(original)
        after[:len(image)] = image
        after[flash.MODEL_BASE:flash.MODEL_BASE + len(image)] = image
        flash.verify_flash_images(original, bytes(after), image, image, 65536, 65536)
        flash.verify_flash_images(original, bytes(after), image, image, 4096, 4096)
        with self.assertRaisesRegex(ValueError, "erase extent is invalid"):
            flash.verify_flash_images(original, bytes(after), image, image, 131072, 4096)
        after[0x700000] = 0x11
        with self.assertRaisesRegex(ValueError, "outside erase ranges"):
            flash.verify_flash_images(original, bytes(after), image, image, 65536, 65536)

    def test_mock_step_order_and_failure_stops_later_steps(self) -> None:
        tmp_root = self.real_root / "tmp"
        tmp_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="flash mock path ", dir=tmp_root) as tmp:
            root = Path(tmp) / "project with spaces"
            root.mkdir()
            steps = [flash.Step(f"step-{idx}", (f"arg-{idx}",), 180, root / f"{idx}.log")
                     for idx in range(3)]
            calls: list[list[str]] = []

            def runner(command, **_kwargs):
                calls.append(command)
                return SimpleNamespace(returncode=9 if len(calls) == 2 else 0)

            with self.assertRaises(Exception):
                flash._execute(steps, root, runner)
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][-1], calls[1][-1])
            batch = (root / "tmp/flash_persistent/run_step.bat").read_text(encoding="ascii")
            self.assertIn('call "C:\\Efinity\\2026.1\\bin\\setup.bat"', batch)
            self.assertIn("set \"QT_QPA_PLATFORM=offscreen\"", batch)


if __name__ == "__main__":
    unittest.main()
