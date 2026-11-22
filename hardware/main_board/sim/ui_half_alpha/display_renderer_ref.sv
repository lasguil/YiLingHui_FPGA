// Fixed, single-font product UI compositor. All UI pixels are overlays; there
// is no UI framebuffer or additional DDR reader.
module display_renderer_ref (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [11:0] x, y,
    input  logic        in_hs, in_vs, in_de,
    input  logic [1:0]  scene_mode,
    input  logic [11:0] source_width, source_height, source_x, source_y,
    input  logic [11:0] dest_x, dest_y, dest_width, dest_height,
    input  logic [31:0] x_step, y_step,
    input  logic [11:0] wipe_x,
    input  logic        ui_enable,
    input  logic [11:0] fps_bcd,
    input  logic        status_ok,
    input  logic [31:0] ui_data,
    input  logic [10:0] ui_hint,
    input  logic [16:0] ui_metrics,
    input  logic [95:0] ui_values,
    input  logic [2:0]  ui_live_state,
    input  logic [7:0]  ui_catalog_data,
    output logic [demo_model_asset_pkg::MODEL_CATALOG_ADDR_WIDTH-1:0] ui_catalog_addr,
    output logic        ui_catalog_re,
    input  logic [3:0]  diagnostics_status,
    output logic [11:0] src_a_x, src_a_y, src_b_x, src_b_y, next_source_y,
    output logic        src_a_req, src_b_req,
    output logic        out_hs, out_vs, out_de,
    output logic [15:0] out_rgb565
);
    localparam integer UI_MSG_ID_WIDTH=7, UI_MSG_COUNT=80, UI_TAG_WIDTH=6, UI_TAG_MAX=34;
    localparam [UI_MSG_ID_WIDTH-1:0] MSG_BRAND=0, MSG_INPUT0=1, MSG_INPUT1=2, MSG_INPUT2=3,
        MSG_INPUT3=4, MSG_LIVE=5, MSG_PAUSED=6, MSG_FPS=7, MSG_LT=8, MSG_GT=9,
        MSG_STYLE=10, MSG_MODEL=11, MSG_COLOR=12, MSG_CURVE=13, MSG_GRAY=14,
        MSG_DUOTONE=15, MSG_COLORDOT=16, MSG_TABLE=17, MSG_IDENTITY=18,
        MSG_WARM=19, MSG_ADJUST=20, MSG_AI=21, MSG_FX=22, MSG_SAT=23,
        MSG_KEEP=24, MSG_BASIC=25, MSG_RANGE=26, MSG_OUTSAT=27, MSG_RESET=28,
        MSG_RGB=29, MSG_RMIN=30, MSG_RMAX=31, MSG_GMIN=32, MSG_GMAX=33,
        MSG_BMIN=34, MSG_BMAX=35, MSG_LIMITS=36, MSG_SAT_UNUSED=37,
        MSG_KEEP_OVERRIDE=38, MSG_MODE_UNUSED=39, MSG_PENDING=40, MSG_PAUSED_LAST=41,
        MSG_PAUSED_PENDING=42, MSG_VIEW=43, MSG_ORIGINAL=44, MSG_RESULT=45,
        MSG_WIPE=46, MSG_SIDE=47, MSG_PAUSE=48, MSG_RESUME=49, MSG_CLEAN=50,
        MSG_HIDE=51, MSG_SHOW=52, MSG_AI_FX=53, MSG_COUNT1=54, MSG_COUNT2=55,
        MSG_RED=56, MSG_WARM_RANGE=57, MSG_GREEN=58, MSG_BLUE=59, MSG_CUSTOM=60, MSG_FPS_LABEL=61,
        MSG_CLOSE=62, MSG_KEEP_OFF=63, MSG_KEEP_ON=64, MSG_RANGE_RED=65, MSG_RANGE_WARM=66,
        MSG_RANGE_GREEN=67, MSG_RANGE_BLUE=68, MSG_RANGE_CUSTOM=69, MSG_HOLD=70,
        MSG_START=71, MSG_WIPE_HANDLE=72, MSG_EDIT_RANGE=73, MSG_BACK=74, MSG_ERROR=75,
        MSG_WIPE_CUE=76, MSG_BRAND_SUB=77, MSG_MINUS=78, MSG_PLUS=79;

    logic [1:0] mode_q;
    logic [11:0] source_width_q,source_height_q,source_x_q,source_y_q;
    logic [11:0] dest_x_q,dest_y_q,dest_width_q,dest_height_q,wipe_x_q;
    logic [31:0] x_step_q,y_step_q,x_acc_q,y_acc_q,map_y_acc,next_map_y_acc;
    logic [31:0] y_next_acc_q,y_two_next_acc_q;
    logic [12:0] map_x_ext,map_y_ext,source_x_end,source_y_end;
    logic [12:0] dest_x_end_q,dest_y_end_q,split_x_q;
    logic [11:0] wipe_end_q;
    logic [12:0] scene_width;
    logic inside_scene,choose_a,choose_b,map_in_bounds,split_mark;
    logic ui_overlay,ui_menu,ui_button,ui_button_border,ui_selected,ui_disabled,ui_font_zone;
    logic [15:0] panel_color,ink_color;

    localparam [UI_TAG_WIDTH-1:0] TAG_NONE=0,TAG_HEADER=1,TAG_FOOT_TITLE=2,TAG_FOOT_SUB=3,
        TAG_MENU_TITLE=4,TAG_COLOR0=5,TAG_COLOR1=6,TAG_COLOR2=7,TAG_COLOR3=8,
        TAG_TABLE_LABEL=9,TAG_TABLE_PICK=10,TAG_TABLE_COUNT=11,TAG_COLOR_FX=12,
        TAG_ADJUST_TAB=13,TAG_BASIC_AI=14,TAG_BASIC_FX=15,TAG_BASIC_SAT=16,
        TAG_BASIC_RESET=17,TAG_KEEP_ON=18,TAG_KEEP_RANGE=19,TAG_KEEP_OUTSAT=20,
        TAG_KEEP_EDIT=21,TAG_RGB0=22,TAG_RGB1=23,TAG_RGB2=24,TAG_RGB3=25,
        TAG_RGB4=26,TAG_RGB5=27,TAG_MENU_FOOT=28,TAG_PAUSE_NOTE=29,TAG_CLEAN=30,TAG_WIPE_HANDLE=31,
        TAG_RGB_BACK=32,TAG_WIPE_CUE=33,TAG_PAUSE_WIPE=34;
    logic [UI_TAG_WIDTH-1:0] line_tag,line_tag_next;
    logic [11:0] line_origin_y,line_origin_y_next;
    logic [2:0] font_row_q;
    logic [UI_MSG_ID_WIDTH-1:0] font_msg,fetch_msg,text_msg_q;
    logic [4:0] font_index,fetch_index,text_index_q,font_len;
    logic [11:0] font_origin,font_x;
    logic text_rd_en,text_valid_q,glyph_valid_q;
    logic [2:0] fetch_value_slot,text_value_slot_q;
    logic [4:0] fetch_dyn_start,text_dyn_start_q;
    logic [7:0] text_data,glyph_char;
    logic font_catalog,fetch_catalog,text_catalog_q;
    logic ui_param_row;
    logic [11:0] ui_param_top;
    logic [6:0] ui_param_height;
    wire ui_param_button=ui_menu&&ui_param_row&&((x>=1704&&x<1768)||(x>=1784&&x<1848));
    logic [11:0] text_addr;
    logic [4:0] glyph_data,glyph_bits_q;
    logic [8:0] glyph_addr;
    logic font_active,font_pixel;
    logic [11:0] y_step_end;
    wire frame_start=in_de&&(x==12'd0)&&(y==12'd0);
    wire line_start=in_de&&(x==12'd0);

    always_comb begin
        ui_param_row=0;ui_param_top=0;ui_param_height=0;
        if(ui_menu)case(ui_data[2:0])
            1:if(y>=752&&y<820)begin ui_param_row=1;ui_param_top=752;ui_param_height=68;end
            2:begin
                if(y>=320&&y<388)begin ui_param_row=1;ui_param_top=320;ui_param_height=68;end
                else if(y>=416&&y<484)begin ui_param_row=1;ui_param_top=416;ui_param_height=68;end
                else if(y>=512&&y<580)begin ui_param_row=1;ui_param_top=512;ui_param_height=68;end
            end
            3:if(y>=512&&y<580)begin ui_param_row=1;ui_param_top=512;ui_param_height=68;end
            4:begin
                if(y>=220&&y<284)begin ui_param_row=1;ui_param_top=220;ui_param_height=64;end
                else if(y>=300&&y<364)begin ui_param_row=1;ui_param_top=300;ui_param_height=64;end
                else if(y>=380&&y<444)begin ui_param_row=1;ui_param_top=380;ui_param_height=64;end
                else if(y>=460&&y<524)begin ui_param_row=1;ui_param_top=460;ui_param_height=64;end
                else if(y>=540&&y<604)begin ui_param_row=1;ui_param_top=540;ui_param_height=64;end
                else if(y>=620&&y<684)begin ui_param_row=1;ui_param_top=620;ui_param_height=64;end
            end
            default:;
        endcase
    end

    generate
        if ((UI_MSG_COUNT>(1<<UI_MSG_ID_WIDTH)) || (UI_TAG_MAX>=(1<<UI_TAG_WIDTH)) ||
            (MSG_WIPE_CUE>=UI_MSG_COUNT) || (TAG_WIPE_CUE>UI_TAG_MAX)) begin : g_ui_id_range_error
            initial $fatal(1,"UI message/tag range does not fit its declared width");
        end
    endgenerate

    assign mode_q=scene_mode;
    assign source_width_q=source_width; assign source_height_q=source_height;
    assign source_x_q=source_x; assign source_y_q=source_y;
    assign dest_x_q=dest_x; assign dest_y_q=dest_y;
    assign dest_width_q=dest_width; assign dest_height_q=dest_height;
    assign wipe_x_q=wipe_x; assign x_step_q=x_step; assign y_step_q=y_step;

    // Source mapping and overlay exclusion retain the accepted reader geometry.
    always_comb begin
        scene_width=(mode_q==2'd3)?{1'b0,dest_width_q[11:1]}:{1'b0,dest_width_q};
        inside_scene=(dest_width_q!=0)&&(dest_height_q!=0)&&(x>=dest_x_q)&&
            ({1'b0,x}<dest_x_end_q)&&(y>=dest_y_q)&&({1'b0,y}<dest_y_end_q);
        split_mark=(mode_q==2'd2)&&(x>=wipe_x_q)&&(x<wipe_end_q);
        map_x_ext={1'b0,source_x_q};
        if(!(x==12'd0||(mode_q==2'd3&&x==split_x_q)) ) map_x_ext={1'b0,source_x_q}+{1'b0,x_acc_q[27:16]};
        map_y_acc=y_acc_q;
        if(x==12'd0&&y==dest_y_q)map_y_acc=0;
        else if(x==12'd0&&y>dest_y_q&&y<dest_y_end_q[11:0])map_y_acc=y_next_acc_q;
        map_y_ext={1'b0,source_y_q}+{1'b0,map_y_acc[27:16]};
        next_map_y_acc=y_next_acc_q;
        if(x==12'd0&&y==dest_y_q)next_map_y_acc=y_step_q;
        else if(x==12'd0&&y>dest_y_q&&y<dest_y_end_q[11:0])next_map_y_acc=y_two_next_acc_q;
        next_source_y=source_y_q+next_map_y_acc[27:16];
        map_in_bounds=(map_x_ext<source_x_end)&&(map_y_ext<source_y_end);
        choose_a=0;choose_b=0;
        case(mode_q)
            2'd0:choose_a=inside_scene;
            2'd1:choose_b=inside_scene;
            2'd2:begin choose_a=inside_scene&&(x<wipe_x_q);choose_b=inside_scene&&(x>=wipe_x_q);end
            2'd3:begin choose_a=inside_scene&&({1'b0,x}<({1'b0,dest_x_q}+scene_width));
                choose_b=inside_scene&&({1'b0,x}>=({1'b0,dest_x_q}+scene_width));end
        endcase
        ui_menu=ui_data[2:0]!=0;
        ui_overlay=(ui_enable&&((y<12'd88)||(y>=12'd952)))||(ui_menu&&(x>=12'd1328)&&(x<12'd1872)&&
            (y>=12'd112)&&(y<12'd928))||(!ui_enable&&(x>=12'd1632)&&(x<12'd1896)&&
            (y>=12'd984)&&(y<12'd1056))||(ui_enable&&ui_data[22]&&(x>=12'd24)&&(x<12'd536)&&
            (y>=12'd872)&&(y<12'd920))||(ui_enable&&!ui_menu&&(ui_data[26:25]==2)&&
            (wipe_x_q>=48)&&(wipe_x_q<1872)&&(x>=wipe_x_q-12'd48)&&(x<wipe_x_q+12'd48)&&
            (y>=12'd486)&&(y<12'd558))||(ui_enable&&!ui_menu&&(ui_data[26:25]==2)&&
            (y>=12'd868)&&(y<12'd916)&&(x>=12'd704)&&(x<12'd1216));
        src_a_req=choose_a&&map_in_bounds&&!ui_overlay&&!split_mark;
        src_b_req=choose_b&&map_in_bounds&&!ui_overlay&&!split_mark;
        src_a_x=map_x_ext[11:0];src_b_x=map_x_ext[11:0];
        src_a_y=map_y_ext[11:0];src_b_y=map_y_ext[11:0];
    end

    // Pick only a compact row tag at x=0; message and glyph selection happen
    // from this registered tag, ahead of the text pixels on that scanline.
    always_comb begin
        line_tag_next=TAG_NONE;line_origin_y_next=0;
        if(!ui_enable&&(y>=1009)&&(y<1030))begin line_tag_next=TAG_CLEAN;line_origin_y_next=1009;end
        else if(ui_enable)begin
            if((y>=34)&&(y<55))begin line_tag_next=TAG_HEADER;line_origin_y_next=34;end
            else if((y>=987)&&(y<1008))begin line_tag_next=TAG_FOOT_TITLE;line_origin_y_next=987;end
            else if((y>=1019)&&(y<1040))begin line_tag_next=TAG_FOOT_SUB;line_origin_y_next=1019;end
            else if(ui_menu)begin
                if((y>=140)&&(y<167))begin line_tag_next=TAG_MENU_TITLE;line_origin_y_next=140;end
                else if(ui_data[2:0]==1)begin
                    if((y>=253)&&(y<274))begin line_tag_next=TAG_COLOR0;line_origin_y_next=253;end
                    else if((y>=337)&&(y<358))begin line_tag_next=TAG_COLOR1;line_origin_y_next=337;end
                    else if((y>=421)&&(y<442))begin line_tag_next=TAG_COLOR2;line_origin_y_next=421;end
                    else if((y>=505)&&(y<526))begin line_tag_next=TAG_COLOR3;line_origin_y_next=505;end
                    else if((y>=578)&&(y<599))begin line_tag_next=TAG_TABLE_LABEL;line_origin_y_next=578;end
                    else if((y>=637)&&(y<658))begin line_tag_next=TAG_TABLE_PICK;line_origin_y_next=637;end
                    else if((y>=704)&&(y<725))begin line_tag_next=TAG_TABLE_COUNT;line_origin_y_next=704;end
                    else if((y>=776)&&(y<797))begin line_tag_next=TAG_COLOR_FX;line_origin_y_next=776;end
                end else if((ui_data[2:0]==2)||(ui_data[2:0]==3))begin
                    if((y>=241)&&(y<262))begin line_tag_next=TAG_ADJUST_TAB;line_origin_y_next=241;end
                    else if((y>=344)&&(y<365))begin line_tag_next=(ui_data[2:0]==2)?TAG_BASIC_AI:TAG_KEEP_ON;line_origin_y_next=344;end
                    else if((y>=440)&&(y<461))begin line_tag_next=(ui_data[2:0]==2)?TAG_BASIC_FX:TAG_KEEP_RANGE;line_origin_y_next=440;end
                    else if((y>=536)&&(y<557))begin line_tag_next=(ui_data[2:0]==2)?TAG_BASIC_SAT:TAG_KEEP_OUTSAT;line_origin_y_next=536;end
                    else if((y>=681)&&(y<702))begin line_tag_next=(ui_data[2:0]==2)?TAG_BASIC_RESET:TAG_KEEP_EDIT;line_origin_y_next=681;end
                    else if((y>=850)&&(y<871))begin line_tag_next=TAG_MENU_FOOT;line_origin_y_next=850;end
                end else if(ui_data[2:0]==4)begin
                    if((y>=244)&&(y<265))begin line_tag_next=TAG_RGB0;line_origin_y_next=244;end
                    else if((y>=324)&&(y<345))begin line_tag_next=TAG_RGB1;line_origin_y_next=324;end
                    else if((y>=404)&&(y<425))begin line_tag_next=TAG_RGB2;line_origin_y_next=404;end
                    else if((y>=484)&&(y<505))begin line_tag_next=TAG_RGB3;line_origin_y_next=484;end
                    else if((y>=564)&&(y<585))begin line_tag_next=TAG_RGB4;line_origin_y_next=564;end
                    else if((y>=644)&&(y<665))begin line_tag_next=TAG_RGB5;line_origin_y_next=644;end
                    else if((y>=753)&&(y<774))begin line_tag_next=TAG_RGB_BACK;line_origin_y_next=753;end
                    else if((y>=850)&&(y<871))begin line_tag_next=TAG_MENU_FOOT;line_origin_y_next=850;end
                end
            end else if(ui_enable&&ui_data[22]&&(ui_data[26:25]==2)&&(y>=882)&&(y<904))begin line_tag_next=TAG_PAUSE_WIPE;line_origin_y_next=882;end
            else if(ui_enable&&ui_data[22]&&(y>=886)&&(y<907))begin line_tag_next=TAG_PAUSE_NOTE;line_origin_y_next=886;end
            else if(ui_enable&&!ui_menu&&(ui_data[26:25]==2)&&(y>=882)&&(y<903))begin line_tag_next=TAG_WIPE_CUE;line_origin_y_next=882;end
            else if(ui_enable&&!ui_menu&&(ui_data[26:25]==2)&&(y>=507)&&(y<528)&&
                (wipe_x_q>=48)&&(wipe_x_q<1872))begin line_tag_next=TAG_WIPE_HANDLE;line_origin_y_next=507;end
        end
    end
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin line_tag<=TAG_NONE;line_origin_y<=0;end
        else if(in_vs)begin line_tag<=TAG_NONE;line_origin_y<=0;end
        else if(line_start)begin line_tag<=line_tag_next;line_origin_y<=line_origin_y_next;end
    end
    logic [11:0] font_y_origin;
    always_comb begin
        font_y_origin=line_origin_y;
        if((line_tag==TAG_PAUSE_WIPE)&&(x<12'd600))font_y_origin=12'd886;
        if((line_tag==TAG_MENU_TITLE)&&(x>=12'd1806)&&(x<12'd1825))font_y_origin=12'd146;
        font_row_q=(y>=font_y_origin)?3'((y-font_y_origin)/12'd3):3'd0;
    end

    function automatic [4:0] message_length(input logic [UI_MSG_ID_WIDTH-1:0] id);
        begin case(id)
            MSG_BRAND:message_length=9; MSG_INPUT0:message_length=13; MSG_INPUT1:message_length=12;
            MSG_INPUT2:message_length=12; MSG_INPUT3:message_length=12; MSG_LIVE:message_length=4;
            MSG_PAUSED:message_length=6; MSG_FPS:message_length=4; MSG_FPS_LABEL:message_length=3; MSG_LT,MSG_GT:message_length=1;
            MSG_STYLE:message_length=5; MSG_MODEL:message_length=8; MSG_COLOR:message_length=5;
            MSG_CURVE:message_length=9; MSG_GRAY:message_length=12; MSG_DUOTONE:message_length=11;
            MSG_COLORDOT:message_length=9; MSG_TABLE:message_length=11; MSG_IDENTITY:message_length=8;
            MSG_WARM:message_length=4; MSG_ADJUST:message_length=6; MSG_AI,MSG_FX,MSG_SAT:message_length=19;
            MSG_KEEP:message_length=10; MSG_BASIC:message_length=5; MSG_RANGE:message_length=5;
            MSG_OUTSAT:message_length=20; MSG_RESET:message_length=12; MSG_RGB:message_length=9;
            MSG_RMIN,MSG_RMAX,MSG_GMIN,MSG_GMAX,MSG_BMIN,MSG_BMAX:message_length=19;
            MSG_LIMITS:message_length=19; MSG_SAT_UNUSED:message_length=25;
            MSG_KEEP_OVERRIDE:message_length=24; MSG_MODE_UNUSED:message_length=26;
            MSG_PENDING:message_length=20; MSG_PAUSED_LAST:message_length=19;
            MSG_PAUSED_PENDING:message_length=24; MSG_VIEW:message_length=4;
            MSG_ORIGINAL:message_length=8; MSG_RESULT:message_length=6; MSG_WIPE:message_length=4;
            MSG_SIDE:message_length=12; MSG_PAUSE:message_length=5; MSG_RESUME:message_length=6;
            MSG_CLEAN:message_length=5; MSG_HIDE:message_length=10; MSG_SHOW:message_length=10;
            MSG_AI_FX:message_length=16; MSG_COUNT1,MSG_COUNT2:message_length=5;
            MSG_RED:message_length=3;MSG_WARM_RANGE:message_length=4;MSG_GREEN:message_length=5;
            MSG_BLUE:message_length=4;MSG_CUSTOM:message_length=6;MSG_CLOSE:message_length=1;
            MSG_KEEP_OFF:message_length=9;MSG_KEEP_ON:message_length=8;MSG_RANGE_RED:message_length=12;
            MSG_RANGE_WARM:message_length=13;MSG_RANGE_GREEN:message_length=14;MSG_RANGE_BLUE:message_length=13;
            MSG_RANGE_CUSTOM:message_length=15;MSG_HOLD:message_length=15;MSG_START:message_length=13;
            MSG_WIPE_HANDLE:message_length=3;MSG_EDIT_RANGE:message_length=16;MSG_BACK:message_length=4; MSG_ERROR:message_length=5;MSG_WIPE_CUE:message_length=15;MSG_BRAND_SUB:message_length=11;
            MSG_MINUS,MSG_PLUS:message_length=1;default:message_length=0;
        endcase end
    endfunction
    function automatic [7:0] digit_char(input logic [3:0] digit);
        begin digit_char=(digit<=9)?(8'h30+{4'd0,digit}):8'h20;end
    endfunction
    function automatic [7:0] bcd_char(input logic [95:0] values,input logic [2:0] slot,input logic [1:0] digit);
        logic [3:0] nibble;
        begin nibble=values[(slot*12)+((2-digit)*4)+:4]; bcd_char=digit_char(nibble);end
    endfunction

    // Segment decoder for one shared text/glyph port. Each line uses a compact
    // tag; the x-segment selects a string only during its own cell range.
    always_comb begin
        font_msg=0;font_origin=0;font_index=0;font_len=0;font_x=0;
        font_active=0;ui_font_zone=0;fetch_value_slot=3'd0;fetch_dyn_start=5'd0;font_catalog=0;
        if(ui_param_button)begin
            if(x<1776)begin font_msg=MSG_MINUS;font_origin=1728;end
            else begin font_msg=MSG_PLUS;font_origin=1808;end
            ui_font_zone=1;
        end else case(line_tag)
            TAG_HEADER:begin
                if(x>=21&&x<24+9*16)begin font_msg=MSG_BRAND;font_origin=24;ui_font_zone=1;end
                else if(x>=197&&x<200+11*16)begin font_msg=MSG_BRAND_SUB;font_origin=200;ui_font_zone=1;end
                else if((ui_data[24:23]==0)&&(x>=1262&&x<1265+13*16))begin
                    font_msg=MSG_INPUT0;font_origin=1265;ui_font_zone=1;
                end else if((ui_data[24:23]!=0)&&(x>=1270&&x<1273+12*16))begin
                    case(ui_data[24:23])1:font_msg=MSG_INPUT1;2:font_msg=MSG_INPUT2;default:font_msg=MSG_INPUT3;endcase
                    font_origin=1273;ui_font_zone=1;
                end else if(x>=1597&&x<1600+6*16)begin if(ui_live_state==3'd5)font_msg=MSG_ERROR;else font_msg=ui_data[22]?MSG_PAUSED:MSG_LIVE;font_origin=1600;ui_font_zone=1;end
                else if(x>=1765&&x<1768+4*16)begin font_msg=MSG_FPS;font_origin=1768;ui_font_zone=1;end
                else if(x>=1845&&x<1848+3*16)begin font_msg=MSG_FPS_LABEL;font_origin=1848;ui_font_zone=1;end
            end
            TAG_FOOT_TITLE:begin
                if(x>=38&&x<41+1*16)begin font_msg=MSG_LT;font_origin=41;ui_font_zone=1;end
                else if(x>=93&&x<96+5*16)begin font_msg=MSG_STYLE;font_origin=96;ui_font_zone=1;end
                else if(x>=290&&x<293+1*16)begin font_msg=MSG_GT;font_origin=293;ui_font_zone=1;end
                else if(x>=353&&x<356+5*16)begin font_msg=MSG_COLOR;font_origin=356;ui_font_zone=1;end
                else if(x>=669&&x<672+6*16)begin font_msg=MSG_ADJUST;font_origin=672;ui_font_zone=1;end
                else if(x>=985&&x<988+4*16)begin font_msg=MSG_VIEW;font_origin=988;ui_font_zone=1;end
                else if(x>=1301&&x<1304+6*16)begin font_msg=ui_data[22]?MSG_RESUME:MSG_PAUSE;font_origin=1304;ui_font_zone=1;end
                else if(x>=1597&&x<1600+5*16)begin font_msg=MSG_CLEAN;font_origin=1600;ui_font_zone=1;end
            end
            TAG_FOOT_SUB:begin
                if(x>=93&&x<96+10*16)begin font_msg=MSG_MODEL;font_origin=96;ui_font_zone=1;font_catalog=1;end
                else if(x>=353&&x<356+12*16)begin
                    case(ui_data[4:3])0:font_msg=MSG_CURVE;1:font_msg=MSG_GRAY;2:font_msg=MSG_DUOTONE;default:font_msg=MSG_COLORDOT;endcase
                    font_origin=356;ui_font_zone=1;
                end else if(x>=669&&x<672+16*16)begin font_msg=MSG_AI_FX;font_origin=672;ui_font_zone=1;fetch_value_slot=3'd6;fetch_dyn_start=5'd3;end
                else if(x>=985&&x<988+12*16)begin
                    case(ui_data[26:25])0:font_msg=MSG_ORIGINAL;1:font_msg=MSG_RESULT;2:font_msg=MSG_WIPE;default:font_msg=MSG_SIDE;endcase
                    font_origin=988;ui_font_zone=1;
                end else if(x>=1301&&x<1304+15*16)begin font_msg=ui_data[22]?MSG_START:MSG_HOLD;font_origin=1304;ui_font_zone=1;end
                else if(x>=1597&&x<1600+10*16)begin font_msg=MSG_HIDE;font_origin=1600;ui_font_zone=1;end
            end
            TAG_MENU_TITLE:begin
                if(x>=1349&&x<1352+12*16)begin font_msg=ui_data[2:0]==1?MSG_COLOR:(ui_data[2:0]==4?MSG_RGB:MSG_ADJUST);font_origin=1352;ui_font_zone=1;end
                else if(x>=1806&&x<1809+1*16)begin font_msg=MSG_CLOSE;font_origin=1809;ui_font_zone=1;end
            end
            TAG_COLOR0,TAG_COLOR1,TAG_COLOR2,TAG_COLOR3:begin
                case(line_tag)TAG_COLOR0:font_msg=MSG_CURVE;TAG_COLOR1:font_msg=MSG_GRAY;TAG_COLOR2:font_msg=MSG_DUOTONE;default:font_msg=MSG_COLORDOT;endcase
                font_origin=1352;ui_font_zone=1;
            end
            TAG_TABLE_LABEL:begin font_msg=MSG_TABLE;font_origin=1352;ui_font_zone=1;end
            TAG_TABLE_PICK:begin
                if(x>=1373&&x<1376+1*16)begin font_msg=MSG_LT;font_origin=1376;ui_font_zone=1;end
                else if(x>=1477&&x<1480+16*16)begin font_msg=MSG_IDENTITY;font_origin=1480;ui_font_zone=1;font_catalog=1;end
                else if(x>=1805&&x<1808+1*16)begin font_msg=MSG_GT;font_origin=1808;ui_font_zone=1;end
            end
            TAG_TABLE_COUNT:begin font_msg=ui_data[13:11]==0?MSG_COUNT1:MSG_COUNT2;font_origin=1544;ui_font_zone=1;end
            TAG_COLOR_FX:begin
                font_msg=MSG_FX;font_origin=1352;ui_font_zone=1;fetch_value_slot=3'd0;fetch_dyn_start=5'd15;
            end
            TAG_ADJUST_TAB:begin
                if(x>=1365&&x<1368+5*16)begin font_msg=MSG_BASIC;font_origin=1368;ui_font_zone=1;end
                else if(x>=1621&&x<1624+10*16)begin font_msg=MSG_KEEP;font_origin=1624;ui_font_zone=1;end
            end
            TAG_BASIC_AI:begin font_msg=MSG_AI;font_origin=1352;ui_font_zone=1;fetch_value_slot=3'd0;fetch_dyn_start=5'd15;end
            TAG_BASIC_FX:begin font_msg=MSG_FX;font_origin=1352;ui_font_zone=1;fetch_value_slot=3'd1;fetch_dyn_start=5'd15;end
            TAG_BASIC_SAT:begin font_msg=MSG_SAT;font_origin=1352;ui_font_zone=1;fetch_value_slot=3'd2;fetch_dyn_start=5'd15;end
            TAG_BASIC_RESET:begin font_msg=MSG_RESET;font_origin=1352;ui_font_zone=1;end
            TAG_KEEP_ON:begin font_msg=ui_data[17]?MSG_KEEP_ON:MSG_KEEP_OFF;font_origin=1352;ui_font_zone=1;end
            TAG_KEEP_RANGE:begin
                case(ui_data[20:18])0:font_msg=MSG_RANGE_RED;1:font_msg=MSG_RANGE_WARM;2:font_msg=MSG_RANGE_GREEN;3:font_msg=MSG_RANGE_BLUE;default:font_msg=MSG_RANGE_CUSTOM;endcase
                font_origin=1352;ui_font_zone=1;
            end
            TAG_KEEP_OUTSAT:begin font_msg=MSG_OUTSAT;font_origin=1352;ui_font_zone=1;fetch_value_slot=3'd0;fetch_dyn_start=5'd16;end
            TAG_KEEP_EDIT:begin font_msg=MSG_EDIT_RANGE;font_origin=1352;ui_font_zone=1;end
            TAG_RGB0,TAG_RGB1,TAG_RGB2,TAG_RGB3,TAG_RGB4,TAG_RGB5:begin
                case(line_tag)TAG_RGB0:font_msg=MSG_RMIN;TAG_RGB1:font_msg=MSG_RMAX;TAG_RGB2:font_msg=MSG_GMIN;
                    TAG_RGB3:font_msg=MSG_GMAX;TAG_RGB4:font_msg=MSG_BMIN;default:font_msg=MSG_BMAX;endcase
                font_origin=1352;ui_font_zone=1;fetch_value_slot=3'(line_tag-TAG_RGB0);fetch_dyn_start=5'd16;
            end
            TAG_MENU_FOOT:begin
                if(ui_data[2:0]==2)begin
                    if((ui_data[4:3]==1)||(ui_data[4:3]==2))font_msg=MSG_SAT_UNUSED;
                    else if(ui_data[17])font_msg=MSG_KEEP_OVERRIDE;
                    else if(ui_data[21])font_msg=MSG_PENDING;
                    else font_msg=0;
                end else if(ui_data[2:0]==3)font_msg=(ui_data[4:3]==1||ui_data[4:3]==2)?MSG_MODE_UNUSED:0;
                else font_msg=MSG_LIMITS;
                font_origin=1352;ui_font_zone=(font_msg!=0);
            end
            TAG_PAUSE_NOTE:begin font_msg=ui_data[21]?MSG_PAUSED_PENDING:MSG_PAUSED_LAST;font_origin=40;ui_font_zone=1;end
            TAG_PAUSE_WIPE:begin
                if(x<12'd600)begin
                    if(x>=37&&x<40+24*16)begin font_msg=ui_data[21]?MSG_PAUSED_PENDING:MSG_PAUSED_LAST;font_origin=40;ui_font_zone=1;end
                end else if(x>=837&&x<840+15*16)begin font_msg=MSG_WIPE_CUE;font_origin=840;ui_font_zone=1;end
            end
            TAG_CLEAN:begin font_msg=MSG_SHOW;font_origin=1728;ui_font_zone=1;end
            TAG_WIPE_HANDLE:begin font_msg=MSG_WIPE_HANDLE;font_origin=wipe_x_q-12'd24;ui_font_zone=1;end
            TAG_WIPE_CUE:begin font_msg=MSG_WIPE_CUE;font_origin=840;ui_font_zone=1;end
            TAG_RGB_BACK:begin font_msg=MSG_BACK;font_origin=1376;ui_font_zone=1;end
            default:;
        endcase
        font_len=font_catalog ? 5'd16 : message_length(font_msg);
        if(ui_font_zone)begin
            if(x>=font_origin)font_x=x-font_origin;else font_x=0;
            if((x>=font_origin)&&(x<font_origin+font_len*16)&&(y>=font_y_origin)&&(y<font_y_origin+21))begin
                font_active=1; font_index=font_x[8:4];
            end
        end
        fetch_msg=font_msg;fetch_index=font_index;fetch_catalog=font_catalog;
        text_rd_en=0;
        if(ui_font_zone&&(font_len!=0))begin
            if(x==font_origin-3)begin text_rd_en=1;fetch_index=0;end
            else if(font_active&&(font_x[3:0]==4'd12)&&(font_index+1<font_len))begin
                text_rd_en=1;fetch_index=font_index+1'b1;
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin text_valid_q<=0;glyph_valid_q<=0;text_msg_q<=0;text_index_q<=0;text_catalog_q<=0;
            text_value_slot_q<=0;text_dyn_start_q<=0;glyph_bits_q<=0;end
        else begin
            text_valid_q<=text_rd_en;glyph_valid_q<=text_valid_q;
            if(text_rd_en)begin text_msg_q<=fetch_msg;text_index_q<=fetch_index;
                text_value_slot_q<=fetch_value_slot;text_dyn_start_q<=fetch_dyn_start;text_catalog_q<=fetch_catalog;end
            if(glyph_valid_q)glyph_bits_q<=glyph_data;
        end
    end
    assign text_addr={font_msg[UI_MSG_ID_WIDTH-1:0],fetch_index};
    always_comb begin
        glyph_char=text_data;
        if(text_catalog_q)glyph_char=ui_catalog_data;
        if((text_msg_q==MSG_AI||text_msg_q==MSG_FX||text_msg_q==MSG_SAT)&&text_index_q>=15&&text_index_q<=17)
            glyph_char=bcd_char(ui_values,text_value_slot_q,text_index_q-15);
        else if(text_msg_q==MSG_OUTSAT&&text_index_q>=16&&text_index_q<=18)
            glyph_char=bcd_char(ui_values,text_value_slot_q,text_index_q-16);
        else if(text_msg_q>=MSG_RMIN&&text_msg_q<=MSG_BMAX&&text_index_q>=16&&text_index_q<=18)
            glyph_char=bcd_char(ui_values,text_value_slot_q,text_index_q-16);
        else if(text_msg_q==MSG_AI_FX&&text_index_q>=3&&text_index_q<=5)
            glyph_char=bcd_char(ui_values,3'd6,text_index_q-3);
        else if(text_msg_q==MSG_AI_FX&&text_index_q>=12&&text_index_q<=14)
            glyph_char=bcd_char(ui_values,3'd7,text_index_q-12);
        else if(text_msg_q==MSG_FPS&&text_index_q==0)glyph_char=ui_metrics[16]?digit_char(ui_metrics[11:8]):"-";
        else if(text_msg_q==MSG_FPS&&text_index_q==1)glyph_char=ui_metrics[16]?digit_char(ui_metrics[7:4]):"-";
        else if(text_msg_q==MSG_FPS&&text_index_q==3)glyph_char=ui_metrics[16]?digit_char(ui_metrics[3:0]):"-";
        else if((text_msg_q==MSG_COUNT1||text_msg_q==MSG_COUNT2)&&text_index_q==0)
            glyph_char=digit_char({1'b0,ui_data[13:11]}+4'd1);
        else if((text_msg_q==MSG_COUNT1||text_msg_q==MSG_COUNT2)&&text_index_q==4)
            glyph_char=digit_char({1'b0,ui_data[16:14]}+4'd1);
    end
    always_comb begin
        ui_catalog_addr=0;
        if(line_tag==TAG_FOOT_SUB)
            ui_catalog_addr={1'b0,ui_data[demo_model_asset_pkg::MODEL_CATALOG_MODEL_INDEX_HIGH_BIT],
                ui_data[7:5],4'b0000}+fetch_index;
        else if(line_tag==TAG_TABLE_PICK)
            ui_catalog_addr=demo_model_asset_pkg::MODEL_CATALOG_TABLE_BASE+
                {2'b00,ui_data[13:11],4'b0000}+fetch_index;
        ui_catalog_re=text_rd_en&&font_catalog;
    end
    assign glyph_addr={font_row_q,glyph_char[5:0]};
    pipeline_luna_ui_text_rom u_ui_text_rom(.clk,.re(text_rd_en),.addr(text_addr),.data(text_data));
    pipeline_luna_ui_glyph_rom u_ui_glyph_rom(.clk,.re(text_valid_q),.addr(glyph_addr),.data(glyph_data));
    always_comb begin
        font_pixel=0;
        if(font_active&&(font_x[3:0]<15)&&(font_row_q<7))
            font_pixel=glyph_bits_q[4-(font_x[3:0]/3)];
    end

    // Fixed rectangles mirror the tested web mockup. Only the menu/selection
    // state changes; all labels share the single ROM read path above.
    always_comb begin
        ui_button=0;ui_selected=0;ui_disabled=0;
        if(ui_enable)begin
            if((y>=970)&&(y<1058))begin
                if((x>=24&&x<72)||(x>=80&&x<268)||(x>=276&&x<324)||
                   (x>=340&&x<640)||(x>=656&&x<956)||(x>=972&&x<1272)||
                   (x>=1288&&x<1568)||(x>=1584&&x<1896))ui_button=1;
                if((x>=340&&x<640)&&(ui_data[2:0]==1))ui_selected=1;
                if((x>=656&&x<956)&&((ui_data[2:0]==2)||(ui_data[2:0]==3)||(ui_data[2:0]==4)))ui_selected=1;
                if((x>=1288&&x<1568)&&ui_data[22])ui_selected=1;
            end
            if((x>=1216&&x<1520)&&(y>=16&&y<72))ui_button=1;
            if(ui_menu&&(x>=1328)&&(x<1872)&&(y>=112)&&(y<928))begin
                if(x>=1784&&x<1848&&y>=128&&y<184)ui_button=1;
                if((x>=1352)&&(x<1848))begin
                    if(ui_data[2:0]==1)begin
                        if(y>=228&&y<552)ui_button=1;
                        if((y>=228&&y<300&&ui_data[4:3]==0)||(y>=312&&y<384&&ui_data[4:3]==1)||
                           (y>=396&&y<468&&ui_data[4:3]==2)||(y>=480&&y<552&&ui_data[4:3]==3))ui_selected=1;
                        if((y>=614&&y<682)&&(x<1416||x>=1784))ui_button=1;
                        if(y>=752&&y<820)ui_button=1;
                    end else if(ui_data[2:0]==2||ui_data[2:0]==3)begin
                        if(y>=220&&y<284)ui_button=1;
                        if(ui_data[2:0]==3&&((y>=320&&y<388)||(y>=416&&y<484)))ui_button=1;
                        if(((ui_data[2:0]==2&&(y>=320&&y<388||y>=416&&y<484||y>=512&&y<580))||
                            (ui_data[2:0]==3&&y>=512&&y<580))&&
                           ((x>=1704&&x<1768)||(x>=1784&&x<1848)))ui_button=1;
                        if(y>=660&&y<732)ui_button=1;
                        if((y>=220&&y<284)&&((x<1592&&ui_data[2:0]==2)||(x>=1608&&ui_data[2:0]==3)))ui_selected=1;
                    end else if(ui_data[2:0]==4)begin
                        if(((y>=220&&y<284)||(y>=300&&y<364)||(y>=380&&y<444)||
                            (y>=460&&y<524)||(y>=540&&y<604)||(y>=620&&y<684))&&
                           ((x>=1704&&x<1768)||(x>=1784&&x<1848)))ui_button=1;
                        if(y>=732&&y<804)ui_button=1;
                    end
                end
                if(ui_data[2:0]==2&&(y>=512&&y<580)&&(ui_data[4:3]==1||ui_data[4:3]==2||ui_data[17]))ui_disabled=1;
                if(ui_data[2:0]==3&&(ui_data[4:3]==1||ui_data[4:3]==2)&&(y>=320&&y<732))ui_disabled=1;
                if(ui_data[2:0]==3&&(y>=512&&y<580)&&!ui_data[17])ui_disabled=1;
            end
        end else if(x>=1632&&x<1896&&y>=984&&y<1056)ui_button=1;
        if(ui_enable&&!ui_menu&&ui_data[26:25]==2&&wipe_x_q>=48&&wipe_x_q<1872&&
           x>=wipe_x_q-48&&x<wipe_x_q+48&&y>=486&&y<558)ui_button=1;
        ui_button_border=0;
        if(ui_param_button&&((x==1704||x==1705||x==1766||x==1767||x==1784||x==1785||x==1846||x==1847)||
           (y==ui_param_top)||(y==ui_param_top+1)||
           (y==ui_param_top+ui_param_height-2)||(y==ui_param_top+ui_param_height-1)))begin
            ui_button_border=1;
        end
        if(ui_button&&ui_selected)panel_color=16'h29C5;else if(ui_button)panel_color=16'h1944;else panel_color=16'h1103;
        if(ui_button_border)panel_color=16'h4B09;
        if(ui_enable&&!ui_menu&&ui_data[26:25]==2&&wipe_x_q>=48&&wipe_x_q<1872&&
           y>=486&&y<558&&x>=wipe_x_q-48&&x<wipe_x_q+48&&
           (x==wipe_x_q-48||x==wipe_x_q+47||y==486||y==557))panel_color=16'hE60F;
        ink_color=16'hF75B;
        if(ui_selected)ink_color=16'hE60F;
        if(ui_disabled)ink_color=16'h740D;
        out_hs=in_hs;out_vs=in_vs;out_de=in_de;
        if(!rst_n||!in_de)out_rgb565=16'h0000;
        else if(ui_overlay)begin
            if(ui_button)out_rgb565=font_pixel?ink_color:panel_color;
            else if(font_pixel)out_rgb565=ink_color;
            else out_rgb565=panel_color;
            if(ui_menu&&(x>=1328)&&(x<1872)&&(y>=112)&&(y<928)&&
               (x==1328||x==1871||y==112||y==927))out_rgb565=16'h4B09;
            if(ui_enable&&y>=952&&y<954)out_rgb565=16'h4B09;
            if(ui_enable&&y<88&&y>=86)out_rgb565=16'h4B09;
        end else if(split_mark)out_rgb565=16'hFFFF;
        else out_rgb565=16'h0000;
    end

    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin source_x_end<=0;source_y_end<=0;dest_x_end_q<=0;dest_y_end_q<=0;
            split_x_q<=0;wipe_end_q<=0;end
        else if(in_vs)begin
            source_x_end<={1'b0,source_x}+{1'b0,source_width};
            source_y_end<={1'b0,source_y}+{1'b0,source_height};
            dest_x_end_q<={1'b0,dest_x}+{1'b0,dest_width};
            dest_y_end_q<={1'b0,dest_y}+{1'b0,dest_height};
            split_x_q<={1'b0,dest_x}+((scene_mode==3)?{2'b0,dest_width[11:1]}:{1'b0,dest_width});
            wipe_end_q<=wipe_x+12'd2;
        end
    end
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin x_acc_q<=0;y_acc_q<=0;y_next_acc_q<=0;y_two_next_acc_q<=0;end
        else begin
            if(in_vs)begin x_acc_q<=0;y_acc_q<=0;end
            else if(frame_start)begin x_acc_q<=(dest_x_q==0&&inside_scene)?x_step_q:32'd0;y_acc_q<=0;end
            else if(line_start)begin
                x_acc_q<=(dest_x_q==0&&inside_scene)?x_step_q:32'd0;
                if(y==dest_y_q)y_acc_q<=0;
                else if(y>dest_y_q&&y<dest_y_end_q[11:0])y_acc_q<=y_acc_q+y_step_q;
            end else if(inside_scene)begin
                if(mode_q==2'd3&&x==split_x_q)x_acc_q<=x_step_q;
                else x_acc_q<=x_acc_q+x_step_q;
            end
            y_next_acc_q<=y_acc_q+y_step_q;y_two_next_acc_q<=y_next_acc_q+y_step_q;
        end
    end
endmodule





