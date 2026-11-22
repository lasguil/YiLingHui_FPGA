# Entry point for map-aware bundled CDC payload STA.
#
# First run verify_cdc_payloads.py generate on the exact formal map. It checks
# every dynamic source-Q/capture-D pair against the loaded SDC and emits a Tcl
# script with one exact setup report per dynamic bit. Then:
#
#   $env:CDC_PAYLOAD_STA_TCL = '<generated verify_cdc_payloads.generated.tcl>'
#   efx_sta --prj ti60f225_oob.xml -t tools/verify_cdc_payloads.tcl
#
# The Python validator consumes the full STA transcript and checks map/SDC/tool
# hashes, one report per dynamic bit, the expected max-delay exception, positive
# slack, and the exact mapped capture endpoint. A fixed FF count is deliberately
# not used because constant bus fields are optimized by the mapper.

if {![info exists ::env(CDC_PAYLOAD_STA_TCL)]} {
    error "Set CDC_PAYLOAD_STA_TCL to the generated per-bit STA Tcl script"
}
set cdc_payload_tcl $::env(CDC_PAYLOAD_STA_TCL)
if {![file exists $cdc_payload_tcl]} {
    error "Generated CDC payload STA Tcl not found: $cdc_payload_tcl"
}
if {![info exists ::env(CDC_PAYLOAD_SDC)] || ![file exists $::env(CDC_PAYLOAD_SDC)]} {
    error "Set CDC_PAYLOAD_SDC to the frozen project SDC"
}
set cdc_payload_sdc [string map [list "\\" "/"] $::env(CDC_PAYLOAD_SDC)]
read_sdc $cdc_payload_sdc
# Rebuild the routed timing graph before individual paths are queried.
report_timing_summary -file cdc_initial_timing.rpt
puts "CDC_PAYLOAD_ENTRY script=$cdc_payload_tcl"

# Check the exact mapped Sapphire USER1 CDC objects before reporting any
# timing. The loader contract limits TCK to 800 kHz; payload bundles retain a
# 9 ns setup bound independent of this external clock.
set jtag_toggle_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_target~FF$}]
set jtag_toggle_dst [get_pins -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_target_buffercc/i7_2\|D$}]
set jtag_cmd_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_data_(last|fragment\[0\])~FF$}]
set jtag_cmd_dst [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge_io_remote_cmd_payload_(last|fragment\[0\])~FF$}]
if {[llength $jtag_toggle_src] != 1 || [llength $jtag_toggle_dst] != 1} {
    error "JTAG toggle CDC mapping mismatch: src=[llength $jtag_toggle_src] dst=[llength $jtag_toggle_dst]"
}
if {[llength $jtag_cmd_src] != 2 || [llength $jtag_cmd_dst] != 2} {
    error "JTAG command payload mapping mismatch: src=[llength $jtag_cmd_src] dst=[llength $jtag_cmd_dst]"
}
puts "JTAG_TOGGLE_SOURCE_COUNT [llength $jtag_toggle_src]"
puts "JTAG_TOGGLE_FIRST_STAGE_D_COUNT [llength $jtag_toggle_dst]"
puts "JTAG_COMMAND_SOURCE_COUNT [llength $jtag_cmd_src]"
puts "JTAG_COMMAND_CAPTURE_COUNT [llength $jtag_cmd_dst]"
set jtag_command_pairs {
    {u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_data_last~FF u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge_io_remote_cmd_payload_last~FF}
    {u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/flowCCUnsafeByToggle_1/inputArea_data_fragment[0]~FF u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge_io_remote_cmd_payload_fragment[0]~FF}
}
foreach jtag_pair $jtag_command_pairs {
    set jtag_src [get_cells [lindex $jtag_pair 0]]
    set jtag_dst [get_cells [lindex $jtag_pair 1]]
    puts "JTAG_COMMAND_PATH_BEGIN $jtag_pair"
    report_timing -from $jtag_src -to $jtag_dst -npaths 1 -setup -stdout
    puts "JTAG_COMMAND_PATH_END $jtag_pair"
}
for {set jtag_bit 0} {$jtag_bit < 32} {incr jtag_bit} {
    set jtag_shift_bit [expr {$jtag_bit + 2}]
    set jtag_src_name [format {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/system_rsp_payload_data\[%d\]~FF$} $jtag_bit]
    set jtag_dst_name [format {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/jtag_readArea_full_shifter\[%d\]~FF$} $jtag_shift_bit]
    set jtag_src [get_cells -regexp $jtag_src_name]
    set jtag_dst [get_cells -regexp $jtag_dst_name]
    if {[llength $jtag_src] != 1 || [llength $jtag_dst] != 1} {
        error "JTAG response bit $jtag_bit mapping mismatch: src=[llength $jtag_src] dst=[llength $jtag_dst]"
    }
    puts "JTAG_RESPONSE_PATH_BEGIN bit=$jtag_bit shift=$jtag_shift_bit"
    report_timing -from $jtag_src -to $jtag_dst -npaths 1 -setup -stdout
    puts "JTAG_RESPONSE_PATH_END bit=$jtag_bit shift=$jtag_shift_bit"
}
set jtag_err_src [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/system_rsp_payload_error~FF$}]
set jtag_err_dst [get_cells -regexp {^u_sapphire_soc/u_EfxSapphireSoc/system_hardJtag_debug_logic_jtagBridge/jtag_readArea_full_shifter\[1\]~FF$}]
if {[llength $jtag_err_src] != 1 || [llength $jtag_err_dst] != 1} {
    error "JTAG response error mapping mismatch: src=[llength $jtag_err_src] dst=[llength $jtag_err_dst]"
}
puts "JTAG_RESPONSE_ERROR_PATH_BEGIN"
report_timing -from $jtag_err_src -to $jtag_err_dst -npaths 1 -setup -stdout
puts "JTAG_RESPONSE_ERROR_PATH_END"

report_timing_summary -file ti60f225_oob.timing.rpt
source $cdc_payload_tcl

if {![info exists ::env(CDC_GRAY_STA_TCL)]} {
    error "Set CDC_GRAY_STA_TCL to the generated DDR Gray CDC STA Tcl script"
}
set cdc_gray_tcl $::env(CDC_GRAY_STA_TCL)
if {![file exists $cdc_gray_tcl]} {
    error "Generated DDR Gray CDC STA Tcl not found: $cdc_gray_tcl"
}
puts "DDR_GRAY_CDC_ENTRY script=$cdc_gray_tcl"
source $cdc_gray_tcl
