from pathlib import Path
import argparse
root=Path(__file__).resolve().parents[1]
check=argparse.ArgumentParser();check.add_argument('--check-only',action='store_true');args=check.parse_args()
raw=(root/'software/build/product_ui_24k.bin').read_bytes()
if len(raw)>24576:raise SystemExit('Firmware exceeds 24KiB OCR')
image=raw.ljust(24576,b'\0');lanes=[image[i::4] for i in range(4)]
assert bytes(lanes[i][n] for n in range(6144) for i in range(4))==image
for i,lane in enumerate(lanes):
 stem=f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}'
 for suffix,data in [('',lane),('_lo',lane[:4096]),('_hi',lane[4096:])]:
  path=root/(stem+suffix+'.bin')
  if args.check_only:
   assert bytes(int(x,2) for x in path.read_text().splitlines())==data,path
  else:path.write_bytes(('\r\n'.join(f'{b:08b}' for b in data)+'\r\n').encode('ascii'))
print('PASS 24KiB ROM interleave and split banks; firmware bytes',len(raw))
