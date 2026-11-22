"""Efinity-runtime shim that enables maximum Flash page waits before writes.
Use this in place of ftdi_pgm.bat for board-B jtag_bridge write commands.
It accepts the vendor CLI arguments and restricts writes to the configuration
area below 0x400000 or the signed GMD1 model slot [0x400000,0x529700].
"""
import hashlib
import runpy
import sys
from pathlib import Path

PGM_BIN = Path(r'C:\Efinity\2026.1\pgm\bin')
DBG_BIN = Path(r'C:\Efinity\2026.1\debugger\bin')
VENDOR = PGM_BIN / 'efx_pgm' / 'ftdi_program.py'
CONFIG_END = 0x00400000
MODEL_BASE = 0x00400000
MODEL_END = 0x00529700
MODEL_ERASE_LIMIT = (MODEL_END + 0xFFFF) & ~0xFFFF
EXPECTED_JEDEC = bytes((0xEF,0x60,0x17))
FLASH_BYTES = 8 * 1024 * 1024
ERASE_UNIT = 4096
args = sys.argv[1:]

def option(name, default=None):
    try: return args[args.index(name)+1]
    except ValueError: return default

def hex_payload(path):
    lines=Path(path).read_text(encoding='ascii').splitlines()
    if not lines or any(len(x.strip())!=2 for x in lines):
        raise SystemExit('refusing non byte-per-line Efinity HEX')
    return bytes(int(x.strip(),16) for x in lines)

mode=option('-m',option('--mode'))
bridge_mode=option('--jtag_bridge_mode','all')
url=option('-u',option('--url'))
address=int(option('--address','0'),0)
inputs=[x for x in args if not x.startswith('-')]
if mode!='jtag_bridge' or bridge_mode not in {'write','erase_and_write','all','all_no_erase'}:
    raise SystemExit('maximum-wait shim is restricted to jtag_bridge write modes')
if not url or not Path(inputs[-1]).is_file():
    raise SystemExit('missing explicit FTDI URL or input image')
payload=hex_payload(inputs[-1]); end=address+len(payload)
erase_end=((end+ERASE_UNIT-1)//ERASE_UNIT)*ERASE_UNIT
if address==0:
    if end>CONFIG_END or erase_end>CONFIG_END:
        raise SystemExit(f'configuration write reaches model region: erase end 0x{erase_end:x}')
elif address==MODEL_BASE:
    if end>MODEL_END or erase_end>MODEL_ERASE_LIMIT:
        raise SystemExit(f'model write exceeds signed GMD1 slot/erase allowance: erase end 0x{erase_end:x}, limit 0x{MODEL_ERASE_LIMIT:x}')
else:
    raise SystemExit(f'unsupported Flash write base 0x{address:x}')
print(f'MAXWAIT_GUARD: image_sha256={hashlib.sha256(Path(inputs[-1]).read_bytes()).hexdigest()} payload={len(payload)} address=0x{address:x} erase_end=0x{erase_end:x}')

sys.path.insert(0,str(DBG_BIN)); sys.path.insert(0,str(PGM_BIN))
from efx_pgm.jtag2SpiFlash import SerialFlashDetector
original_get=SerialFlashDetector.get_flash_device
def guarded_get(driver):
    flash=original_get(driver)
    jedec=bytes(getattr(flash,'_jedec',b''))
    if jedec!=EXPECTED_JEDEC or len(flash)!=FLASH_BYTES or flash.get_erase_size()!=ERASE_UNIT:
        raise RuntimeError(f'Flash identity/capacity mismatch: jedec={jedec.hex()} bytes={len(flash)} erase={flash.get_erase_size()}')
    flash.change_wait_time(False)
    if flash._wait_for_completion.__name__!='_wait_for_completion_slow':
        raise RuntimeError('maximum page wait failed to activate')
    print(f'MAXWAIT_ACTIVE: JEDEC={jedec.hex()} capacity={len(flash)} page_wait={flash._wait_for_completion.__name__}')
    return flash
SerialFlashDetector.get_flash_device=staticmethod(guarded_get)
sys.argv=[str(VENDOR),*args]
try:
    runpy.run_path(str(VENDOR),run_name='__main__')
except SystemExit:
    raise
