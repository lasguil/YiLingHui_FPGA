[CmdletBinding()]
param([ValidateSet('reset_gate','bitslip_phase','phasealign_lines','full_vblank')][string]$Test='reset_gate')
$ErrorActionPreference='Stop'
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$rtl=Join-Path $projectRoot 'rtl\vendor_hdmi\source\hdmi_src\dvi_rx'
$questa='C:\altera\25.1std\questa_fse\win64'
$work=Join-Path $PSScriptRoot "work_$Test"
New-Item -ItemType Directory -Force -Path $work | Out-Null
switch($Test){
 'reset_gate' { $tb=Join-Path $PSScriptRoot 'tb_decoder_reset_gate.sv'; $top='tb_decoder_reset_gate'; $src=@($tb) }
 'bitslip_phase' { $tb=Join-Path $PSScriptRoot 'tb_bitslip_phase.sv'; $top='tb_bitslip_phase'; $src=@((Join-Path $rtl 'frame_bitslip.v'),(Join-Path $rtl 'phasealign_v1.v'),$tb) }
 'phasealign_lines' { $tb=Join-Path $PSScriptRoot 'tb_phasealign_hdmi_lines.sv'; $top='tb_phasealign_hdmi_lines'; $src=@((Join-Path $rtl 'frame_bitslip.v'),(Join-Path $rtl 'phasealign_v1.v'),$tb) }
 'full_vblank' { $tb=Join-Path $PSScriptRoot 'tb_dvi_full_vblank.sv'; $top='tb_dvi_full_vblank'; $src=@((Join-Path $rtl 'frame_bitslip.v'),(Join-Path $rtl 'phasealign_v1.v'),(Join-Path $rtl 'decoder_v1.v'),(Join-Path $rtl 'EDID\simple_dual_port_ram.v'),(Join-Path $rtl 'channelbond_v1.v'),(Join-Path $rtl 'tmds_decoder.v'),(Join-Path $rtl 'channelboad_ctrl.v'),(Join-Path $rtl 'dyn_delay.v'),(Join-Path $rtl 'lvds_dynamic_delay_v2.v'),(Join-Path $rtl 'de_sync.v'),(Join-Path $rtl 'package_ctrl_v1.v'),(Join-Path $rtl 'aux_parse.v'),(Join-Path $rtl 'dvi_decoder.v'),$tb) }
}
Push-Location $work
try {
  & (Join-Path $questa 'vlib.exe') work | Out-Null
  if($LASTEXITCODE -ne 0){throw "vlib failed: $LASTEXITCODE"}
  & (Join-Path $questa 'vlog.exe') -sv -timescale 1ns/1ps @src -work work *> (Join-Path $PSScriptRoot "$Test.vlog.log")
  if($LASTEXITCODE -ne 0){throw "vlog failed: $LASTEXITCODE"}
  & (Join-Path $questa 'vsim.exe') -c "work.$top" -do 'run -all; quit -f' -l (Join-Path $PSScriptRoot "$Test.vsim.log")
  if($LASTEXITCODE -ne 0){throw "vsim failed: $LASTEXITCODE"}
} finally { Pop-Location }
