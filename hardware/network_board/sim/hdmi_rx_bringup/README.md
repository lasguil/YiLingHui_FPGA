# Retained RX unit and characterization benches

Run a case from this directory with `powershell -File .\run_hdmi_rx_test.ps1 -Test <case>`.

- `reset_gate`: self-contained reset gate / stale-state behavior.
- `bitslip_phase`: 10 initial serial offsets through the vendor frame-bitslip + phasealign modules.
- `phasealign_lines`: word-boundary recovery checks using 1080p line and control-symbol cadence.
- `full_vblank`: full legacy decoder raster characterization including 99,000 clocks of vertical blank

All RTL dependencies are resolved relative to the B main project. Simulation requires the installed Questa path encoded in the runner.
