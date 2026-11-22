# Invoke after the board target has been initialized and DDR calibration is ready:
#   openocd -f <board-debug.cfg> -f tools/load_model.tcl
# Loads volatile DDR only; does not program persistent flash.
set fw_dir [file normalize [file join [file dirname [info script]] ..]]
halt
load_image [file join $fw_dir model weights_hw.bin] 0x02000000 bin
load_image [file join $fw_dir model param_hw.bin] 0x0210d000 bin
resume
shutdown
