#ifndef STYLE_SYSTEM_H
#define STYLE_SYSTEM_H
#include "style_pipeline.h"
#include "style_model_assets_generated.h"
#define STYLE_APB_BASE UINT32_C(0xf8100000)
#define STYLE_CONTROL_BASE (STYLE_APB_BASE+0x100u)
#define STYLE_DISPLAY_BASE (STYLE_APB_BASE+0x400u)
#define STYLE_NPU_BASE (STYLE_APB_BASE+0x1000u)
#define STYLE_IPX_BASE (STYLE_APB_BASE+0x2000u)
#define STYLE_LINK_BASE (STYLE_APB_BASE+0x3000u)
#define STYLE_MODEL_DDR STYLE_MODEL_DDR_BASE
/* Built-in curve presets are generated directly into the IPX CSR table; no CPU DDR mapping exists. */
#define STYLE_TABLE_PRESET_A 0u
#define STYLE_TABLE_PRESET_B 1u
#define STYLE_RGB_DDR UINT32_C(0x00c00000)
#define STYLE_X0_DDR UINT32_C(0x01000000)
enum style_video_mode { VIDEO_1080_30=0, VIDEO_720_30=1, VIDEO_480_30=2, VIDEO_480_60=3 };
enum style_system_register {
    SYS_VERSION=0x00, SYS_STATUS=0x04, SYS_COMMAND=0x08,
    SYS_CLAIM_SEQUENCE=0x0c, SYS_CLAIM_BASE=0x10, SYS_CLAIM_BANK=0x14,
    SYS_TARGET_BASE=0x18, SYS_ACTIVE_BASE=0x1c, SYS_FRAMES=0x20,
    SYS_IRQ_STATUS=0x24, SYS_FAULT=0x28, SYS_CAMERA_SEQUENCE=0x2c,
    SYS_CAMERA_SIZE=0x30, SYS_MODE_REQUEST=0x34, SYS_MODE_ACTIVE=0x38, SYS_MODE_STATUS=0x3c,
    // Fixed addresses and mode geometry are read-only (SYS_VERSION 0x53594302).
    SYS_NPU_RGB=0x40, SYS_X0=0x44,
    SYS_RGB_STRIDE=0x48, SYS_X0_STRIDE=0x4c, SYS_SIZE=0x50,
    SYS_STREAM=0x54, SYS_RGB_BYTES=0x58, SYS_CAMERA_MODE=0x60, SYS_CLAIM_MODE=0x64
};
#define SYS_DDR_READY 1u
#define SYS_BOOT_DONE 2u
#define SYS_BOOT_FAULT 4u
#define SYS_CAMERA_HELD 8u
#define SYS_DISPLAY_PENDING 16u
#define SYS_ERROR 32u
#define SYS_CAMERA_VALID 64u
#define SYS_FRAME_BUSY 256u
#define SYS_FRAME_DONE 512u
#define SYS_FRAME_ERROR 1024u
#define SYS_MODE_BUSY 1u
#define SYS_SENSOR_SWITCHING 2u
#define SYS_SENSOR_FAULT 4u
enum style_system_command { SYS_LOAD_FLASH=1, SYS_CLAIM_CAMERA=2,
    SYS_PUBLISH_FRAME=4, SYS_RELEASE_CAMERA=8, SYS_START_FRAME=16 };
enum style_display_register {
    DISPLAY_UI_DATA=0x40, DISPLAY_UI_HINT=0x44,
    DISPLAY_UI_METRICS=0x48, DISPLAY_UI_LIVE_STATE=0x4c,
    DISPLAY_DIAG_CLEAR=0x50, DISPLAY_DIAG_SNAPSHOT=0x54,
    DISPLAY_DIAG_STATUS=0x58, DISPLAY_DIAG_A=0x5c, DISPLAY_DIAG_B=0x60,
    DISPLAY_UI_VALUES0=0x64, DISPLAY_UI_VALUES1=0x68, DISPLAY_UI_VALUES2=0x6c
};
enum style_display_state { DISPLAY_STATE_STARTING=0, DISPLAY_STATE_READY=1,
    DISPLAY_STATE_PROCESSING=2, DISPLAY_STATE_PUBLISHING=3,
    DISPLAY_STATE_MODE_SWITCH=4, DISPLAY_STATE_ERROR=5, DISPLAY_STATE_PAUSED=6, DISPLAY_STATE_GESTURE_READY=7 };
#ifdef STYLE_CAMERA_HOST_TEST
uint32_t style_read(uint32_t base,unsigned reg);
void style_write(uint32_t base,unsigned reg,uint32_t value);
#else
static inline uint32_t style_read(uint32_t base,unsigned reg)
{ return *(volatile uint32_t *)(uintptr_t)(base+reg); }
static inline void style_write(uint32_t base,unsigned reg,uint32_t value)
{
    *(volatile uint32_t *)(uintptr_t)(base+reg)=value;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
}
#endif
#endif
