from pathlib import Path
import hashlib,os,runpy,sys
import argparse
parser=argparse.ArgumentParser(description='Board1 volatile JTAG only; fixed HiFTDI target, never ordinary FTDI.')
parser.add_argument('--bit',type=Path,required=True)
parser.add_argument('--sha256')
parser.add_argument('--dry-run',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parents[3]
bit=args.bit.resolve()
if not bit.is_relative_to(root) or bit.suffix.lower()!='.bit':raise SystemExit('BIT must be a project .bit file')
digest=hashlib.sha256(bit.read_bytes()).hexdigest()
if args.sha256 and digest!=args.sha256.lower():raise SystemExit('BIT SHA256 mismatch')
print('TARGET=BOARD1 hiftdi://0x0403:0x6011/1; BIT='+str(bit)+'; SHA256='+digest,flush=True)
if args.dry_run:raise SystemExit(0)
tmp=root/'tmp/board1_jtag';tmp.mkdir(parents=True,exist_ok=True)
os.environ['TMP']=os.environ['TEMP']=str(tmp)
os.environ['EFX_HIFTDI_ENABLE']='1'
os.environ['QT_QPA_PLATFORM']='offscreen'
user=tmp/'hiftdi_user';user.mkdir(exist_ok=True)
os.environ['EFINITY_USER_DIR_INI']=str(tmp/'hiftdi_user.ini');os.environ['EFINITY_USER_DIR']=str(user)
(tmp/'hiftdi_user.ini').write_text('[General]\nEFINITY_USER_DIR='+str(user)+'\n')
vendor=r'C:\Efinity\2026.1\python311\Lib\site-packages';sys.path.insert(0,vendor)
import vcd
sys.path.remove(vendor);sys.path.append(vendor)
compat=runpy.run_path(str(Path(__file__).resolve().with_name('program_flash_hiftdi.py')))
compat['install_hiftdi_adapter']()
sys.argv=['ftdi_program','-m','jtag','-u','hiftdi://0x0403:0x6011/1','--jtag_clock_freq','3000000',str(bit)]
runpy.run_module('efx_pgm.ftdi_program',run_name='__main__')
