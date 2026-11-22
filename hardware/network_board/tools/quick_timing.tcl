set root [file normalize [file join [file dirname [info script]] ..]]
read_sdc [file join $root ti60f225_oob.sdc]
report_timing_summary -file [file join $root build quick_timing.rpt]
