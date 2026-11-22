#ifndef CH9350_UART_H
#define CH9350_UART_H
#include "ch9350_touch.h"
#include <stdint.h>

#define CH9350_UART_CSR_BASE UINT32_C(0xf8100600)
#define CH9350_UART_DATA 0x00u
#define CH9350_UART_STATUS 0x04u
#define CH9350_UART_LEVEL 0x08u
#define CH9350_UART_OVERRUN_COUNT 0x0cu
#define CH9350_UART_FRAMING_COUNT 0x10u
#define CH9350_UART_BYTE_COUNT 0x14u
#define CH9350_UART_CONTROL 0x18u
#define CH9350_STATUS_NONEMPTY (1u<<0)
#define CH9350_STATUS_OVERRUN (1u<<1)
#define CH9350_STATUS_FRAMING (1u<<2)
#define CH9350_STATUS_FULL (1u<<4)

/* Reads at most budget bytes, keeping a UI task bounded. now_ms must be monotonic. */
unsigned ch9350_uart_service(ch9350_touch *ctx, uintptr_t base, uint32_t now_ms, unsigned budget);
#endif
