#ifndef GESTURE_UART_H
#define GESTURE_UART_H

#include <stdint.h>
#include "style_input.h"

#define GESTURE_UART_CSR_BASE UINT32_C(0xf8100700)
#define GESTURE_UART_DATA 0x00u
#define GESTURE_UART_STATUS 0x04u
#define GESTURE_UART_LEVEL 0x08u
#define GESTURE_UART_OVERRUN_COUNT 0x0cu
#define GESTURE_UART_FRAMING_COUNT 0x10u
#define GESTURE_UART_BYTE_COUNT 0x14u
#define GESTURE_UART_CONTROL 0x18u
#define GESTURE_UART_TX_DATA 0x1cu
#define GESTURE_UART_TX_STATUS 0x20u
#define GESTURE_UART_STATUS_NONEMPTY (1u<<0)
#define GESTURE_UART_STATUS_OVERRUN (1u<<1)
#define GESTURE_UART_STATUS_FRAMING (1u<<2)
#define GESTURE_UART_RX_BUDGET 64u

#define GESTURE_PROTOCOL_SYNC0 0xa5u
#define GESTURE_PROTOCOL_SYNC1 0x5au
#define GESTURE_PROTOCOL_VERSION 1u
#define GESTURE_PROTOCOL_TYPE_PAUSE_SET 0x02u /* WAVE PRO: payload u8, 1=hold, 0=resume. */
#define GESTURE_PROTOCOL_FRAME_MAX 64u
#define GESTURE_UART_ACK_DEPTH 4u
#define GESTURE_UART_TX_BASE UINT32_C(0xf8100700)
#define GESTURE_HAND_MARKER_INVALID 127u

typedef struct {
    uint8_t bytes[GESTURE_PROTOCOL_FRAME_MAX];
    uint8_t used;
    uint8_t expected;
    uint8_t sequence_valid;
    uint16_t last_sequence;
    uint16_t last_crc;
    uint8_t last_ack_status,last_ack_error;
    uint32_t last_byte_cycles;
    uint32_t last_frame_cycles;
    uint32_t good_frames;
    uint32_t bad_frames;
    uint32_t unsupported;
    uint8_t ack[GESTURE_UART_ACK_DEPTH][14]; /* Complete wire frame; no payload FIFO. */
    uint8_t ack_head,ack_count,ack_pos;
    uint8_t remote_active;
    uint32_t remote_last_cycles;
    uint32_t gesture_last_cycles;
    uint32_t ack_dropped;
    uint16_t hand_marker;
    uint32_t hand_marker_last_cycles;
    uint8_t hand_marker_valid;
} gesture_uart_parser;

extern gesture_uart_parser gesture_uart_state;

/* Feed one protocol byte, or service up to GESTURE_UART_RX_BUDGET hardware bytes. */
void gesture_uart_parser_feed(gesture_uart_parser *parser, uint8_t byte,
                              uint32_t now_cycles, style_input_state *state);
unsigned gesture_uart_service(style_input_state *state,uint32_t now_cycles);
void gesture_uart_tx_service(gesture_uart_parser *parser);
void gesture_uart_remote_timeout(gesture_uart_parser *parser,style_input_state *state,
                                 uint32_t now_cycles,uint32_t now_ms);

#endif
