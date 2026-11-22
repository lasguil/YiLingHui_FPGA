#ifndef STYLE_PIPELINE_H
#define STYLE_PIPELINE_H
#include <stdint.h>
#include "ipx_regs.h"

/* Three control MMIO windows map to n_s_axi, p_s_axi and link_s_axi.
 * Current RISC-V reaches these through an APB-to-AXI-Lite control adapter;
 * the CPU does not become a DDR AXI master. The system adapter is separate.
 * Streaming-only: the NPU RGB output never lands in DDR; npu_rgb is only the
 * address window the bridge classifies, so callers keep the range reserved. */
enum sp_npu_reg {
    SP_N_COMMAND=0x00, SP_N_STATUS=0x04, SP_N_EVENTS=0x08, SP_N_IRQ=0x0c,
    SP_N_SIZE=0x10, SP_N_INPUT=0x14, SP_N_OUTPUT=0x18, SP_N_X0=0x1c,
    SP_N_INPUT_STRIDE=0x20, SP_N_OUTPUT_STRIDE=0x24, SP_N_X0_STRIDE=0x28,
    SP_N_MODEL=0x2c
};
enum sp_link_reg { SP_L_CONTROL=0, SP_L_STATUS=4, SP_L_RGB_BASE=8, SP_L_RGB_LIMIT=12, SP_L_VERSION=16 };
enum sp_result { SP_PENDING=0, SP_DONE=1, SP_ABORTED=2, SP_BUSY=-1, SP_INVALID=-2, SP_HW_ERROR=-3 };
enum sp_state { SP_IDLE, SP_MODEL, SP_FRAME, SP_ABORTING, SP_FAULT };
#define SP_MODEL_BYTES UINT32_C(12800) /* Fixed ngm_weight_dma master package length. */
#define SP_480_VISIBLE_WIDTH 854u
#define SP_480_PROCESS_WIDTH 856u
#define SP_480_RGB_STRIDE 1728u /* 864 pixels, including row alignment space. */
#define SP_480_X0_STRIDE 6848u /* 214 C32 points. */
#define SP_STRIP_PIXELS 480u /* One strip is 120 X0 columns at four RGB pixels each. */
#define SP_SEAM_PIXELS 8u /* RGB layer computes two extra groups per internal seam (2 X0 columns). */

struct sp_frame {
    /* original/final: little endian RGB565, 2 bytes/pixel.
     * Bits 15:11 R, 10:5 G, 4:0 B. rgb_stride is bytes including padding.
     * npu_rgb is the classification window for the NPU RGB stage; the bridge
     * turns every write inside it into stream words, no DDR traffic occurs.
     * X0/model retain their own tensor/package formats. */
    uint32_t original, npu_rgb, final, x0;
    uint16_t width, height, rgb_stride, x0_stride; /* width/height are VISIBLE. */
};
struct sp_context {
    volatile uint32_t *npu, *ipx, *link;
    struct sp_frame frame;
    enum sp_state state; /* Initialize to SP_IDLE; mappings remain valid. */
    uint16_t x;
    uint8_t n_finished, p_finished;
};

/* A single scheduling task owns this context; IRQ handlers notify that task.
 * The DDR producer publishes source/model buffers before submit; the display
 * consumer takes ownership only after DONE. CPU pixel access is not required.
 * Effect/LUT updates happen only while this full-frame context is idle.
 * poll advances one task boundary; caller owns watchdog timing and IRQ dispatch. */
int sp_request_model(struct sp_context *ctx, uint32_t model_base);
int sp_submit(struct sp_context *ctx, const struct sp_frame *frame);
int sp_poll(struct sp_context *ctx);
int sp_abort(struct sp_context *ctx);
/* Source is a stable caller-owned 768-byte buffer at aligned DDR address 0x01000000..0x01fffd00;
 * IPX DMA reads it. The caller must keep the bytes unchanged until this bounded call returns. */
int sp_load_color_table(struct sp_context *ctx, uint32_t ddr_address);
/* Built-ins are generated one public byte at a time through the manual CSR protocol. */
int sp_load_color_table_builtin(struct sp_context *ctx, unsigned preset);
#endif
