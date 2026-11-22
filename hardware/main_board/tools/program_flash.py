"""Safely program this project's approved FPGA configuration Flash image.

This A-board entry point uses the vendor's maximum page wait from the first
write. The physical target and Flash part are fixed to this project's TI60
board. It erases only the 4 KiB-aligned configuration image at address 0 and
refuses any range reaching the model at 0x400000. Default vendor verification
is none for the fast-write workflow; use the separate readback procedure when
verification is required. A successful JTAG restore is not a cold-boot test.
"""
import hashlib
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'CURRENT_PROJECT.json'
FTDI_PGM = Path(r'C:\Efinity\2026.1\pgm\bin\ftdi_pgm.bat')
PYTHON_ENTRY = Path(r'C:\Efinity\2026.1\pgm\bin\efx_pgm\ftdi_program.py')
BRIDGE_BIT = Path(r'C:\Efinity\2026.1\pgm\fli\titanium\u10660A79.bit')
USB_URL = 'ftdi://0x0403:0x6011:0:fd/1'
FPGA_ID = '0x10660A79'
FLASH_JEDEC = bytes((0xEF, 0x60, 0x17))
MODEL_BASE = 0x400000
ERASE_UNIT = 4096
JTAG_HZ = 3_000_000
LOG_DIR = ROOT / 'tmp' / 'program_flash'


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def resolve_image():
    manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
    if 'TIMING_FAILED' in str(manifest.get('latest_status', '')).upper():
        raise RuntimeError('refusing to program a TIMING_FAILED configuration candidate')
    bit_path = (ROOT / manifest['latest_bit']).resolve()
    bit_path.relative_to(ROOT.resolve())
    hex_path = bit_path.with_suffix('.hex')
    bit = bit_path.read_bytes()
    raw_hex = hex_path.read_bytes()
    bit_hash = sha256(bit)
    hex_hash = sha256(raw_hex)
    if bit_hash.lower() != manifest['bit_sha256'].lower():
        raise RuntimeError('active BIT hash does not match CURRENT_PROJECT.json')
    if hex_hash.lower() != manifest['hex_sha256'].lower():
        raise RuntimeError('active HEX hash does not match CURRENT_PROJECT.json')
    payload = bytes(int(line[:2], 16) for line in raw_hex.decode('ascii').splitlines())
    erase_end = ((len(payload) + ERASE_UNIT - 1) // ERASE_UNIT) * ERASE_UNIT
    if not payload or erase_end > MODEL_BASE:
        raise RuntimeError(f'configuration Flash range reaches model area: end=0x{erase_end:X}')
    return manifest, bit_path, hex_path, bit_hash, hex_hash, payload, erase_end


def print_plan():
    manifest, bit_path, hex_path, bit_hash, hex_hash, payload, erase_end = resolve_image()
    print(json.dumps({
        'dry_run': True,
        'bit': str(bit_path.relative_to(ROOT)), 'bit_sha256': bit_hash,
        'hex': str(hex_path.relative_to(ROOT)), 'hex_sha256': hex_hash,
        'payload_bytes': len(payload), 'flash_address': 0,
        'erase_range': [0, erase_end], 'model_base': MODEL_BASE,
        'target': USB_URL, 'expected_fpga_id': FPGA_ID,
        'expected_flash_jedec': FLASH_JEDEC.hex(), 'page_wait': 'maximum from first write',
        'vendor_verify_method': 'none', 'cold_boot_test': 'not performed by this tool'
    }, indent=2))


def run_vendor_cli(args, log_path):
    command = subprocess.list2cmdline([str(FTDI_PGM), *map(str, args)])
    result = subprocess.run(command, cwd=ROOT, shell=True, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=180)
    log_path.write_text(result.stdout, encoding='utf-8')
    print(result.stdout, end='')
    return result.returncode, result.stdout


def instrument_vendor_write(payload, erase_end):
    sys.path.insert(0, r'C:\Efinity\2026.1\debugger\bin')
    sys.path.insert(0, r'C:\Efinity\2026.1\pgm\bin')
    from efx_pgm.jtag2SpiFlash import SerialFlashDetector

    original_get = SerialFlashDetector.get_flash_device
    status_log = LOG_DIR / 'status_registers.jsonl'

    def emit(event, **fields):
        with status_log.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'event': event, **fields}, sort_keys=True) + '\n')

    def guarded_get(driver):
        flash = original_get(driver)
        jedec = bytes(getattr(flash, '_jedec', b''))
        erase_size = int(flash.get_erase_size())
        if jedec != FLASH_JEDEC or erase_size != ERASE_UNIT:
            raise RuntimeError(f'unexpected board Flash: JEDEC={jedec.hex()}, erase={erase_size}')
        if ((len(payload) + erase_size - 1) // erase_size) * erase_size != erase_end or erase_end > MODEL_BASE:
            raise RuntimeError('Flash erase range guard failed')
        flash.change_wait_time(False)
        if getattr(flash._wait_for_completion, '__name__', '') != '_wait_for_completion_slow':
            raise RuntimeError('maximum page wait did not activate')
        try:
            status_before = flash._read_status(sync=False)
        except Exception as exc:
            status_before = None
            emit('status_before_error', error=repr(exc))
        emit('flash_detected', jedec=jedec.hex(), erase_size=erase_size,
             erase_range=[0, erase_end], payload_bytes=len(payload),
             page_wait=flash._wait_for_completion.__name__, status_before=status_before)
        original_status_write = flash._write_status

        def traced_status_write(*args, **kwargs):
            emit('status_write_begin', args=[repr(v) for v in args],
                 kwargs={k: repr(v) for k, v in kwargs.items()})
            result = original_status_write(*args, **kwargs)
            try:
                status_after = flash._read_status(sync=False)
                emit('status_write_complete', status_after=status_after)
            except Exception as exc:
                emit('status_after_error', error=repr(exc))
                raise
            return result

        flash._write_status = traced_status_write
        return flash

    SerialFlashDetector.get_flash_device = staticmethod(guarded_get)
    return SerialFlashDetector


def program():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    for stale in (LOG_DIR / 'status_registers.jsonl', LOG_DIR / 'enumerate.log',
                  LOG_DIR / 'bridge_load.log', LOG_DIR / 'program.log', LOG_DIR / 'jtag_restore.log'):
        stale.unlink(missing_ok=True)
    manifest, bit_path, hex_path, bit_hash, hex_hash, payload, erase_end = resolve_image()

    rc, enumeration = run_vendor_cli(['-l'], LOG_DIR / 'enumerate.log')
    if rc:
        raise RuntimeError(f'FTDI enumeration failed with exit {rc}')
    if len(re.findall(r'^Usb Target:', enumeration, re.M)) != 1 or USB_URL not in enumeration:
        raise RuntimeError('expected exactly one FT4232 board with the approved fd/1 interface')

    rc, bridge_log = run_vendor_cli(['-m', 'jtag', '-u', USB_URL,
                                     '--jtag_clock_freq', str(JTAG_HZ), str(BRIDGE_BIT)],
                                    LOG_DIR / 'bridge_load.log')
    if rc or FPGA_ID.lower() not in bridge_log.lower():
        raise RuntimeError(f'JTAG bridge load/FPGA ID check failed (exit {rc})')

    instrument_vendor_write(payload, erase_end)
    sys.argv = [str(PYTHON_ENTRY), '-m', 'jtag_bridge', '-u', USB_URL,
                '--jtag_clock_freq', str(JTAG_HZ), '--jtag_bridge_mode', 'all',
                '--verify_method', 'none', '--address', '0', str(hex_path)]
    try:
        runpy.run_path(str(PYTHON_ENTRY), run_name='__main__')
        program_rc = 0
    except SystemExit as exc:
        program_rc = int(exc.code or 0)
    except Exception as exc:
        print(f'Flash programmer raised: {exc!r}')
        program_rc = 1

    restore_rc, _ = run_vendor_cli(['-m', 'jtag', '-u', USB_URL,
                                    '--jtag_clock_freq', str(JTAG_HZ), str(bit_path)],
                                   LOG_DIR / 'jtag_restore.log')
    status = {
        'bit_sha256': bit_hash, 'hex_sha256': hex_hash, 'payload_bytes': len(payload),
        'erase_range': [0, erase_end], 'model_base': MODEL_BASE,
        'vendor_verify_method': 'none; no verification claim',
        'max_page_wait': 'enabled before first erase/write',
        'flash_program_exit': program_rc, 'jtag_restore_exit': restore_rc,
        'cold_boot_test': 'pending user power cycle'
    }
    (LOG_DIR / 'result.json').write_text(json.dumps(status, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(status, indent=2))
    if program_rc or restore_rc:
        return 1
    return 0


if __name__ == '__main__':
    try:
        if '--dry-run' in sys.argv[1:]:
            print_plan()
            raise SystemExit(0)
        raise SystemExit(program())
    except Exception as exc:
        print(f'ERROR: {exc}')
        raise SystemExit(1)
