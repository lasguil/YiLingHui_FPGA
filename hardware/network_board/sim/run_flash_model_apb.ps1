$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sim = Join-Path $root "tmp\flash_model_apb_sim"
New-Item -ItemType Directory -Force -Path $sim | Out-Null
Push-Location $sim
try {
    & vlib work
    if ($LASTEXITCODE -ne 0) { throw "vlib failed ($LASTEXITCODE)" }
    & vlog -sv (Join-Path $root "rtl\flash_model_apb.sv") (Join-Path $root "sim\tb_flash_model_apb.sv")
    if ($LASTEXITCODE -ne 0) { throw "vlog failed ($LASTEXITCODE)" }
    & vsim -c work.tb_flash_model_apb -do "run -all; quit -f"
    if ($LASTEXITCODE -ne 0) { throw "vsim failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
