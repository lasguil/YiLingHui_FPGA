// 协议契约：固定signed INT8 logits域6/127，输出UINT8像素；不随风格重载。
// 常量来自quant/mem_rq16/sigmoid_u8.hex的128项半表，负码按255减正码恢复。
// 使用常量case译码，禁止依赖initial/readmemh在Efinity中初始化ROM；不占RAM10或DSP。
// 输入有效沿取码，下一周期out_valid/out_bytes；无有效周期输出字节不得消费。
// INIT_FILE仅保留旧例化参数兼容，实际表固定；修改量化域必须同步生成器与常量表。
module ngm_sigmoid_lut #( // 固定模型RGB末级。
    parameter int unsigned LANE_COUNT=5, // 每拍查五个码。
    parameter [1023:0] INIT_FILE="sigmoid_u8.hex" // 兼容已有行引擎参数。
)( // 接口开始。
    input logic clk,reset,in_valid, // 时钟、同步复位与码有效。
    input logic [LANE_COUNT*8-1:0] in_codes, // 逐车道signed INT8码。
    output logic out_valid, // 返回有效延迟一拍。
    output logic [LANE_COUNT*8-1:0] out_bytes // UINT8像素字节。
); // 接口结束。
    function automatic logic [7:0] half_lookup(input logic [6:0] address); // 纯常量半表。
        case(address) // 直接译码，全部128地址有定义。
            7'd0:half_lookup=8'h80; // 非负码0的像素值。
            7'd1:half_lookup=8'h83; // 非负码1的像素值。
            7'd2:half_lookup=8'h86; // 非负码2的像素值。
            7'd3:half_lookup=8'h89; // 非负码3的像素值。
            7'd4:half_lookup=8'h8c; // 非负码4的像素值。
            7'd5:half_lookup=8'h8e; // 非负码5的像素值。
            7'd6:half_lookup=8'h91; // 非负码6的像素值。
            7'd7:half_lookup=8'h94; // 非负码7的像素值。
            7'd8:half_lookup=8'h97; // 非负码8的像素值。
            7'd9:half_lookup=8'h9a; // 非负码9的像素值。
            7'd10:half_lookup=8'h9d; // 非负码10的像素值。
            7'd11:half_lookup=8'ha0; // 非负码11的像素值。
            7'd12:half_lookup=8'ha3; // 非负码12的像素值。
            7'd13:half_lookup=8'ha5; // 非负码13的像素值。
            7'd14:half_lookup=8'ha8; // 非负码14的像素值。
            7'd15:half_lookup=8'hab; // 非负码15的像素值。
            7'd16:half_lookup=8'hae; // 非负码16的像素值。
            7'd17:half_lookup=8'hb0; // 非负码17的像素值。
            7'd18:half_lookup=8'hb3; // 非负码18的像素值。
            7'd19:half_lookup=8'hb5; // 非负码19的像素值。
            7'd20:half_lookup=8'hb8; // 非负码20的像素值。
            7'd21:half_lookup=8'hba; // 非负码21的像素值。
            7'd22:half_lookup=8'hbc; // 非负码22的像素值。
            7'd23:half_lookup=8'hbf; // 非负码23的像素值。
            7'd24:half_lookup=8'hc1; // 非负码24的像素值。
            7'd25:half_lookup=8'hc3; // 非负码25的像素值。
            7'd26:half_lookup=8'hc5; // 非负码26的像素值。
            7'd27:half_lookup=8'hc7; // 非负码27的像素值。
            7'd28:half_lookup=8'hc9; // 非负码28的像素值。
            7'd29:half_lookup=8'hcb; // 非负码29的像素值。
            7'd30:half_lookup=8'hcd; // 非负码30的像素值。
            7'd31:half_lookup=8'hcf; // 非负码31的像素值。
            7'd32:half_lookup=8'hd1; // 非负码32的像素值。
            7'd33:half_lookup=8'hd3; // 非负码33的像素值。
            7'd34:half_lookup=8'hd4; // 非负码34的像素值。
            7'd35:half_lookup=8'hd6; // 非负码35的像素值。
            7'd36:half_lookup=8'hd8; // 非负码36的像素值。
            7'd37:half_lookup=8'hd9; // 非负码37的像素值。
            7'd38:half_lookup=8'hdb; // 非负码38的像素值。
            7'd39:half_lookup=8'hdc; // 非负码39的像素值。
            7'd40:half_lookup=8'hde; // 非负码40的像素值。
            7'd41:half_lookup=8'hdf; // 非负码41的像素值。
            7'd42:half_lookup=8'he0; // 非负码42的像素值。
            7'd43:half_lookup=8'he1; // 非负码43的像素值。
            7'd44:half_lookup=8'he3; // 非负码44的像素值。
            7'd45:half_lookup=8'he4; // 非负码45的像素值。
            7'd46:half_lookup=8'he5; // 非负码46的像素值。
            7'd47:half_lookup=8'he6; // 非负码47的像素值。
            7'd48:half_lookup=8'he7; // 非负码48的像素值。
            7'd49:half_lookup=8'he8; // 非负码49的像素值。
            7'd50:half_lookup=8'he9; // 非负码50的像素值。
            7'd51:half_lookup=8'hea; // 非负码51的像素值。
            7'd52:half_lookup=8'heb; // 非负码52的像素值。
            7'd53:half_lookup=8'hec; // 非负码53的像素值。
            7'd54:half_lookup=8'hed; // 非负码54的像素值。
            7'd55:half_lookup=8'hed; // 非负码55的像素值。
            7'd56:half_lookup=8'hee; // 非负码56的像素值。
            7'd57:half_lookup=8'hef; // 非负码57的像素值。
            7'd58:half_lookup=8'hf0; // 非负码58的像素值。
            7'd59:half_lookup=8'hf0; // 非负码59的像素值。
            7'd60:half_lookup=8'hf1; // 非负码60的像素值。
            7'd61:half_lookup=8'hf1; // 非负码61的像素值。
            7'd62:half_lookup=8'hf2; // 非负码62的像素值。
            7'd63:half_lookup=8'hf3; // 非负码63的像素值。
            7'd64:half_lookup=8'hf3; // 非负码64的像素值。
            7'd65:half_lookup=8'hf4; // 非负码65的像素值。
            7'd66:half_lookup=8'hf4; // 非负码66的像素值。
            7'd67:half_lookup=8'hf5; // 非负码67的像素值。
            7'd68:half_lookup=8'hf5; // 非负码68的像素值。
            7'd69:half_lookup=8'hf6; // 非负码69的像素值。
            7'd70:half_lookup=8'hf6; // 非负码70的像素值。
            7'd71:half_lookup=8'hf6; // 非负码71的像素值。
            7'd72:half_lookup=8'hf7; // 非负码72的像素值。
            7'd73:half_lookup=8'hf7; // 非负码73的像素值。
            7'd74:half_lookup=8'hf7; // 非负码74的像素值。
            7'd75:half_lookup=8'hf8; // 非负码75的像素值。
            7'd76:half_lookup=8'hf8; // 非负码76的像素值。
            7'd77:half_lookup=8'hf8; // 非负码77的像素值。
            7'd78:half_lookup=8'hf9; // 非负码78的像素值。
            7'd79:half_lookup=8'hf9; // 非负码79的像素值。
            7'd80:half_lookup=8'hf9; // 非负码80的像素值。
            7'd81:half_lookup=8'hfa; // 非负码81的像素值。
            7'd82:half_lookup=8'hfa; // 非负码82的像素值。
            7'd83:half_lookup=8'hfa; // 非负码83的像素值。
            7'd84:half_lookup=8'hfa; // 非负码84的像素值。
            7'd85:half_lookup=8'hfa; // 非负码85的像素值。
            7'd86:half_lookup=8'hfb; // 非负码86的像素值。
            7'd87:half_lookup=8'hfb; // 非负码87的像素值。
            7'd88:half_lookup=8'hfb; // 非负码88的像素值。
            7'd89:half_lookup=8'hfb; // 非负码89的像素值。
            7'd90:half_lookup=8'hfb; // 非负码90的像素值。
            7'd91:half_lookup=8'hfc; // 非负码91的像素值。
            7'd92:half_lookup=8'hfc; // 非负码92的像素值。
            7'd93:half_lookup=8'hfc; // 非负码93的像素值。
            7'd94:half_lookup=8'hfc; // 非负码94的像素值。
            7'd95:half_lookup=8'hfc; // 非负码95的像素值。
            7'd96:half_lookup=8'hfc; // 非负码96的像素值。
            7'd97:half_lookup=8'hfc; // 非负码97的像素值。
            7'd98:half_lookup=8'hfd; // 非负码98的像素值。
            7'd99:half_lookup=8'hfd; // 非负码99的像素值。
            7'd100:half_lookup=8'hfd; // 非负码100的像素值。
            7'd101:half_lookup=8'hfd; // 非负码101的像素值。
            7'd102:half_lookup=8'hfd; // 非负码102的像素值。
            7'd103:half_lookup=8'hfd; // 非负码103的像素值。
            7'd104:half_lookup=8'hfd; // 非负码104的像素值。
            7'd105:half_lookup=8'hfd; // 非负码105的像素值。
            7'd106:half_lookup=8'hfd; // 非负码106的像素值。
            7'd107:half_lookup=8'hfd; // 非负码107的像素值。
            7'd108:half_lookup=8'hfd; // 非负码108的像素值。
            7'd109:half_lookup=8'hfe; // 非负码109的像素值。
            7'd110:half_lookup=8'hfe; // 非负码110的像素值。
            7'd111:half_lookup=8'hfe; // 非负码111的像素值。
            7'd112:half_lookup=8'hfe; // 非负码112的像素值。
            7'd113:half_lookup=8'hfe; // 非负码113的像素值。
            7'd114:half_lookup=8'hfe; // 非负码114的像素值。
            7'd115:half_lookup=8'hfe; // 非负码115的像素值。
            7'd116:half_lookup=8'hfe; // 非负码116的像素值。
            7'd117:half_lookup=8'hfe; // 非负码117的像素值。
            7'd118:half_lookup=8'hfe; // 非负码118的像素值。
            7'd119:half_lookup=8'hfe; // 非负码119的像素值。
            7'd120:half_lookup=8'hfe; // 非负码120的像素值。
            7'd121:half_lookup=8'hfe; // 非负码121的像素值。
            7'd122:half_lookup=8'hfe; // 非负码122的像素值。
            7'd123:half_lookup=8'hfe; // 非负码123的像素值。
            7'd124:half_lookup=8'hfe; // 非负码124的像素值。
            7'd125:half_lookup=8'hfe; // 非负码125的像素值。
            7'd126:half_lookup=8'hfe; // 非负码126的像素值。
            7'd127:half_lookup=8'hfe; // 非负码127的像素值。
        endcase // 常量表结束。
    endfunction // 译码函数结束。
    for(genvar lane=0;lane<LANE_COUNT;lane++)begin:g_lane // 五路独立组合查表。
        wire [7:0] code=in_codes[lane*8+:8]; // 当前车道码。
        wire [6:0] magnitude=code[7] ? (~code[6:0]+7'd1) : code[6:0]; // 绝对值，-128为非法输入域。
        always_ff @(posedge clk)out_bytes[lane*8+:8]<=half_lookup(magnitude)^{8{code[7]}}; // 对称恢复且只寄存一次。
    end // 独立车道结束。
    always_ff @(posedge clk)if(reset)out_valid<=0;else out_valid<=in_valid; // 只复位有效位。
endmodule // 固定sigmoid结束。
