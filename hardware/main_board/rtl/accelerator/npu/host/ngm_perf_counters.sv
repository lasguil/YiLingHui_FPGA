// 协议契约：仅统计控制事件，不参与数据背压；clear优先，用于软件显式开始新的测量区间。
// busy_cycles包含计算、DMA等待及重载，计数按32位自然回绕；整帧性能须另用帧开始/结束时间差验收。
module ngm_perf_counters( // 最小可读性能计数。
    input logic clk,reset,clear,busy,frame_done,frame_aborted,model_done,task_error, // 时钟、清零、占用和单拍事件。
    output logic [31:0] busy_cycles,frames,aborts,models,errors // 五项软件可读计数。
); // 接口结束。
    always_ff @(posedge clk)begin // 无宽数据存储。
        if(reset || clear)begin busy_cycles<=0;frames<=0;aborts<=0;models<=0;errors<=0;end // 显式复位测量。
        else begin // 独立事件可同拍发生。
            if(busy)busy_cycles<=busy_cycles+1'b1; // 包含真实等待。
            if(frame_done)frames<=frames+1'b1; // 只计成功帧。
            if(frame_aborted)aborts<=aborts+1'b1; // 丢弃帧独立计数。
            if(model_done)models<=models+1'b1; // 成功切换。
            if(task_error)errors<=errors+1'b1; // 失败事件。
        end // 正常统计结束。
    end // 计数寄存器结束。
endmodule // 性能计数结束。
