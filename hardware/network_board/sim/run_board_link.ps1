param([switch]$FullCapture,[switch]$OldParser)
$ErrorActionPreference='Stop'
$Project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo=(Resolve-Path (Join-Path $Project '..\..\..\..\..')).Path
$Name=if($FullCapture){'tb_board_link_capture'}else{'tb_board_link_dvi'}
$Run=Join-Path (Join-Path $Project 'tmp') ($Name+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fffffff'))
New-Item -ItemType Directory $Run|Out-Null
$Questa='C:\altera\25.1std\questa_fse\win64'
$Parser=if($OldParser){Join-Path $Project 'tmp/package_ctrl_v1_before_dvi_fix.v'}else{Join-Path $Project 'rtl/vendor_hdmi/source/hdmi_src/dvi_rx/package_ctrl_v1.v'}
Push-Location $Run
try {
 & "$Questa/vlib.exe" work |Out-Null
 $files=@((Join-Path $Repo 'Efinity_Projects/ti60f225_style_demo_renderer_20261010/rtl/tmds_encode.v'),$Parser,(Join-Path $Project 'rtl/vendor_hdmi/source/hdmi_src/dvi_rx/decoder_v1.v'))
 if($FullCapture){$files+=@((Join-Path $Project 'rtl/demo_bus_pkg.sv'),(Join-Path $Project 'rtl/gesture_async_fifo.sv'),(Join-Path $Project 'rtl/gesture_sync_fifo.sv'),(Join-Path $Project 'rtl/gesture_frame_capture.sv'))}
 $files+=(Join-Path $Project ('sim/'+$Name+'.sv'))
 & "$Questa/vlog.exe" -sv -timescale 1ns/1ps @files *>compile.log
 if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
 $sim=Start-Process -FilePath "$Questa/vsim.exe" -ArgumentList @('-c','-onfinish','exit','-l','simulation.log',('work.'+$Name),'-do','"run -all"') -WindowStyle Hidden -PassThru -RedirectStandardOutput stdout.log -RedirectStandardError stderr.log
 $null=$sim.Handle
 if(!$sim.WaitForExit(300000)){& taskkill.exe /PID $sim.Id /T /F|Out-Null;throw 'simulation timeout'}
 $sim.WaitForExit();$sim.Refresh();Write-Output ("Simulator exit code: "+$sim.ExitCode)
 Get-Content simulation.log -Tail 12
 if($sim.ExitCode -ne 0 -or (Get-Content simulation.log -Raw) -notmatch 'PASS (board A to B|actual board-A)'){throw "simulation failed: $Run"}
}finally{Pop-Location}



