// 协议契约：每口CLKE=0原生保持；同址双写禁止；读写同址语义以器件原语为准，上层不调度这种访问。
module ngm_d_dual128_ram( // 两组各十三块RAM10，位宽130中只使用128。
    input logic clk, // 同步工作时钟。
    input wire [1:0] en[2],we[2], // 两组各A/B端口使能与读写选择。
    input wire [9:0] addr[2][2], // 1024深度寻址。
    input wire [127:0] din[2][2], // 原生128位写。
    output wire [127:0] dout[2][2] // 四个独立128位返回。
); // 接口结束。
    for(genvar g=0;g<2;g++)begin:g_group // 两组物理容量独立。
        wire [129:0] a,b;wire [129:0] wa={2'b0,din[g][0]},wb={2'b0,din[g][1]}; // 第十三块两位空闲。
        for(genvar k=0;k<13;k++)begin:g_block // 每块双口都为10位。
            EFX_DPRAM10 #(.READ_WIDTH_A(10),.WRITE_WIDTH_A(10),.READ_WIDTH_B(10),.WRITE_WIDTH_B(10),.OUTPUT_REG_A(0),.OUTPUT_REG_B(0),.WRITE_MODE_A("READ_FIRST"),.WRITE_MODE_B("READ_FIRST")) u_ram( // 显式真双口原语，不靠推断。
                .CLKA(clk),.WEA(we[g][0]),.CLKEA(en[g][0]),.RSTA(1'b0),.ADDRENA(1'b1),.WDATAA(wa[k*10+:10]),.ADDRA(addr[g][0]),.RDATAA(a[k*10+:10]), // A口固定。
                .CLKB(clk),.WEB(we[g][1]),.CLKEB(en[g][1]),.RSTB(1'b0),.ADDRENB(1'b1),.WDATAB(wb[k*10+:10]),.ADDRB(addr[g][1]),.RDATAB(b[k*10+:10]) // B口固定。
            ); // 原语结束。
        end // 十三块结束。
        assign dout[g][0]=a[127:0];assign dout[g][1]=b[127:0]; // 回程仅常量拼接。
    end // 两组结束。
endmodule // 真双口RAM封装结束。
