#ifndef GESTURE_PLATFORM_H
#define GESTURE_PLATFORM_H

#include <stdint.h>

/* CPU-visible APB map agreed with the second-board integration draft. */
#define PLATFORM_APB_BASE       0xf8100000u
#define GESTURE_NPU_APB_BASE    (PLATFORM_APB_BASE + 0x1000u)
#define GESTURE_VIDEO_APB_BASE  (PLATFORM_APB_BASE + 0x2000u)
#define GESTURE_RETURN_UART_BASE (PLATFORM_APB_BASE + 0x3000u)
#define GESTURE_WEB_CONTROL_BASE (PLATFORM_APB_BASE + 0x4000u)
#define GESTURE_FLASH_MODEL_BASE (PLATFORM_APB_BASE + 0x5000u)
#define WEB_CONTROL_STATUS       0x00u
#define WEB_CONTROL_CMD_BYTE     0x04u
#define WEB_CONTROL_CMD_EMPTY    (1u << 0)
#define WEB_CONTROL_STATUS_FULL  (1u << 1)
#define WEB_CONTROL_STATUS_TOKEN 0x08u
#define WEB_CONTROL_STATUS_META  0x0cu
#define WEB_CONTROL_STATUS_COMMIT 0x10u
#define GESTURE_UART_BASE       0xf8010000u

#define FLASH_MODEL_CTRL        0x00u
#define FLASH_MODEL_ADDR        0x04u
#define FLASH_MODEL_DATA        0x08u
#define FLASH_MODEL_STATUS      0x0cu
#define FLASH_MODEL_START       (1u << 0)
#define FLASH_MODEL_STOP        (1u << 1)
#define FLASH_MODEL_BUSY        (1u << 0)
#define FLASH_MODEL_VALID       (1u << 1)
#define FLASH_MODEL_DONE        (1u << 2)
#define FLASH_MODEL_FAULT       (1u << 3)

#define RETURN_UART_TXDATA      0x00u
#define RETURN_UART_RXDATA      0x04u
#define RETURN_UART_STATUS      0x08u
#define RETURN_UART_BAUD_DIV    0x0cu
#define RETURN_UART_STATUS_W1C  0x10u
#define RETURN_UART_TX_EMPTY    (1u << 0)
#define RETURN_UART_TX_FULL     (1u << 1)
#define RETURN_UART_TX_BUSY     (1u << 2)
#define RETURN_UART_RX_EMPTY    (1u << 3)
#define RETURN_UART_RX_FULL     (1u << 4)
#define RETURN_UART_RX_OVERFLOW (1u << 5)
#define RETURN_UART_FRAME_ERROR (1u << 6)
#define RETURN_UART_BREAK       (1u << 7)
#define RETURN_UART_BAUD_DIV_100M_115200 868u

#define NPU_REG_CTRL            0x00u
#define NPU_REG_STATUS          0x04u
#define NPU_REG_IRQ             0x0cu
#define NPU_REG_DDR_OFFSET      0x24u
#define NPU_REG_VERSION         0x20u
#define NPU_STATUS_BUSY         (1u << 0)
#define NPU_STATUS_DONE         (1u << 1)
#define NPU_STATUS_ERROR        (1u << 2)
#define NPU_VERSION_EXPECTED    0x20261001u

#define VIDEO_REG_CTRL          0x00u
#define VIDEO_REG_STATUS        0x04u
#define VIDEO_REG_FRAME0        0x08u
#define VIDEO_REG_FRAME1        0x0cu
#define VIDEO_REG_PUBLISHED     0x10u
#define VIDEO_REG_ROI_X         0x14u
#define VIDEO_REG_ROI_Y         0x18u
#define VIDEO_REG_ROI_SIDE      0x1cu
#define VIDEO_REG_OUTPUT_BASE   0x20u
#define VIDEO_REG_SELECTED      0x24u
#define VIDEO_STATUS_FRAME_VALID (1u << 0)
#define VIDEO_STATUS_BUSY        (1u << 1)
#define VIDEO_STATUS_DONE        (1u << 2)
#define VIDEO_STATUS_ERROR       (1u << 3)
#define VIDEO_STATUS_CAPTURE_OVERFLOW (1u << 4)
#define VIDEO_STATUS_CAPTURE_ERROR (1u << 5)
#define VIDEO_STATUS_VIDEO_LOST  (1u << 6)

