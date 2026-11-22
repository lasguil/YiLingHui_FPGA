$ErrorActionPreference='Stop'
# Preserve the established entry point; the old three-ROI bench is archived
# in support/before_wave8x8_20261112. Use the reference/golden suite now.
& "$PSScriptRoot/run_wave8x8.ps1"
