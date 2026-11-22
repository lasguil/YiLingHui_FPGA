/* IPX v2.1 color-only MMIO; 565 frames, 8-bit public table bytes, one shared 768-byte table. */
/* 流式唯一路径：删除SRC读入口，新增流行接缝halo字段。 */
#ifndef IPX_REGS_H
#define IPX_REGS_H
#include <stdint.h>
enum ipx_register {
    IPX_VERSION=0x00, IPX_CAPABILITIES=0x04, IPX_CONTROL=0x08, IPX_STATUS=0x0c,
    IPX_DST=0x14, IPX_DST_STRIDE=0x1c,
    IPX_WINDOW_SIZE=0x20, IPX_DST_SIZE=0x24, IPX_OPTIONS=0x28, IPX_SATURATION=0x2c,
    IPX_COLOR_MIN=0x30, IPX_COLOR_MAX=0x34, IPX_ALPHA=0x38,
    IPX_STREAM_EDGE=0x4c,
    IPX_TABLE_COMMAND=0x50, IPX_TABLE_INDEX=0x54, IPX_TABLE_DATA=0x58,
    IPX_TABLE_STATUS=0x5c, IPX_FRAME_ID=0x60, IPX_MAX_SIZE=0x64,
    IPX_ORIGINAL_SRC=0x68, IPX_ORIGINAL_STRIDE=0x6c, IPX_AI_ALPHA=0x70, IPX_AI_CONTROL=0x74,
    IPX_CYCLES=0x80, IPX_INPUT_PIXELS=0x84, IPX_OUTPUT_PIXELS=0x88,
    IPX_READ_BEATS=0x8c, IPX_WRITE_BEATS=0x90, IPX_INPUT_STALLS=0x94, IPX_OUTPUT_STALLS=0x98
};
enum ipx_color { IPX_RGB_CURVE=0, IPX_GRAY_PALETTE=1, IPX_DUOTONE_DOT=2, IPX_RGB_DOT=3 };
enum ipx_error { IPX_OK, IPX_BAD_CONFIG, IPX_BAD_ADDRESS, IPX_READ_ERROR,
                 IPX_WRITE_ERROR, IPX_ABORTED, IPX_TABLE_INVALID };
#define IPX_START          UINT32_C(1)
#define IPX_ABORT          UINT32_C(2)
#define IPX_CLEAR_DONE     UINT32_C(4)
#define IPX_IRQ_ENABLE     UINT32_C(8)
#define IPX_BUSY           UINT32_C(1)
#define IPX_DONE           UINT32_C(2)
#define IPX_TABLE_BEGIN    UINT32_C(1) /* Manual 8-bit byte load; invalidates the active table. */
#define IPX_TABLE_COMMIT   UINT32_C(2) /* Manual load succeeds only after exactly 768 bytes. */
#define IPX_TABLE_LOAD_DDR UINT32_C(4) /* IPX read DMA loads 768 bytes from IPX_ORIGINAL_SRC. */
#define IPX_SIZE(w,h)      (((uint32_t)(h)<<16)|(uint32_t)(w))
#define IPX_RGB(r,g,b)     ((uint32_t)(r)|((uint32_t)(g)<<8)|((uint32_t)(b)<<16))
#define IPX_MODE_COLOR(m)  (((uint32_t)(m)&3u)<<4)
#define IPX_PRESERVE       UINT32_C(0x00000200)
#define IPX_TABLE_BYTES    768u
#define IPX_TABLE_STATUS_VALID UINT32_C(1)
#define IPX_TABLE_STATUS_LOADING UINT32_C(2)
#define IPX_TABLE_GENERATION(status) ((uint16_t)((status)>>16))
#define IPX_INTERFACE_V12  UINT32_C(0x49505812)
#define IPX_CAPS_V12       UINT32_C(0x000005f1)
#define IPX_INTERFACE_V13  UINT32_C(0x49505813)
#define IPX_CAPS_V13       UINT32_C(0x00000df1)
#define IPX_INTERFACE_V21  UINT32_C(0x49505821)
#define IPX_CAPS_V21       UINT32_C(0x000005f1)
#define IPX_ENABLE_AI_MIX  UINT32_C(1)
#define IPX_STRENGTH_FULL  UINT32_C(256) /* AI_ALPHA and ALPHA use Q8, valid range 0..256. */
#define IPX_EDGE_HALO(lo,hi) (((uint32_t)(hi)<<8)|(uint32_t)(lo)) /* 0 or 4 pixels per side. */
#endif
