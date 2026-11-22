# Second-board JTAG model preload

`gesture_load_model.bat` defaults to a read-only USER1 TAP scan. It creates no
CPU target, does not halt Sapphire, and issues no memory write. A DDR load is a
separate, explicit operation and requires one adapter selector:

```text
gesture_load_model.bat
gesture_load_model.bat --scan --location 1-4.2
gesture_load_model.bat --load --location 1-4.2
gesture_load_model.bat --load --serial <adapter-serial>
```

`--location` is OpenOCD's USB bus-port location syntax (`bus-port[.port]...`),
not an Efinity adapter URI. Use the actual Windows/OpenOCD USB location for the
second-board FT4232; do not guess it. The existing board notes say the FT4232
EEPROM has no serial or description, so the expected selector is `--location`.
Load mode rejects a missing selector and never silently picks an adapter. The
no-selector scan is read-only and useful for confirming whether OpenOCD sees a
matching FT4232.

The adapter file uses the known FT4232 VID/PID `0403:6011`, JTAG channel 1,
layout `0x08/0x0b`, and 800 kHz. The board-local debug target follows the
Sapphire `debug_ti.cfg` VexRiscv configuration, but resolves `gesture_cpu0.yaml`
beside itself instead of searching from the first-board working directory.
That YAML was copied from the local Ti60F225 Sapphire package; the second-board
generated `soc.v` contains one Sapphire CPU and its `hardJtag_debug_logic`, and
the board top connects USER1 to `jtagCtrl_*`.

The loader reads `0xf8100004` (the synchronized CPU-domain DDR `cal_done_core`)
until ready, with a 30 s bound, before its first DDR write. It loads the two
checked-in binaries only to volatile DDR, reads the full images back through
the Sapphire target and checks their manifest CRC32 values, then resumes
firmware. The installed OpenOCD build does not provide `verify_image`; the
loader therefore uses a complete byte-for-byte-content CRC readback instead.
Firmware independently checks both packaged CRCs after resume. No
flash-programming command is used.
