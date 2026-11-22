// NPU/IPX之间的分流配置。busy时地址锁定，仅允许置/撤discard。
// 三个RW字：CONTROL(00)、RGB_BASE(08)、RGB_LIMIT(0c)。04状态，10版本。
// CONTROL bit0中止丢弃，bit1空闲时桥局部复位脉冲；分流本身无使能位，RGB区间恒进字流。
module style_link_regs(
    input wire csr_valid,csr_write,
    input wire [11:0] csr_address,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output logic csr_ready,csr_error,
    output wire [31:0] csr_rdata,
    input wire clk,reset,n_busy,p_busy,bridge_idle,
    output logic discard,bridge_clear,
    output logic [31:0] rgb_base,rgb_limit
);
    logic write_bad,read_known;
    logic [31:0] read_value;
    wire locked=n_busy||p_busy||!bridge_idle;
    wire write_fire=csr_valid && csr_write && !csr_ready;
    assign csr_rdata=read_value;
    always_comb begin
        write_bad=csr_address[1:0]!=0;
        case(csr_address)
            12'h000:if(csr_wstrb[0])write_bad=write_bad||csr_wdata[7:2]!=0||
                (locked&&csr_wdata[1]); // discard可随时置位，桥局部复位只在静止时允许。
            12'h008,12'h00c:write_bad=write_bad||locked;
            default:write_bad=1;
        endcase
        read_known=csr_address[1:0]==0;
        read_value=0;
        read_value=            ({32{csr_address==12'h000}} & ({30'b0,discard})) |
            ({32{csr_address==12'h004}} & ({28'b0,p_busy,n_busy,bridge_idle,locked})) |
            ({32{csr_address==12'h008}} & (rgb_base)) |
            ({32{csr_address==12'h00c}} & (rgb_limit)) |
            ({32{csr_address==12'h010}} & (32'h53545002));
        read_known=(csr_address==12'h000 || csr_address==12'h004 || csr_address==12'h008 || csr_address==12'h00c || csr_address==12'h010);
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            csr_ready<=0;csr_error<=0;
            discard<=0;bridge_clear<=0;rgb_base<=0;rgb_limit<=0;
        end else begin
            csr_ready<=0;
            if(csr_valid && !csr_ready)begin csr_ready<=1;csr_error<=csr_write ? write_bad : !read_known;end
            bridge_clear<=0;
            if(write_fire)begin
                if(!write_bad)case(csr_address)
                    12'h000:if(csr_wstrb[0])begin discard<=csr_wdata[0];bridge_clear<=csr_wdata[1];end
                    12'h008:for(int b=0;b<4;b++)if(csr_wstrb[b])rgb_base[b*8+:8]<=csr_wdata[b*8+:8];
                    12'h00c:for(int b=0;b<4;b++)if(csr_wstrb[b])rgb_limit[b*8+:8]<=csr_wdata[b*8+:8];
                    default:begin end
                endcase
            end
        end
    end
endmodule
