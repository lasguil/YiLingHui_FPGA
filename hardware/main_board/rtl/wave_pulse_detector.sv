// Integer occluder sweep matching gesture/try_easy_gesture/wave_detector.py.
// Sequential passes share small arithmetic; explicit SRL8 storage, no RAM/DSP.
module wave_pulse_detector #(parameter MAX_FRAMES_30=15,MAX_FRAMES_60=30)(
    input wire clk,rst_n,enable,frame_start,block_valid,mode_60,
    input wire [5:0] block_index,block_mean,
    output reg event_toggle,left_toggle,event_valid,event_dir,decision_done,
    output wire [1:0] debug_state,output wire [2:0] debug_changed
);
    localparam WAIT_FRAME=0,COLLECT=1,MEAN=2,CENTER=3,THRESHOLD=4,
               CLEAR_FILL=5,MASK=6,DIV_INIT=7,DIVIDE=8,DECIDE=9;
    reg [3:0] state;
    reg have_previous,frame_open;
    reg [6:0] received;
    reg [5:0] index;
    wire accepting=state==COLLECT&&frame_open&&block_valid&&received<64&&block_index==received[5:0];
    wire [2:0] bank=state==COLLECT?block_index[5:3]:index[5:3];
    wire [5:0] previous;
    wire [6:0] work_read;
    wire signed [6:0] difference=$signed({1'b0,block_mean})-$signed({1'b0,previous});
    reg signed [12:0] sum_difference;
    reg signed [6:0] mean_difference;
    wire signed [7:0] centered=$signed({work_read[6],work_read})-$signed({mean_difference[6],mean_difference});
    wire [6:0] magnitude=centered[7]?7'(-centered):centered[6:0];
    wire work_write=accepting||state==CENTER||state==MASK;
    wire [6:0] work_data=state==COLLECT?difference:state==CENTER?magnitude:work_read;
    wave_srl64 #(.WIDTH(6)) prev_memory(.clk(clk),.bank(bank),.write(accepting),.data(block_mean),.q(previous));
    // Reuse the delta memory for magnitude; rotate it during the mask pass.
    wave_srl64 #(.WIDTH(7)) work_memory(.clk(clk),.bank(bank),.write(work_write),.data(work_data),.q(work_read));
    reg [13:0] sum_magnitude;
    wire [15:0] triple_magnitude={2'b0,sum_magnitude}+{1'b0,sum_magnitude,1'b0};
    reg [7:0] threshold;
    wire changed={1'b0,work_read}>threshold;
    wire [3:0] fill_old;
    wire [3:0] fill_new=fill_old+{3'd0,changed};
    genvar b;
    generate for(b=0;b<4;b=b+1)begin: fill_columns
        EFX_SRL8 #(.INIT(8'hff)) fill_chain(.D(state==CLEAR_FILL?1'b1:~fill_new[b]),
            .A(3'd0),.CLK(clk),.CE(state==CLEAR_FILL||state==MASK),.Q(fill_old[b]),.Q7());
    end endgenerate
    reg [6:0] area;
    reg [3:0] maximum_fill;
    reg [8:0] weighted_sum;
    reg [11:0] remainder,divisor;
    reg [5:0] centroid;
    reg [2:0] division_bit;
    wire division_subtract=remainder>=divisor;
    reg active,blocked;
    reg [1:0] gap,cooldown;
    reg [5:0] reference_x;
    reg [6:0] peak_area;
    reg [3:0] peak_fill;
    reg [4:0] episode_frames;
    reg fast_mode;
    wire [4:0] frame_limit=fast_mode?5'(MAX_FRAMES_60):5'(MAX_FRAMES_30);
    wire [6:0] next_peak_area=!active||area>peak_area?area:peak_area;
    wire [3:0] next_peak_fill=!active||maximum_fill>peak_fill?maximum_fill:peak_fill;
    wire next_blocked=active&&(blocked||episode_frames>=frame_limit);
    wire [1:0] cooled=cooldown==0?2'd0:cooldown-1'b1;
    wire signed [6:0] displacement=active?$signed({1'b0,centroid})-$signed({1'b0,reference_x}):7'sd0;
    wire sweep=displacement>=7'sd36||displacement<=-7'sd36;
    assign debug_state=blocked?2'd3:active?2'd2:have_previous?2'd1:2'd0;
    assign debug_changed={maximum_fill>=5,area>=13,sweep};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=WAIT_FRAME;have_previous<=0;frame_open<=0;received<=0;index<=0;
            sum_difference<=0;mean_difference<=0;sum_magnitude<=0;threshold<=4;
            area<=0;maximum_fill<=0;weighted_sum<=0;remainder<=0;divisor<=0;centroid<=0;division_bit<=0;
            active<=0;blocked<=0;gap<=0;cooldown<=0;reference_x<=0;peak_area<=0;peak_fill<=0;episode_frames<=0;fast_mode<=0;
            event_toggle<=0;left_toggle<=0;event_valid<=0;event_dir<=0;decision_done<=0;
        end else begin
            event_valid<=0;decision_done<=0;
            if(!enable)begin
                state<=WAIT_FRAME;have_previous<=0;frame_open<=0;received<=0;
                active<=0;blocked<=0;gap<=0;cooldown<=0;episode_frames<=0;
            end else if(frame_start)begin
                if(frame_open||!(state==WAIT_FRAME||state==COLLECT))begin
                    have_previous<=0;active<=0;blocked<=0;gap<=0;cooldown<=0;
                end
                frame_open<=1;received<=0;sum_difference<=0;state<=COLLECT;fast_mode<=mode_60;
            end else case(state)
                COLLECT:if(block_valid)begin
                    if(!accepting)begin
                        have_previous<=0;frame_open<=0;active<=0;blocked<=0;gap<=0;cooldown<=0;state<=WAIT_FRAME;
                    end else begin
                        sum_difference<=sum_difference+{{6{difference[6]}},difference};received<=received+1'b1;
                        if(block_index==63)begin
                            frame_open<=0;
                            if(have_previous)state<=MEAN;
                            else begin have_previous<=1;state<=WAIT_FRAME;decision_done<=1;end
                        end
                    end
                end
                MEAN:begin mean_difference<=sum_difference>>>6;sum_magnitude<=0;index<=0;state<=CENTER;end
                CENTER:begin
                    sum_magnitude<=sum_magnitude+{7'd0,magnitude};
                    if(index==63)state<=THRESHOLD;else index<=index+1'b1;
                end
                THRESHOLD:begin
                    threshold<=(triple_magnitude>>7)<4?8'd4:8'(triple_magnitude>>7);
                    index<=0;area<=0;maximum_fill<=0;weighted_sum<=0;state<=CLEAR_FILL;
                end
                CLEAR_FILL:if(index==7)begin index<=0;state<=MASK;end else index<=index+1'b1;
                MASK:begin
                    if(changed)begin area<=area+1'b1;weighted_sum<=weighted_sum+{6'd0,index[2:0]};end
                    if(fill_new>maximum_fill)maximum_fill<=fill_new;
                    if(index==63)state<=DIV_INIT;else index<=index+1'b1;
                end
                DIV_INIT:begin
                    centroid<=0;
                    if(area<2)state<=DECIDE;
                    else begin remainder<={weighted_sum,3'd0}+{6'd0,area[6:1]};divisor<={area,5'd0};division_bit<=5;state<=DIVIDE;end
                end
                DIVIDE:begin
                    if(division_subtract)remainder<=remainder-divisor;
                    centroid[division_bit]<=division_subtract;divisor<=divisor>>1;
                    if(division_bit==0)state<=DECIDE;else division_bit<=division_bit-1'b1;
                end
                DECIDE:begin
                    decision_done<=1;state<=WAIT_FRAME;cooldown<=cooled;
                    if(area<2)begin
                        if(gap!=3)gap<=gap+1'b1;
                        if(gap>=2)begin active<=0;blocked<=0;end
                    end else begin
                        gap<=0;active<=1;blocked<=next_blocked;peak_area<=next_peak_area;peak_fill<=next_peak_fill;
                        if(!active)begin reference_x<=centroid;episode_frames<=0;end
                        else if(episode_frames!=31)episode_frames<=episode_frames+1'b1;
                        // Reference decrements refractory BEFORE the frame test.
                        if(!next_blocked&&sweep&&next_peak_area>=13&&next_peak_fill>=5&&cooled==0)begin
                            event_valid<=1;event_dir<=!displacement[6];
                            if(displacement[6])left_toggle<=~left_toggle;else event_toggle<=~event_toggle;
                            cooldown<=3;reference_x<=centroid;peak_area<=area;peak_fill<=maximum_fill;episode_frames<=0;
                        end
                    end
                end
                default:state<=WAIT_FRAME;
            endcase
        end
    end
endmodule

// Eight row FIFOs: read oldest, then shift. Raster passes replace/rotate rows.
module wave_srl64 #(parameter WIDTH=6)(
    input wire clk,input wire [2:0] bank,input wire write,
    input wire [WIDTH-1:0] data,output wire [WIDTH-1:0] q
);
    wire [WIDTH-1:0] rows[0:7];
    genvar r,b;
    generate for(r=0;r<8;r=r+1)begin: row_bank
        for(b=0;b<WIDTH;b=b+1)begin: lane
            EFX_SRL8 #(.INIT(8'hff)) memory(.D(~data[b]),.A(3'd0),.CLK(clk),
                .CE(write&&bank==r),.Q(rows[r][b]),.Q7());
        end
    end endgenerate
    assign q=rows[bank];
endmodule
