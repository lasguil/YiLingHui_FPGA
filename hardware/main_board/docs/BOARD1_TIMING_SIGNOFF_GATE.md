# Board 1 timing signoff gate

After routed STA writes `outflow/ti60f225_oob.timing.rpt`, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/check_timing_gate.ps1 -TimingReport outflow/ti60f225_oob.timing.rpt
```

The gate rejects an incomplete report or any negative setup or hold clock
relationship. `compile.bat` runs it after routed static timing analysis and before
generating the programming files. FPGA configuration is a separate step.
