param([switch]$CompareLegacy)
$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot\..").Path
$q='C:\altera\25.1std\questa_fse\win64'
$run="$p/tmp/model_switch_regression"
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
try {
    & "$q/vlib.exe" work | Out-Null
    $files=@('rtl/demo_model_asset_pkg.sv','rtl/demo_bus_pkg.sv','rtl/demo_axi_merge.sv',
        'rtl/display/display_cfg_csr.sv','rtl/display/display_renderer.sv',
        'rtl/display/display_axi_line_cache.sv','rtl/display/display_axi_shared_reader.sv',
        'rtl/display/display_ui_catalog_ram.sv','rtl/display/pipeline_luna_ui_text_rom.sv',
        'rtl/display/pipeline_luna_ui_glyph_rom.sv','rtl/display/display_system_top.sv',
        'rtl/tmds_encode.v','rtl/accelerator/npu/host/ngm_weight_dma.sv',
        'rtl/accelerator/npu/host/ngm_axi_master.sv','rtl/accelerator/npu/host/ngm_host_if.sv',
        'rtl/accelerator/npu/host/ngm_npu_regs.sv','rtl/accelerator/npu/host/ngm_perf_counters.sv',
        'sim/tb_weight_dma_segmented.sv','sim/tb_display_model_switch.sv') | ForEach-Object {Join-Path $p $_}
    & "$q/vlog.exe" -sv -timescale 1ns/1ps -svinputport=net +define+SIM_ASSERT @files C:\Efinity\2026.1\sim_models\verilog\efx_ram10.v *> compile.log
    if($LASTEXITCODE){Get-Content compile.log -Tail 40;throw 'compile failed'}
    function Run-Checked([string]$Name,[string]$Top,[string[]]$Extra,[string]$Pass) {
        & "$q/vsim.exe" -c "work.$Top" @Extra -do 'run -all; quit -f' -l "$Name.log" *> "$Name.console.log"
        $log=Get-Content "$Name.log" -Raw
        if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch $Pass){Get-Content "$Name.log" -Tail 35;throw "$Name failed"}
        Select-String -Path "$Name.log" -Pattern 'TB PASS|PASS DISPLAY|MODEL_LOAD' | ForEach-Object {$_.Line}
    }
    Run-Checked 'weight_direct' 'tb_weight_dma_segmented' @() 'TB PASS: WEIGHT_DMA'
    Run-Checked 'weight_wrapped' 'tb_weight_dma_segmented' @('-gWRAPPED=1') 'TB PASS: WEIGHT_DMA'
    $geometry=@('-gTEST_WIDTH=1920','-gTEST_HEIGHT=12','-gSTEP_X=29164','-gSTEP_Y=29164',
        '-gREAD_GAP=2','-gDYNAMIC=1','-gONE_PASS=1','-gAXI_HALF_NS=2.7778','-gCHECK_DIAGNOSTICS=1')
    Run-Checked 'no_model' 'tb_display_model_switch' ($geometry+@('-gMERGE_COMPETITOR=0')) 'PASS DISPLAY_VIEWPORT'
    Run-Checked 'model_segmented' 'tb_display_model_switch' ($geometry+@('-gMERGE_COMPETITOR=1')) 'PASS DISPLAY_VIEWPORT'
    if($CompareLegacy){
        & "$q/vlog.exe" -sv -timescale 1ns/1ps "$p/sim/reference/ngm_weight_dma_before_20261111.sv" *> legacy_compile.log
        if($LASTEXITCODE){throw 'legacy compile failed'}
        & "$q/vsim.exe" -c work.tb_display_model_switch @geometry -gMERGE_COMPETITOR=1 -do 'run -all; quit -f' -l model_legacy.log *> model_legacy.console.log
        $log=Get-Content model_legacy.log -Raw
        if($log -notmatch 'MODEL_LOAD_DONE items=2560' -or $log -notmatch 'single full viewport mismatches=4136 of 23040'){
            Get-Content model_legacy.log -Tail 35;throw 'legacy did not reproduce the expected black pixels'
        }
        Write-Output 'PASS legacy-only reproduction: 4136 mismatches; current segmented model: 0 mismatches'
    }
}finally{Pop-Location}
