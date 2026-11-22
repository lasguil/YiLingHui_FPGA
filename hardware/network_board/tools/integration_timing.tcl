set project_root [file normalize [file join [file dirname [info script]] ..]]
set ::env(CDC_PAYLOAD_SDC) [file join $project_root ti60f225_oob.sdc]
set ::env(CDC_PAYLOAD_STA_TCL) [file join $project_root build cdc_payload_signoff verify_cdc_payloads.generated.tcl]
set ::env(CDC_GRAY_STA_TCL) [file join $project_root build cdc_payload_signoff verify_ddr_gray_cdc.generated.tcl]
source [file join $project_root tools verify_cdc_payloads.tcl]
report_timing_summary -file final_timing.rpt
# Print coverage counts so unmapped MJPEG FIFO Gray constraints cannot pass silently.
foreach {object_name expected} {
    mjpeg_wgray_src 14 mjpeg_wgray_dst 14 mjpeg_rgray_src 14 mjpeg_rgray_dst 14
    hdmi_mjpeg_wgray_src 12 hdmi_mjpeg_wgray_dst 12 hdmi_mjpeg_rgray_src 12 hdmi_mjpeg_rgray_dst 12
    hdmi_capture_wgray_src 10 hdmi_capture_wgray_dst 10 hdmi_capture_rgray_src 10 hdmi_capture_rgray_dst 10
} {
    set objects [set $object_name]
    if {[llength $objects] != $expected} {error "MJPEG CDC endpoint mismatch: $object_name"}
    puts "MJPEG_CDC_OBJECTS $object_name [llength $objects]"
}

foreach {name pattern} {
    capture_valid_meta {^net_status_meta\[6\]~FF\|D$}
    mjpeg_start_first {^mjpeg_start_sync\[0\]~FF\|D$}
    mjpeg_busy_first {^mjpeg_busy_sync\[0\]~FF\|D$}
    mjpeg_error_first {^mjpeg_error_sync\[0\]~FF\|D$}
    mjpeg_source_overflow_first {^mjpeg_source_overflow_sync\[0\]~FF\|D$}
    mjpeg_source_error_first {^mjpeg_source_error_sync\[0\]~FF\|D$}
    mjpeg_output_overflow_first {^mjpeg_output_overflow_sync\[0\]~FF\|D$}
    hdmi_mjpeg_bad_first {^u_mjpeg_source/u_capture/bad_sync1~FF\|D$}
    mjpeg_source_frame_first {^mjpeg_source_frame_sync\[0\]~FF\|D$}
    hdmi_capture_bad_first {^u_capture/bad_sync1~FF\|D$}
} {
    set objects [get_pins -regexp $pattern]
    if {[llength $objects] != 1} {error "MJPEG control CDC endpoint mismatch: $name"}
    puts "MJPEG_CDC_CONTROL $name [llength $objects]"
}
# Removed adaptive geometry metadata has no CDC endpoints. The companion
# Python checker verifies their absence in the mapped netlist; do not query
# nonexistent pins or retain a stale false-path exception here.
puts "HDMI_INPUT_MODE_CDC fixed_1080p"
foreach {name pattern expected} {
    stream_up_reset {^mjpeg_stream_up\[[01]\]~FF\|SR$} 2
    stream_abort_reset {^mjpeg_link_abort~FF\|SR$} 1
} {
    set objects [get_pins -regexp $pattern]
    if {[llength $objects] != $expected} {error "Stream recovery reset endpoint mismatch: $name"}
    puts "STREAM_RECOVERY_RESET $name [llength $objects]"
}
foreach {name pattern} {
    capture_pclk_reset {^u_capture/pclk_reset_pipe\[[01]\]~FF\|SR$}
    mjpeg_pclk_reset {^u_mjpeg_source/u_capture/pclk_reset_pipe\[[01]\]~FF\|SR$}
} {
    set objects [get_pins -regexp $pattern]
    if {[llength $objects] != 2} {error "HDMI pixel reset synchronizer mismatch: $name"}
    puts "HDMI_PCLK_RESET $name [llength $objects]"
}
set mjpeg_head_reset [get_pins -regexp {^mjpeg_fifo_data\[[0-8]\]~FF\|SR$}]
set mjpeg_empty_reset [get_pins -regexp {^net_pixel_valid~FF\|SR$}]
if {[llength $mjpeg_head_reset] != 9 || [llength $mjpeg_empty_reset] != 1} {
    error "MJPEG FIFO FWFT reset endpoint mismatch"
}
puts "MJPEG_CDC_RESET head=[llength $mjpeg_head_reset] empty=[llength $mjpeg_empty_reset]"

proc report_mjpeg_bank {group instance bank source_stem sink_stem width msb} {
    for {set bit 0} {$bit < $width} {incr bit} {
        set stem $source_stem
        if {$bit == $msb && $bank eq "write"} {set stem "$instance/wbin"}
        if {$bit == $msb && $bank eq "read"} {set stem "$instance/rcons_bin"}
        set source_name [format {%s[%d]~FF|Q} $stem $bit]
        set sink_name [format {%s[%d]~FF|D} $sink_stem $bit]
        set source_re [format {^%s\[%d\]~FF\|Q$} $stem $bit]
        set sink_re [format {^%s\[%d\]~FF\|D$} $sink_stem $bit]
        set source [get_pins -regexp $source_re]
        set sink [get_pins -regexp $sink_re]
        if {[llength $source] != 1 || [llength $sink] != 1} {error "MJPEG exact Q/D lookup failed: $bank $bit"}
        puts "MJPEG_PATH_BEGIN bank=$group bit=$bit source=$source_name sink=$sink_name"
        report_timing -from $source -to $sink -npaths 1 -setup -stdout
        puts "MJPEG_PATH_END bank=$group bit=$bit"
    }
}
report_mjpeg_bank write u_mjpeg_fifo write u_mjpeg_fifo/wgray u_mjpeg_fifo/wgray_r1 14 13
report_mjpeg_bank read u_mjpeg_fifo read u_mjpeg_fifo/rcons_gray u_mjpeg_fifo/rcons_gray_w1 14 13
report_mjpeg_bank hdmi_write u_mjpeg_source/u_capture/u_pixel_fifo write u_mjpeg_source/u_capture/u_pixel_fifo/wgray u_mjpeg_source/u_capture/u_pixel_fifo/wgray_r1 12 11
report_mjpeg_bank hdmi_read u_mjpeg_source/u_capture/u_pixel_fifo read u_mjpeg_source/u_capture/u_pixel_fifo/rcons_gray u_mjpeg_source/u_capture/u_pixel_fifo/rcons_gray_w1 12 11
report_mjpeg_bank hdmi_capture_write u_capture/u_pixel_fifo write u_capture/u_pixel_fifo/wgray u_capture/u_pixel_fifo/wgray_r1 10 9
report_mjpeg_bank hdmi_capture_read u_capture/u_pixel_fifo read u_capture/u_pixel_fifo/rcons_gray u_capture/u_pixel_fifo/rcons_gray_w1 10 9
