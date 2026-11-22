from pathlib import Path
import hashlib,json,shutil
root=Path(__file__).resolve().parents[1]
fw=root/'software/gesture_firmware/build/hand_marker'
rom=fw/'rom'
backup=root/'build/rom_backup_baseline'
backup.mkdir(parents=True,exist_ok=True)
names=[f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin' for i in range(4)]
old={}
for name in names:
    p=root/name
    if not (backup/name).exists(): shutil.copy2(p,backup/name)
    old[name]=hashlib.sha256((backup/name).read_bytes()).hexdigest()
for i,name in enumerate(names):
    src=rom/f'gesture_demo_ram_symbol{i}.bin'
    assert src.is_file() and src.stat().st_size>0
    shutil.copyfile(src,root/name)
lanes=[]
for name in names:
    words=(root/name).read_text('ascii').splitlines()
    assert len(words)==4096 and all(len(w)==8 and set(w)<={'0','1'} for w in words)
    lanes.append(bytes(int(w,2) for w in words))
image=bytes(lanes[i][j] for j in range(4096) for i in range(4))
bin_data=(fw/'gesture_demo.bin').read_bytes()
assert len(image)==16384 and image[:len(bin_data)]==bin_data and image[len(bin_data):]==bytes(16384-len(bin_data))
record={'status':'HAND_MARKER_FIRMWARE_ROM_INTEGRATED','firmware_bin':'software/gesture_firmware/build/hand_marker/gesture_demo.bin','firmware_bytes':len(bin_data),'firmware_sha256':hashlib.sha256(bin_data).hexdigest(),'rom_image_bytes':len(image),'rom_image_sha256':hashlib.sha256(image).hexdigest(),'baseline_lane_backup':'build/rom_backup_baseline','baseline_lane_sha256':old,'new_lane_sha256':{n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in names}}
(root/'build/hand_marker_rom_integration.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))