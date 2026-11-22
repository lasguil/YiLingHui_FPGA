# Project SDC is loaded by efx_sta before this script. Use the routed netlist.
report_timing_summary -file ti60f225_oob.timing.rpt
report_cdc -details -file signoff_cdc.rpt
report_bus_skew -file signoff_skew.rpt
