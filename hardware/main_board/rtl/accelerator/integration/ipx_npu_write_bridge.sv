// NPU单在途AXI写分流：checkpoint进DDR，最终RGB恒进IPX字流，不存在模式选择。
// 地址范围整个NPU帧保持；credit_load来自IPX的stream_start。
// 一条带只发放一次精确AW拍信用，防止下一条带在旧任务结束前进入FIFO。
// 流式契约：行尾部分拍允许非满WSTRB，有效像素数由IPX按行计数决定，桥本身不解释字节使能。
module ipx_npu_write_bridge(
    input logic clk,reset,credit_load,discard,
    input logic [18:0] credit_words,
    input logic [31:0] rgb_base,rgb_limit,
    input logic [3:0] s_awid,
    input logic [31:0] s_awaddr,
    input logic [7:0] s_awlen,
    input logic [2:0] s_awsize,
    input logic [1:0] s_awburst,
    input logic s_awvalid,
    output logic s_awready,
    input logic [127:0] s_wdata,
    input logic [15:0] s_wstrb,
    input logic s_wlast,s_wvalid,
    output logic s_wready,
    output logic [3:0] s_bid,
    output logic [1:0] s_bresp,
    output logic s_bvalid,
    input logic s_bready,
    output logic [3:0] m_awid,
    output logic [31:0] m_awaddr,
    output logic [7:0] m_awlen,
    output logic [2:0] m_awsize,
    output logic [1:0] m_awburst,
    output logic m_awvalid,
    input logic m_awready,
    output logic [127:0] m_wdata,
    output logic [15:0] m_wstrb,
    output logic m_wlast,m_wvalid,
    input logic m_wready,
    input logic [3:0] m_bid,
    input logic [1:0] m_bresp,
    input logic m_bvalid,
    output logic m_bready,
    output logic [127:0] stream_data,
    output logic stream_valid,
    input logic stream_ready,
    output wire idle // 给配置锁/局部复位使用，不增加状态。
);
    typedef enum logic [2:0] {IDLE,DDR_DATA,DDR_RESP,LOCAL_DATA,LOCAL_RESP} state_t;
    state_t state_q;
    assign idle=state_q==IDLE;
    logic [18:0] credit_q;
    logic [8:0] left_q;
    logic [3:0] id_q;
    logic discarded_q;
    wire local_address=s_awaddr>=rgb_base&&s_awaddr<rgb_limit; // RGB区间恒分流，其余（checkpoint）进DDR。
    wire [8:0] burst_words={1'b0,s_awlen}+9'd1;
    wire aw_take=s_awvalid&&s_awready;
    wire w_take=s_wvalid&&s_wready;
    wire dropping=discard||discarded_q; // 联合中止接受已提出AW，并将整个已接受burst排空。

    always_comb begin
        m_awid=s_awid;m_awaddr=s_awaddr;m_awlen=s_awlen;
        m_awsize=s_awsize;m_awburst=s_awburst;
        m_awvalid=state_q==IDLE&&s_awvalid&&!local_address;
        s_awready=state_q==IDLE&&(local_address?(discard||credit_q>={10'b0,burst_words}):m_awready);
        m_wdata=s_wdata;m_wstrb=s_wstrb;m_wlast=s_wlast;
        m_wvalid=state_q==DDR_DATA&&s_wvalid;
        s_wready=state_q==DDR_DATA?m_wready:state_q==LOCAL_DATA&&(dropping||stream_ready);
        m_bready=state_q==DDR_RESP&&s_bready;
        s_bvalid=state_q==LOCAL_RESP||(state_q==DDR_RESP&&m_bvalid);
        s_bid=state_q==LOCAL_RESP?id_q:m_bid;
        s_bresp=state_q==LOCAL_RESP?(discarded_q?2'b10:2'b00):m_bresp;
        stream_data=s_wdata;
        stream_valid=state_q==LOCAL_DATA&&s_wvalid&&!dropping;
    end
    always_ff @(posedge clk)begin
        if(reset)begin state_q<=IDLE;credit_q<=0;left_q<=0;id_q<=0;discarded_q<=0;end
        else begin
            if(credit_load)credit_q<=credit_words;
            case(state_q)
                IDLE:if(aw_take)begin
                    if(local_address)begin
                        credit_q<=discard?19'd0:credit_q-{10'b0,burst_words};
                        left_q<=burst_words;id_q<=s_awid;discarded_q<=discard;state_q<=LOCAL_DATA;
                    end else state_q<=DDR_DATA;
                end
                DDR_DATA:if(w_take&&s_wlast)state_q<=DDR_RESP;
                DDR_RESP:if(m_bvalid&&s_bready)state_q<=IDLE;
                LOCAL_DATA:if(w_take)begin
                    left_q<=left_q-1'b1;
                    if(discard)discarded_q<=1;
                    if(left_q==1)state_q<=LOCAL_RESP;
                end
                LOCAL_RESP:if(s_bready)state_q<=IDLE;
                default:state_q<=IDLE;
            endcase
        end
    end
`ifdef SIM_ASSERT
    always @(posedge clk)if(!reset)begin
        if(credit_load&&(credit_q!=0||state_q==LOCAL_DATA||state_q==LOCAL_RESP||(aw_take&&local_address)))
            $fatal(1,"Bridge credit reload before drain");
        if(aw_take&&local_address&&(s_awsize!=4||s_awburst!=1))$fatal(1,"Bridge RGB format");
        if(w_take&&state_q==LOCAL_DATA&&(s_wlast!=(left_q==1)||s_wstrb==16'h0000))$fatal(1,"Bridge RGB last/strb"); // 行尾允许部分字节使能。
    end
`endif
endmodule
