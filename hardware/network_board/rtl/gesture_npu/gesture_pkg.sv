// gesture_pkg —— 手势关键点加速器的全局参数。
//
// 算力切分（推导见 docs/架构设计.md §3）：
//   16 颗 EFX_DSP48 全做 MAC，DUAL 模式下每颗 = 2 条独立 int8 通道 ⇒ 32 lane / 拍。
//   重量化另用 4 条 LUT 车道（32/9 = 3.6 出/拍是深度卷积的吞吐下限，4 条够）。
//   实测总周期 ≈ 4.87 M，@150 MHz 约 32.5 ms（30 fps）。
//
// 累加器用织物侧 32 位：DSP 只出乘积，两条轨道各自符号扩展后相加。
// 代价约 2100 XLR，换来任意输入分布下都不回绕——7×7 阶段的去偏置峰值实测
// 2^19.5，理论最坏 2^24，赌 24 位不溢出不值得。
package gesture_pkg;

    // ---- MAC 阵列 ----
    localparam int MAC_DSP   = 16;              // EFX_DSP48 实例数
    localparam int LANES     = MAC_DSP * 2;     // int8 MAC 通道数
    localparam int ACT_W     = 8;
    localparam int WGT_W     = 8;
    localparam int ACC_W     = 32;

    // ---- 重量化 ----
    // y = clamp8( rne( ((p * m18) >> (post-10)) + B_fixed , 10 ) + zp )
    localparam int RQ_LANES  = 4;
    localparam int M18_W     = 17;              // 尾数归一化到 [2^16, 2^17)
    localparam int POST_W    = 6;               // post_shift ∈ [14, 51]
    localparam int POST_MIN  = 14;
    localparam int POST_MAX  = 51;
    localparam int BFIX_W    = 32;              // B_fixed 实测 27 位有符号
    localparam int BSHIFT    = 10;              // B_fixed 的定点小数位
    localparam int CODE_W    = 8;

    // 重量化中间量位宽：32 位累加器 × 17 位尾数
    localparam int PROD_W    = ACC_W + M18_W;           // 49
    localparam int TOT_W     = PROD_W + BFIX_W + 1;     // 82，仅用于溢出判定

    // ---- 每通道参数表记录（打包顺序，与 tools/extract_model.py 一致）----
    //   [pre_shift:u16][m18:u24][post_shift:u8]  然后 co 字节 zero point
    localparam int PARAM_REC_B  = 6;
    localparam int ZP_REC_B     = 1;

endpackage
