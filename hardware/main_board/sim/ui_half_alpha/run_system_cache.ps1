param([int]$Width=64,[int]$Height=8,[switch]$ExpectUnderflow)
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sim=Join-Path $project 'sim'
$scenario=if($ExpectUnderflow){'sim_system_cache_underflow'}else{'sim_system_cache_normal'}
$work=Join-Path $project ("tmp/ui_half_alpha/$scenario")
$tool='C:\altera\25.1std\questa_fse\win64'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$tb=Join-Path $PSScriptRoot 'tb_ui_half_system_cache.sv'
$src=[IO.File]::ReadAllText((Join-Path $sim 'tb_display_scene.sv'))
$src=[regex]::Replace($src,"if\(x==0 \|\| x==H_ACTIVE-1 \|\| y==0 \|\| y==V_ACTIVE-1\) expect_pixel=16'hffff;\s*else if\(mode_tb==2",'if(mode_tb==2')
$src=$src.Replace('logic [11:0] cx=0,cy=0;','logic [11:0] cx0=0,cy0=0,cx=0,cy=0;')
$src=$src.Replace('logic cde=0;','logic cde0=0,cde=0;')
$old="if(!pix_rst_n) begin cx<=0;cy<=0;cde<=0;end"+[Environment]::NewLine+"        else begin cx<=dut.x;cy<=dut.y;cde<=dut.in_de;end"
$new="if(!pix_rst_n) begin cx0<=0;cy0<=0;cde0<=0;cx<=0;cy<=0;cde<=0;end"+[Environment]::NewLine+"        else begin cx0<=dut.x;cy0<=dut.y;cde0<=dut.in_de;cx<=cx0;cy<=cy0;cde<=cde0;end"
$src=$src.Replace($old,$new)
$src=[regex]::Replace($src,'(?s)\s+if\(CHECK_EVENT_Y\)begin\s+wait\(dut\.row_prefetch_event_q.*?PASS DISPLAY_EVENT_RESET pending packet cancelled"\);\s+end','')
$src=$src.Replace('if(debug_rgb565!==(dut.ui_opaque_q?dut.overlay_q:(dut.ui_half_q?half565_tb(16''h0000,dut.overlay_q):dut.overlay_q)))fails=fails+1;',
  'if(debug_rgb565!==(dut.ui_opaque_q?dut.overlay_q:(dut.ui_half_q?half565_tb(16''h0000,dut.overlay_q):dut.overlay_q)))fails=fails+1;')
$src=$src.Replace('integer checks=0,fails=0;','integer checks=0,fails=0,half_source_checks=0;')
$oracle=@'
    logic [15:0] oracle_rgb,oracle_base;
    logic oracle_missing,oracle_half_valid;
    function automatic [15:0] half565_tb(input logic [15:0] a,input logic [15:0] b);
        integer r,g,bv;
        begin
            r=(int'(a[15:11])+int'(b[15:11]))/2;
            g=(int'(a[10:5])+int'(b[10:5]))/2;
            bv=(int'(a[4:0])+int'(b[4:0]))/2;
            half565_tb={r[4:0],g[5:0],bv[4:0]};
        end
    endfunction
    always @(posedge pix_clk)begin
        if(!pix_rst_n)begin oracle_rgb<=0;oracle_base<=0;oracle_missing<=0;oracle_half_valid<=0;end
        else begin
            oracle_base=0;
            if(dut.req_a_q&&dut.cache_a_valid)begin
                oracle_base=mem_at(BASE_A+STRIDE*dut.req_a_y_q+2*dut.req_a_x_q);
            end else if(dut.req_b_q&&dut.cache_b_valid)begin
                oracle_base=mem_at(BASE_B+STRIDE*dut.req_b_y_q+2*dut.req_b_x_q);
            end
            oracle_missing<=dut.de_q&&((dut.req_a_q&&!dut.cache_a_valid)||(dut.req_b_q&&!dut.cache_b_valid));
            oracle_half_valid<=dut.ui_half_q&&!((dut.req_a_q&&!dut.cache_a_valid)||(dut.req_b_q&&!dut.cache_b_valid))&&
                               (dut.req_a_q||dut.req_b_q);
            if(dut.ui_opaque_q)oracle_rgb<=dut.overlay_q;
            else if(dut.ui_half_q)oracle_rgb<=half565_tb(oracle_base,dut.overlay_q);
            else if((dut.req_a_q&&dut.cache_a_valid)||(dut.req_b_q&&dut.cache_b_valid))oracle_rgb<=oracle_base;
            else oracle_rgb<=dut.overlay_q;
        end
    end