/* Packed NPU memory image, relocated as one 0x439800-byte DDR region. */
#define GESTURE_DDR_BASE         0x02000000u
#define GESTURE_WEIGHTS_DDR      (GESTURE_DDR_BASE + 0x00000000u)
#define GESTURE_PARAMS_DDR       (GESTURE_DDR_BASE + 0x0010d000u)
#define GESTURE_IMAGE_DDR        (GESTURE_DDR_BASE + 0x00129000u)
#define GESTURE_HEAD_HAND_DDR    (GESTURE_DDR_BASE + 0x002b12a0u)
#define GESTURE_HEAD_HANDED_DDR  (GESTURE_DDR_BASE + 0x002b12c0u)
#define GESTURE_HEAD_LANDMARK_DDR (GESTURE_DDR_BASE + 0x002b12e0u)
#define GESTURE_CAPTURE_FRAME0   0x03000000u
#define GESTURE_CAPTURE_FRAME1   0x03100000u

#ifdef GESTURE_HOST_TEST
uint32_t gesture_mmio_read(uint32_t base, uint32_t offset);
void gesture_mmio_write(uint32_t base, uint32_t offset, uint32_t value);
uint8_t gesture_ddr_read8(uint32_t address);
void gesture_ddr_write32(uint32_t address, uint32_t value);
void gesture_console_init(void);
int gesture_console_putc(char value);
#else
static inline volatile uint32_t *gesture_reg(uint32_t base, uint32_t offset)
{
    return (volatile uint32_t *)(uintptr_t)(base + offset);
}

static inline uint32_t gesture_mmio_read(uint32_t base, uint32_t offset)
{
    uint32_t value = *gesture_reg(base, offset);
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    return value;
}

static inline void gesture_mmio_write(uint32_t base, uint32_t offset, uint32_t value)
{
    *gesture_reg(base, offset) = value;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
}

static inline uint8_t gesture_ddr_read8(uint32_t address)
{
    uint8_t value = *(volatile uint8_t *)(uintptr_t)address;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    return value;
}

static inline void gesture_ddr_write32(uint32_t address, uint32_t value)
{
    *(volatile uint32_t *)(uintptr_t)address = value;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
}

static inline void gesture_console_init(void)
{
    volatile uint32_t *uart = (volatile uint32_t *)(uintptr_t)GESTURE_UART_BASE;
    uart[2] = 100000000u / (115200u * 8u) - 1u;
    uart[3] = 7u; /* Sapphire UART: 8 data bits, no parity, one stop bit. */
    __asm__ volatile("fence iorw,iorw" ::: "memory");
}

static inline int gesture_console_putc(char value)
{
    volatile uint32_t *uart = (volatile uint32_t *)(uintptr_t)GESTURE_UART_BASE;
    uint32_t timeout = 100000u;
    while ((((uart[1] >> 16) & 0xffu) == 0u) && timeout)
        --timeout;
    if (!timeout) return 0;
    uart[0] = (uint8_t)value;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    return 1;
}
#endif

enum gesture_event_code { RETURN_NONE = 0, RETURN_LEFT = 1, RETURN_RIGHT = 2, RETURN_READY = 3, RETURN_CANCEL = 4 };
int gesture_return_send(enum gesture_event_code event, uint32_t frame_sequence);
void gesture_return_prompt(unsigned ready, uint32_t frame_sequence);
void gesture_return_init(void);
void gesture_return_service(void);

#endif
