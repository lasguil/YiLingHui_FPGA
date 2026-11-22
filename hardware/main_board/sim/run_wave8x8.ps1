$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$run=Join-Path $project 'tmp/wave8x8'
New-Item -ItemType Directory -Force $run | Out-Null
& 'C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe' -E -I -B -X utf8 "$PSScriptRoot/wave8x8_vectors.py"
if($LASTEXITCODE){throw 'vector generation failed'}
$q='C:\altera\25.1std\questa_fse\win64'
Push-Location $run
try {
 & "$q/vlib.exe" work | Out-Null
 & "$q/vlog.exe" -sv C:/Efinity/2026.1/sim_models/verilog/efx_srl8.v "$project/rtl/wave_roi_stats.sv" "$project/rtl/wave_pulse_detector.sv" "$PSScriptRoot/tb_wave8x8_detector.sv" "$PSScriptRoot/tb_wave8x8_stats.sv" *>compile.log
 if($LASTEXITCODE){Get-Content compile.log -Tail 30;throw 'compile failed'}
 foreach($vectors in Get-ChildItem $run -Filter '*.txt'){
  & "$q/vsim.exe" -c work.tb_wave8x8_detector "+VECTORS=$($vectors.FullName.Replace('\','/'))" -do 'run -all; quit -f' -l "$($vectors.BaseName).log" *>"$($vectors.BaseName).console.log"
  $log=Get-Content "$($vectors.BaseName).log" -Raw
  if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS WAVE GOLDEN'){Get-Content "$($vectors.BaseName).log" -Tail 25;throw 'detector comparison failed'}
  Get-Content "$($vectors.BaseName).log" | Select-String 'EVENT|PASS WAVE'
 }
 & "$q/vsim.exe" -c work.tb_wave8x8_stats -do 'run -all; quit -f' -l frontend.log *>frontend.console.log
 $log=Get-Content frontend.log -Raw
 if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS WAVE FRONTEND'){Get-Content frontend.log -Tail 25;throw 'frontend comparison failed'}
 Get-Content frontend.log | Select-String 'PASS WAVE'
}finally{Pop-Location}