'@
$src=$src.Replace('integer checks=0,fails=0,half_source_checks=0;', $oracle+[Environment]::NewLine+'    integer checks=0,fails=0,half_source_checks=0;')
$src=$src.Replace('                    if(debug_rgb565!==dut.overlay_q)fails=fails+1;',
  '                    if(debug_rgb565!==oracle_rgb)fails=fails+1;')
$src=$src.Replace('                end else if(debug_rgb565!==expect_pixel(cx,cy)) begin',
  '                end else if(debug_rgb565!==oracle_rgb) begin')
$src=$src.Replace('                checks=checks+1;','                checks=checks+1;if(oracle_half_valid)half_source_checks=half_source_checks+1;')
$src=$src.Replace('if(EXPECT_UNDERFLOW&&((dut.req_a_q&&!dut.cache_a_valid)||(dut.req_b_q&&!dut.cache_b_valid)))begin',
  'if(EXPECT_UNDERFLOW&&oracle_missing)begin')
$src=$src.Replace('mode_tb,cx,cy,debug_rgb565,expect_pixel(cx,cy));','mode_tb,cx,cy,debug_rgb565,expect_pixel(cx,cy));$display("UI half=%b opaque=%b overlay=%h A=%h B=%h",dut.ui_half_q,dut.ui_opaque_q,dut.overlay_q,dut.cache_a_pixel,dut.cache_b_pixel);')
$src=$src.Replace('csr_write(12''h030,32''d0);              // status_ok=0, ui_enable=0','csr_write(12''h030,32''d1);              // UI enabled; underlay reads remain demanded')
$src=$src.Replace('        $display("PASS DISPLAY_SCENE original=1 processed=1 wipe=1 side_by_side=1 pixels=%0d",checks);',
  '        if(half_source_checks==0)$fatal(1,"no valid cache-returned pixel was checked under half-alpha UI");'+[Environment]::NewLine+'        $display("PASS UI_HALF_SYSTEM_CACHE original=1 processed=1 wipe=1 side_by_side=1 pixels=%0d valid_half_source=%0d",checks,half_source_checks);')
$arith=@'
    integer arith_r0,arith_r1,arith_g0,arith_g1,arith_b0,arith_b1,arith_i;
    logic [15:0] arith_a,arith_b;
    initial begin
        for(arith_r0=0;arith_r0<32;arith_r0=arith_r0+1)for(arith_r1=0;arith_r1<32;arith_r1=arith_r1+1)
            if(dut.half565({arith_r0[4:0],11'd0},{arith_r1[4:0],11'd0})!==half565_tb({arith_r0[4:0],11'd0},{arith_r1[4:0],11'd0}))$fatal(1,"red half565 mismatch %0d/%0d",arith_r0,arith_r1);
        for(arith_g0=0;arith_g0<64;arith_g0=arith_g0+1)for(arith_g1=0;arith_g1<64;arith_g1=arith_g1+1)
            if(dut.half565({5'd0,arith_g0[5:0],5'd0},{5'd0,arith_g1[5:0],5'd0})!==half565_tb({5'd0,arith_g0[5:0],5'd0},{5'd0,arith_g1[5:0],5'd0}))$fatal(1,"green half565 mismatch %0d/%0d",arith_g0,arith_g1);
        for(arith_b0=0;arith_b0<32;arith_b0=arith_b0+1)for(arith_b1=0;arith_b1<32;arith_b1=arith_b1+1)
            if(dut.half565({11'd0,arith_b0[4:0]},{11'd0,arith_b1[4:0]})!==half565_tb({11'd0,arith_b0[4:0]},{11'd0,arith_b1[4:0]}))$fatal(1,"blue half565 mismatch %0d/%0d",arith_b0,arith_b1);
        for(arith_i=0;arith_i<4096;arith_i=arith_i+1)begin
            arith_a=$urandom;arith_b=$urandom;
            if(dut.half565(arith_a,arith_b)!==half565_tb(arith_a,arith_b))$fatal(1,"random half565 mismatch %h/%h",arith_a,arith_b);
        end
        $display("PASS HALF565 exhaustive_channel_pairs=6144 random_rgb565_pairs=4096");
    end
