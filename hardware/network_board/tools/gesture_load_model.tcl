# Volatile DDR model preload. This file is intentionally guarded; the batch
# wrapper sets GESTURE_DDR_LOAD=YES only for an explicit --load --location/
# --serial request. It never invokes flash programming commands.
if {![info exists ::env(GESTURE_DDR_LOAD)] || $::env(GESTURE_DDR_LOAD) ne "YES"} {
    error "DDR writes disabled: use gesture_load_model.bat --load with an explicit --location or --serial"
}
if {![info exists ::env(GESTURE_DDR_LOAD_TARGET)] ||
    ![regexp {^(location|serial):[A-Za-z0-9._-]+$} $::env(GESTURE_DDR_LOAD_TARGET)]} {
    error "DDR writes disabled: an explicit adapter location/serial was not passed to the loader"
}

set tools_dir [file dirname [info script]]
set board_dir [file join $tools_dir ..]
set fw_dir [file join $board_dir software gesture_firmware]
set weights_file [file join $fw_dir model weights_hw.bin]
set params_file [file join $fw_dir model param_hw.bin]
set weights_addr 0x02000000
set params_addr 0x0210d000
set cal_status_addr 0xf8100004
set expected_weights_bytes 1099552
set expected_params_bytes 112384
set expected_weights_crc 0x992e868b
set expected_params_crc 0x3ff5e162
source [file join $tools_dir gesture_ddr_crc.tcl]

if {![file isfile $weights_file] || ![file isfile $params_file]} {
    error "model binary missing under $fw_dir"
}
if {[file size $weights_file] != $expected_weights_bytes} {
    error "weights image size mismatch: expected $expected_weights_bytes bytes"
}
if {[file size $params_file] != $expected_params_bytes} {
    error "params image size mismatch: expected $expected_params_bytes bytes"
}

targets fpga_spinal.cpu0
halt
wait_halt 5000

# diag CSR 0xf8100004 is cal_done_core, synchronized into Sapphire's 100 MHz
# domain. Poll with a hard timeout before any DDR write is issued.
set cal_ready 0
for {set i 0} {$i < 300} {incr i} {
    set cal_words [read_memory $cal_status_addr 32 1]
    if {[llength $cal_words] != 1} {
        error "DDR calibration CSR read returned an unexpected result"
    }
    if {[expr {[lindex $cal_words 0] & 1}] == 1} {
        set cal_ready 1
        break
    }
    sleep 100
}
if {!$cal_ready} {
    resume
    error "DDR calibration did not complete within 30 seconds; no model bytes were written"
}

echo "DDR calibration ready; loading volatile model images"
load_image $weights_file $weights_addr bin
set weights_crc [gesture_crc32_ddr $weights_addr $expected_weights_bytes]
if {$weights_crc != $expected_weights_crc} {
    resume
    error "weights DDR readback CRC mismatch: got [format 0x%08x $weights_crc], expected [format 0x%08x $expected_weights_crc]"
}
load_image $params_file $params_addr bin
set params_crc [gesture_crc32_ddr $params_addr $expected_params_bytes]
if {$params_crc != $expected_params_crc} {
    resume
    error "params DDR readback CRC mismatch: got [format 0x%08x $params_crc], expected [format 0x%08x $expected_params_crc]"
}
echo "DDR readback CRCs PASS; resuming firmware for its independent CRC checks"
resume
if {[info exists ::env(GESTURE_MODEL_READY_ADDR)]} {
    if {![regexp {^0x[0-9a-fA-F]{1,8}$} $::env(GESTURE_MODEL_READY_ADDR)]} {
        error "invalid gesture_model_ready address supplied by the launcher"
    }
    set model_ready_addr [expr {wide($::env(GESTURE_MODEL_READY_ADDR))}]
    if {$model_ready_addr < 0xf9000000 || $model_ready_addr > 0xf9003ffc || ($model_ready_addr & 3) != 0} {
        error "gesture_model_ready address is outside aligned OCR RAM"
    }
    set model_ready 0
    for {set i 0} {$i < 900} {incr i} {
        sleep 100
        halt
        set ready_words [read_memory $model_ready_addr 32 1]
        if {[llength $ready_words] != 1} {
            resume
            error "gesture_model_ready read returned an unexpected result"
        }
        if {[expr {[lindex $ready_words 0] & 0xffffffff}] == 1} {
            set model_ready 1
            resume
            break
        }
        resume
    }
    if {!$model_ready} {
        error "CPU firmware did not set gesture_model_ready within 90 seconds"
    }
    echo "CPU gesture_model_ready=1; model initialization PASS"
}
shutdown