'@
$src=$src.Replace('    integer checks=0,fails=0,half_source_checks=0;', $arith+[Environment]::NewLine+'    integer checks=0,fails=0,half_source_checks=0;')
$sync=@'
    logic sync_hs_oracle=0,sync_vs_oracle=0,sync_de_oracle=0;
    always @(posedge pix_clk)begin if(!pix_rst_n)begin sync_hs_oracle<=0;sync_vs_oracle<=0;sync_de_oracle<=0;end else begin sync_hs_oracle<=dut.hs_q;sync_vs_oracle<=dut.vs_q_out;sync_de_oracle<=dut.de_q;end end
    always @(negedge pix_clk)if(pix_rst_n&&(debug_hs!==sync_hs_oracle||debug_vs!==sync_vs_oracle||debug_de!==sync_de_oracle))$fatal(1,"registered RGB/HS/VS/DE pipeline lost alignment");
'@
$src=$src.Replace('    integer checks=0,fails=0,half_source_checks=0;', $sync+[Environment]::NewLine+'    integer checks=0,fails=0,half_source_checks=0;')
[IO.File]::WriteAllText($tb,$src,[Text.UTF8Encoding]::new($false))
Push-Location $work
try {
    if(!(Test-Path 'work')){& "$tool/vlib.exe" work | Out-Null}
    $files=@((Join-Path $project 'rtl/demo_model_asset_pkg.sv'),(Join-Path $project 'rtl/demo_bus_pkg.sv'),(Join-Path $project 'rtl/demo_axi_merge.sv'),(Join-Path $project 'rtl/display/display_cfg_csr.sv'),(Join-Path $project 'rtl/display/display_renderer.sv'),(Join-Path $project 'rtl/display/display_axi_line_cache.sv'),(Join-Path $project 'rtl/display/display_axi_shared_reader.sv'),(Join-Path $project 'rtl/display/display_ui_catalog_ram.sv'),(Join-Path $project 'rtl/display/pipeline_luna_ui_text_rom.sv'),(Join-Path $project 'rtl/display/pipeline_luna_ui_glyph_rom.sv'),(Join-Path $project 'rtl/display/display_system_top.sv'),(Join-Path $project 'rtl/tmds_encode.v'),(Join-Path $PSScriptRoot 'tb_ui_half_system_cache.sv'),'C:\Efinity\2026.1\sim_models\verilog\efx_ram10.v')
    & "$tool/vlog.exe" -sv -timescale 1ns/1ps -svinputport=net -work work @files *> compile.log
    if($LASTEXITCODE -ne 0){Get-Content compile.log -Tail 100;throw 'system/cache compile failed'}
    $modeArgs=if($ExpectUnderflow){@('-gONE_PASS=1','-gEXPECT_UNDERFLOW=1','-gSTALL_ONCE=1')}else{@('-gONE_PASS=0','-gEXPECT_UNDERFLOW=0','-gSTALL_ONCE=0')}
    & "$tool/vsim.exe" -c work.tb_display_scene "-gTEST_WIDTH=$Width" "-gTEST_HEIGHT=$Height" @modeArgs -gCHECK_DIAGNOSTICS=1 -do 'run -all; quit -f' -l run.log *> console.txt
    $log=Get-Content -Raw run.log
    $expectedPass=if($ExpectUnderflow){'PASS DISPLAY_OVERDEADLINE'}else{'PASS UI_HALF_SYSTEM_CACHE'}
    if($LASTEXITCODE -ne 0 -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch $expectedPass){
        Get-Content run.log -Tail 100
        Get-Content console.txt -Tail 40
        throw 'system/cache integration failed'
    }
    Select-String -Path run.log -Pattern 'PASS |MISMATCH|Error|Fatal' | ForEach-Object {$_.Line}
} finally {Pop-Location}
