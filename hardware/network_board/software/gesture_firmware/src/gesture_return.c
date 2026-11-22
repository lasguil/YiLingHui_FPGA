#include "gesture_platform.h"
#include "gesture_return_protocol.h"

#define RETURN_FRAME_OVERHEAD 10u

struct return_frame {
    uint8_t bytes[GESTURE_RETURN_FRAME_MAX];
    uint8_t length;
    uint8_t position;
    uint8_t is_web;
    uint32_t web_token;
};

static struct return_frame queue[GESTURE_RETURN_QUEUE_DEPTH];
static uint8_t queue_head;
static uint8_t queue_tail;
static uint8_t queue_count;
static uint16_t hand_marker_latest;
static uint32_t hand_marker_last_queued;
static uint8_t hand_marker_slot,hand_marker_pending,hand_marker_slot_valid;
static uint16_t next_sequence;
static uint8_t service_active;
static uint8_t waiting_ack;
static uint16_t waiting_ack_sequence;
static uint32_t waiting_ack_token;
static uint32_t waiting_ack_since;
static uint8_t active_web;
static uint8_t early_ack, early_ack_status, early_ack_error;
static uint32_t active_web_token;
static uint16_t active_web_sequence;
static uint8_t rx_frame[GESTURE_RETURN_FRAME_MAX];
static uint8_t rx_length, rx_expected;
static uint32_t rx_last_byte_cycle;
static uint8_t wire_pending;
static uint32_t web_status_token, web_status_meta;
static uint8_t web_status_pending;
static uint8_t prompt_sent;
static uint32_t prompt_last_cycle;

static __attribute__((noinline)) uint32_t cycle_count(void)
{
#ifdef GESTURE_HOST_TEST
    extern uint32_t gesture_test_cycle_count(void);
    return gesture_test_cycle_count();
#else
    /* This VexRiscv CSR decode treats rdcycle's csrrs rs1=x0 form as a CSR
     * write, so rdcycle faults into gesture_trap. The CLINT mtime low word is
     * a 100 MHz monotonic tick; unsigned differences tolerate its 42.9 s wrap. */
    return *(volatile uint32_t *)0xf8b0bff8u;
#endif
}

volatile uint32_t gesture_return_frames_queued;
volatile uint32_t gesture_return_frames_sent;
volatile uint32_t gesture_return_frames_dropped;
volatile uint32_t gesture_return_uart_errors;

static void queue_web_status(uint32_t token, uint8_t state, uint8_t detail,
                             uint16_t uart_sequence)
{
    web_status_token = token;
    web_status_meta = (uint32_t)state | ((uint32_t)detail << 8)
                    | ((uint32_t)uart_sequence << 16);
    web_status_pending = 1u;
}

static void flush_web_status(void)
{
    if (!web_status_pending
        || (gesture_mmio_read(GESTURE_WEB_CONTROL_BASE, WEB_CONTROL_STATUS)
            & WEB_CONTROL_STATUS_FULL)) return;
    gesture_mmio_write(GESTURE_WEB_CONTROL_BASE, WEB_CONTROL_STATUS_TOKEN,
                       web_status_token);
    gesture_mmio_write(GESTURE_WEB_CONTROL_BASE, WEB_CONTROL_STATUS_META,
                       web_status_meta);
    gesture_mmio_write(GESTURE_WEB_CONTROL_BASE, WEB_CONTROL_STATUS_COMMIT, 1u);
    web_status_pending = 0u;
}

uint16_t gesture_return_crc16(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xffffu;
    size_t i;
    for (i = 0; i < length; ++i) {
        unsigned bit;
        crc ^= (uint16_t)data[i] << 8;
        for (bit = 0; bit < 8; ++bit) {
            uint16_t shifted = (uint16_t)(crc << 1);
            crc = (crc & 0x8000u) ? (uint16_t)(shifted ^ 0x1021u) : shifted;
        }
    }
    return crc;
}

size_t gesture_return_encode(uint8_t type, uint16_t sequence,
                             const uint8_t *payload, uint16_t payload_length,
                             uint8_t *output, size_t output_capacity)
{
    size_t total = RETURN_FRAME_OVERHEAD + payload_length;
    size_t i;
    uint16_t crc;
    if (!output || (payload_length && !payload) || total > output_capacity)
        return 0;
    output[0] = GESTURE_RETURN_SYNC0;
    output[1] = GESTURE_RETURN_SYNC1;
    output[2] = GESTURE_RETURN_PROTOCOL_VERSION;
    output[3] = type;
    output[4] = (uint8_t)sequence;
    output[5] = (uint8_t)(sequence >> 8);
    output[6] = (uint8_t)payload_length;
    output[7] = (uint8_t)(payload_length >> 8);
    for (i = 0; i < payload_length; ++i)
        output[8u + i] = payload[i];
    crc = gesture_return_crc16(output + 2u, 6u + payload_length);
    output[8u + payload_length] = (uint8_t)crc;
    output[9u + payload_length] = (uint8_t)(crc >> 8);
    return total;
}

static void put16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void put32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static int valid_type(uint8_t type)
{
    switch (type) {
    case GESTURE_RETURN_TYPE_PAUSE_SET:
    case GESTURE_RETURN_TYPE_UI_SET:
    case GESTURE_RETURN_TYPE_GESTURE_EVENT:
    case GESTURE_RETURN_TYPE_VIDEO_MODE_SET:
    case GESTURE_RETURN_TYPE_SCENE_SET:
    case GESTURE_RETURN_TYPE_VIEW_SET:
    case GESTURE_RETURN_TYPE_EFFECT_SET:
    case GESTURE_RETURN_TYPE_PARAMETER_SET:
    case GESTURE_RETURN_TYPE_LUT_BEGIN:
    case GESTURE_RETURN_TYPE_LUT_CHUNK:
    case GESTURE_RETURN_TYPE_LUT_COMMIT:
    case GESTURE_RETURN_TYPE_CONFIG_BEGIN:
    case GESTURE_RETURN_TYPE_CONFIG_COMMIT:
    case GESTURE_RETURN_TYPE_CAPS_QUERY:
    case GESTURE_RETURN_TYPE_CAPS_REPORT:
    case GESTURE_RETURN_TYPE_STATUS_QUERY:
    case GESTURE_RETURN_TYPE_STATUS_REPORT:
    case GESTURE_RETURN_TYPE_ACK:
    case GESTURE_RETURN_TYPE_UI_POINTER:
    case GESTURE_RETURN_TYPE_UI_ACTION:
        return 1;
    default:
        return 0;
    }
}

void gesture_return_init(void)
{
    uint32_t status = gesture_mmio_read(GESTURE_RETURN_UART_BASE, RETURN_UART_STATUS);
    if ((status & (RETURN_UART_TX_BUSY | RETURN_UART_TX_FULL)) == 0u
        && (status & RETURN_UART_TX_EMPTY))
        gesture_mmio_write(GESTURE_RETURN_UART_BASE, RETURN_UART_BAUD_DIV,
                           RETURN_UART_BAUD_DIV_100M_115200);
    gesture_mmio_write(GESTURE_RETURN_UART_BASE, RETURN_UART_STATUS_W1C,
                       RETURN_UART_RX_OVERFLOW | RETURN_UART_FRAME_ERROR | RETURN_UART_BREAK);
    prompt_sent=255u;prompt_last_cycle=0;
    queue_head = queue_tail = queue_count = 0u;
    hand_marker_latest=0x007fu;hand_marker_pending=hand_marker_slot_valid=0u;
    hand_marker_slot=0u;hand_marker_last_queued=0u;
    next_sequence = 0u;
    service_active = 0u;
    waiting_ack = active_web = 0u;
    early_ack = 0u;
    wire_pending = 0u;
    waiting_ack_sequence = active_web_sequence = 0u;
    waiting_ack_token = active_web_token = waiting_ack_since = 0u;
    rx_length = rx_expected = 0u;
    rx_last_byte_cycle = 0u;
    web_status_pending = 0u;
    gesture_return_frames_queued = 0u;
    gesture_return_frames_sent = 0u;
    gesture_return_frames_dropped = 0u;
    gesture_return_uart_errors = 0u;
}

int gesture_return_enqueue(uint8_t type, const uint8_t *payload, uint16_t payload_length)
{
    struct return_frame *frame;
    size_t length;
    if (!valid_type(type) || payload_length > GESTURE_RETURN_PAYLOAD_MAX
        || (payload_length && !payload)) {
        ++gesture_return_frames_dropped;
        return -1;
    }
    if (queue_count >= GESTURE_RETURN_QUEUE_DEPTH) {
        ++gesture_return_frames_dropped;
        return -2;
    }
    frame = &queue[queue_tail];
    length = gesture_return_encode(type, next_sequence++, payload, payload_length,
                                   frame->bytes, sizeof(frame->bytes));
    if (!length) {
        ++gesture_return_frames_dropped;
        return -3;
    }
    frame->length = (uint8_t)length;
    frame->position = 0u;
    frame->is_web = 0u;
    frame->web_token = 0u;
    queue_tail = (uint8_t)((queue_tail + 1u) % GESTURE_RETURN_QUEUE_DEPTH);
    ++queue_count;
    ++gesture_return_frames_queued;
    gesture_return_service();
    return 0;
}

void gesture_return_hand_marker(unsigned valid,int32_t x_q8,int32_t y_q8)
{
    uint16_t packed=0x007fu;
    if(valid&&x_q8>=0&&y_q8>=0&&x_q8<(640*256)&&y_q8<(360*256)){
        unsigned x_cell=((uint32_t)x_q8*3u)>>12;
        unsigned y_cell=((uint32_t)y_q8*3u)>>12;
        if(x_cell<120u&&y_cell<68u)
            packed=(uint16_t)(x_cell|(y_cell<<7));
    }
    uint32_t now=cycle_count();
    if(packed!=hand_marker_latest ||
       (packed!=0x007fu&&(uint32_t)(now-hand_marker_last_queued)>=UINT32_C(10000000))){
        hand_marker_latest=packed;
        hand_marker_pending=1u;
    }
}

int gesture_return_enqueue_web(uint32_t token, uint8_t type,
                               const uint8_t *payload, uint16_t payload_length)
{
    struct return_frame *frame;
    size_t length;
    if (!valid_type(type) || type == GESTURE_RETURN_TYPE_ACK
        || payload_length > GESTURE_RETURN_PAYLOAD_MAX
        || (payload_length && !payload)) {
        ++gesture_return_frames_dropped;
        return -1;
    }
    if (queue_count >= GESTURE_RETURN_QUEUE_DEPTH) {
        ++gesture_return_frames_dropped;
        return -2;
    }
    frame = &queue[queue_tail];
    length = gesture_return_encode(type, next_sequence++, payload, payload_length,
                                   frame->bytes, sizeof(frame->bytes));
    if (!length) return -3;
    frame->length = (uint8_t)length;
    frame->position = 0u;
    frame->is_web = 1u;
    frame->web_token = token;
    queue_tail = (uint8_t)((queue_tail + 1u) % GESTURE_RETURN_QUEUE_DEPTH);
    ++queue_count;
    ++gesture_return_frames_queued;
    gesture_return_service();
    return 0;
}

int gesture_return_send(enum gesture_event_code event, uint32_t frame_sequence)
{
    uint8_t payload[GESTURE_RETURN_PAYLOAD_EVENT_BYTES];
    if ((unsigned)event < RETURN_LEFT || (unsigned)event > RETURN_CANCEL) {
        ++gesture_return_frames_dropped;
        return -1;
    }
    payload[0] = (uint8_t)event;
    put32(payload + 1, frame_sequence);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_GESTURE_EVENT, payload,
                                  sizeof(payload));
}

void gesture_return_prompt(unsigned ready, uint32_t frame_sequence)
{
    uint32_t now=cycle_count();
    ready=!!ready;
    if(ready==prompt_sent && (!ready || (uint32_t)(now-prompt_last_cycle)<50000000u))return;
    if(queue_count>=GESTURE_RETURN_QUEUE_DEPTH)return;
    if(gesture_return_send(ready?RETURN_READY:RETURN_CANCEL,frame_sequence)==0){
        prompt_sent=(uint8_t)ready;prompt_last_cycle=now;
    }
}

int gesture_return_cmd_pause(uint8_t paused)
{
    return paused <= 1u ? gesture_return_enqueue(GESTURE_RETURN_TYPE_PAUSE_SET,
                                                 &paused, 1u) : -1;
}

int gesture_return_cmd_ui_set(uint8_t field, uint8_t value)
{
    uint8_t payload[2] = {field, value};
    if (field < GESTURE_RETURN_SET_MODEL || field > GESTURE_RETURN_SET_WAVE
        || (field == GESTURE_RETURN_SET_WAVE && value > 2u)
        || ((field == GESTURE_RETURN_SET_AI || field == GESTURE_RETURN_SET_FX)
            && value > 100u)) return -1;
    /* Catalog bounds remain authoritative on board1. */
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_UI_SET, payload, 2u);
}

int gesture_return_cmd_video_mode(uint8_t mode)
{
    return mode <= 3u ? gesture_return_enqueue(GESTURE_RETURN_TYPE_VIDEO_MODE_SET,
                                                &mode, 1u) : -1;
}

int gesture_return_cmd_scene(enum gesture_return_scene scene, uint8_t source_a,
                             uint8_t source_b)
{
    uint8_t payload[3];
    if (scene != GESTURE_RETURN_SCENE_WIPE) return -1;
    payload[0] = (uint8_t)scene;
    payload[1] = source_a;
    payload[2] = source_b;
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_SCENE_SET, payload, sizeof(payload));
}

int gesture_return_cmd_view(const struct gesture_return_view *view)
{
    uint8_t payload[24];
    if (!view || !view->src_width || !view->src_height
        || !view->dst_width || !view->dst_height) return -1;
    put16(payload + 0, view->src_x); put16(payload + 2, view->src_y);
    put16(payload + 4, view->src_width); put16(payload + 6, view->src_height);
    put16(payload + 8, view->dst_x); put16(payload + 10, view->dst_y);
    put16(payload + 12, view->dst_width); put16(payload + 14, view->dst_height);
    put32(payload + 16, view->scale_x_16_16);
    put32(payload + 20, view->scale_y_16_16);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_VIEW_SET, payload, sizeof(payload));
}

int gesture_return_cmd_effect(enum gesture_return_effect effect, uint16_t flags)
{
    uint8_t payload[3];
    if (effect != GESTURE_RETURN_EFFECT_DIRECT && effect != GESTURE_RETURN_EFFECT_LINE
        && effect != GESTURE_RETURN_EFFECT_COMIC && effect != GESTURE_RETURN_EFFECT_EMBOSS)
        return -1;
    payload[0] = (uint8_t)effect;
    put16(payload + 1, flags);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_EFFECT_SET, payload, sizeof(payload));
}

int gesture_return_cmd_parameter(enum gesture_return_parameter id, int32_t value)
{
    uint8_t payload[5];
    if (id < GESTURE_RETURN_PARAM_SATURATION || id > GESTURE_RETURN_PARAM_ST_HI)
        return -1;
    payload[0] = (uint8_t)id;
    put32(payload + 1, (uint32_t)value);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_PARAMETER_SET, payload, sizeof(payload));
}

int gesture_return_cmd_lut_begin(enum gesture_return_lut_kind kind,
                                 uint16_t byte_count, uint32_t crc32)
{
    uint8_t payload[7];
    if (kind != GESTURE_RETURN_LUT_CURVE && kind != GESTURE_RETURN_LUT_COLOR) return -1;
    payload[0] = (uint8_t)kind;
    put16(payload + 1, byte_count);
    put32(payload + 3, crc32);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_LUT_BEGIN, payload, sizeof(payload));
}

int gesture_return_cmd_lut_chunk(enum gesture_return_lut_kind kind,
                                 uint32_t offset, const uint8_t *bytes, uint8_t count)
{
    uint8_t payload[6u + GESTURE_RETURN_LUT_CHUNK_MAX];
    unsigned i;
    if ((kind != GESTURE_RETURN_LUT_CURVE && kind != GESTURE_RETURN_LUT_COLOR)
        || !bytes || !count || count > GESTURE_RETURN_LUT_CHUNK_MAX) return -1;
    payload[0] = (uint8_t)kind;
    put32(payload + 1, offset);
    payload[5] = count;
    for (i = 0; i < count; ++i) payload[6u + i] = bytes[i];
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_LUT_CHUNK, payload,
                                  (uint16_t)(6u + count));
}

int gesture_return_cmd_lut_commit(enum gesture_return_lut_kind kind,
                                  uint16_t generation, uint32_t crc32)
{
    uint8_t payload[7];
    if (kind != GESTURE_RETURN_LUT_CURVE && kind != GESTURE_RETURN_LUT_COLOR) return -1;
    payload[0] = (uint8_t)kind;
    put16(payload + 1, generation);
    put32(payload + 3, crc32);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_LUT_COMMIT, payload, sizeof(payload));
}

int gesture_return_cmd_config_begin(uint16_t transaction, uint8_t command_count)
{
    uint8_t payload[3];
    if (!command_count) return -1;
    put16(payload, transaction);
    payload[2] = command_count;
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_CONFIG_BEGIN, payload, sizeof(payload));
}

int gesture_return_cmd_config_commit(uint16_t transaction, uint32_t frame_boundary)
{
    uint8_t payload[6];
    put16(payload, transaction);
    put32(payload + 2, frame_boundary);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_CONFIG_COMMIT, payload, sizeof(payload));
}

int gesture_return_cmd_caps_query(uint8_t min_version, uint8_t max_version)
{
    uint8_t payload[2];
    if (min_version > max_version) return -1;
    payload[0] = min_version;
    payload[1] = max_version;
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_CAPS_QUERY, payload, sizeof(payload));
}

int gesture_return_cmd_status_query(uint32_t requested_groups)
{
    uint8_t payload[4];
    put32(payload, requested_groups);
    return gesture_return_enqueue(GESTURE_RETURN_TYPE_STATUS_QUERY, payload, sizeof(payload));
}

void gesture_return_service(void)
{
    uint8_t payload[GESTURE_RETURN_PAYLOAD_MAX];
    uint8_t header[6];
    uint8_t i, length;
    uint32_t status = gesture_mmio_read(GESTURE_RETURN_UART_BASE, RETURN_UART_STATUS);
    if (service_active) return;
    service_active = 1u;
    const uint32_t errors = status & (RETURN_UART_RX_OVERFLOW | RETURN_UART_FRAME_ERROR
                                      | RETURN_UART_BREAK);
    if (errors) {
        gesture_return_uart_errors |= errors;
        gesture_mmio_write(GESTURE_RETURN_UART_BASE, RETURN_UART_STATUS_W1C, errors);
    }

    if (rx_length && (uint32_t)(cycle_count() - rx_last_byte_cycle)
                     >= GESTURE_RETURN_RX_FRAME_TIMEOUT_CYCLES) {
        rx_length = rx_expected = 0u;
    }

    // Consume UART RX continuously, but only accept a CRC-valid ACK matching
    // the one web command currently awaiting confirmation.
    for (i = 0; i < 64u; ++i) {
        uint8_t byte;
        status = gesture_mmio_read(GESTURE_RETURN_UART_BASE, RETURN_UART_STATUS);
        if (status & RETURN_UART_RX_EMPTY) break;
        byte = (uint8_t)gesture_mmio_read(GESTURE_RETURN_UART_BASE, RETURN_UART_RXDATA);
        rx_last_byte_cycle = cycle_count();
        if (rx_length == 0u) {
            if (byte == GESTURE_RETURN_SYNC0) rx_frame[rx_length++] = byte;
            continue;
        }
        if (rx_length == 1u) {
            if (byte == GESTURE_RETURN_SYNC1) rx_frame[rx_length++] = byte;
            else if (byte == GESTURE_RETURN_SYNC0) rx_frame[0] = byte;
            else rx_length = 0u;
            continue;
        }
        if (rx_length >= sizeof(rx_frame)) { rx_length = rx_expected = 0u; continue; }
        rx_frame[rx_length++] = byte;
        if (rx_length == 8u) {
            length = rx_frame[6];
            if (rx_frame[2] != GESTURE_RETURN_PROTOCOL_VERSION || rx_frame[7] != 0u
                || length > GESTURE_RETURN_PAYLOAD_MAX) {
                rx_length = rx_expected = 0u;
                if (byte == GESTURE_RETURN_SYNC0) rx_frame[rx_length++] = byte;
                continue;
            }
            rx_expected = (uint8_t)(10u + length);
        }
        if (rx_expected && rx_length == rx_expected) {
            uint16_t expected_crc = gesture_return_crc16(rx_frame + 2u,
                                                         (size_t)6u + rx_frame[6]);
            uint16_t received_crc = (uint16_t)rx_frame[rx_length - 2u]
                                  | ((uint16_t)rx_frame[rx_length - 1u] << 8);
            uint16_t sequence = (uint16_t)rx_frame[4] | ((uint16_t)rx_frame[5] << 8);
            if (expected_crc == received_crc && rx_frame[3] == GESTURE_RETURN_TYPE_ACK
                && rx_frame[6] == 4u && waiting_ack && sequence == waiting_ack_sequence) {
                uint16_t original = (uint16_t)rx_frame[8]
                                  | ((uint16_t)rx_frame[9] << 8);
                uint8_t ack_status = rx_frame[10], error = rx_frame[11];
                if (original == waiting_ack_sequence &&
                    ((ack_status == 0u && error == 0u)
                     || (ack_status == 1u && error <= 3u))) {
                    if (wire_pending && active_web) {
                        early_ack = 1u;
                        early_ack_status = ack_status;
                        early_ack_error = error;
                    } else {
                        queue_web_status(waiting_ack_token,
                            ack_status == 0u ? GESTURE_RETURN_STATUS_ACCEPTED
                                             : GESTURE_RETURN_STATUS_REJECTED,
                            error, waiting_ack_sequence);
                    }
                    waiting_ack = 0u;
                }
            }
            if (expected_crc != received_crc) {
                uint8_t found = 0u;
                uint8_t scan;
                for (scan = 1u; (uint16_t)scan + 1u < rx_length; ++scan) {
                    if (rx_frame[scan] == GESTURE_RETURN_SYNC0
                        && rx_frame[scan + 1u] == GESTURE_RETURN_SYNC1) {
                        uint8_t j, remain = (uint8_t)(rx_length - scan);
                        for (j = 0u; j < remain; ++j) rx_frame[j] = rx_frame[scan + j];
                        rx_length = remain;
                        rx_expected = 0u;
                        found = 1u;
                        break;
                    }
                }
                if (!found) {
                    uint8_t last = rx_frame[rx_length - 1u];
                    rx_length = rx_expected = 0u;
                    if (last == GESTURE_RETURN_SYNC0) rx_frame[rx_length++] = last;
                }
            } else {
                rx_length = rx_expected = 0u;
            }
        }
    }

    // The APB mailbox record is tokenLE32,type,length,payload. Preserve the
    // token in its own bounded UART queue entry until that command gets an ACK.
    if (queue_count < GESTURE_RETURN_QUEUE_DEPTH && !web_status_pending
        && !wire_pending
        && !(gesture_mmio_read(GESTURE_WEB_CONTROL_BASE, WEB_CONTROL_STATUS)
             & WEB_CONTROL_CMD_EMPTY)) {
        for (i = 0; i < sizeof(header); ++i)
            header[i] = (uint8_t)gesture_mmio_read(GESTURE_WEB_CONTROL_BASE,
                                                   WEB_CONTROL_CMD_BYTE);
        length = header[5];
        if (length <= sizeof(payload)) {
            for (i = 0; i < length; ++i)
                payload[i] = (uint8_t)gesture_mmio_read(GESTURE_WEB_CONTROL_BASE,
                                                        WEB_CONTROL_CMD_BYTE);
            {
                uint32_t token = (uint32_t)header[0] | ((uint32_t)header[1] << 8)
                               | ((uint32_t)header[2] << 16)
                               | ((uint32_t)header[3] << 24);
                uint16_t sequence = next_sequence;
                if (gesture_return_enqueue_web(token, header[4], payload, length) == 0)
                    queue_web_status(token, 2u, 0u, sequence);
            }
        }
    }

    if (wire_pending && (status & RETURN_UART_TX_EMPTY)
        && !(status & RETURN_UART_TX_BUSY)) {
        wire_pending = 0u;
        ++gesture_return_frames_sent;
        if (active_web) {
            if (early_ack) {
                queue_web_status(active_web_token,
                    early_ack_status == 0u ? GESTURE_RETURN_STATUS_ACCEPTED
                                           : GESTURE_RETURN_STATUS_REJECTED,
                    early_ack_error, active_web_sequence);
                early_ack = 0u;
            } else {
                queue_web_status(active_web_token, 4u, 0u, active_web_sequence);
            }
            active_web = 0u;
        }
    }

    if (hand_marker_pending && queue_count == 0u && !wire_pending && !waiting_ack
        && !(status & RETURN_UART_TX_FULL)) {
        struct return_frame *frame = &queue[queue_tail];
        uint8_t payload[2] = {(uint8_t)hand_marker_latest,
                              (uint8_t)(hand_marker_latest >> 8)};
        size_t encoded = gesture_return_encode(GESTURE_RETURN_TYPE_HAND_MARKER,
            next_sequence++, payload, 2u, frame->bytes, sizeof(frame->bytes));
        if (encoded) {
            frame->length = (uint8_t)encoded;frame->position = 0u;
            frame->is_web = 0u;frame->web_token = 0u;
            hand_marker_slot = queue_tail;hand_marker_slot_valid = 1u;
            queue_tail = (uint8_t)((queue_tail + 1u) % GESTURE_RETURN_QUEUE_DEPTH);
            ++queue_count;++gesture_return_frames_queued;
            hand_marker_pending = 0u;hand_marker_last_queued = cycle_count();
        }
    }

    if (hand_marker_slot_valid && queue_count == 1u
        && queue_head == hand_marker_slot && queue[hand_marker_slot].position == 0u
        && hand_marker_pending) {
        uint8_t payload[2] = {(uint8_t)hand_marker_latest,
                              (uint8_t)(hand_marker_latest >> 8)};
        struct return_frame *frame = &queue[hand_marker_slot];
        size_t encoded = gesture_return_encode(GESTURE_RETURN_TYPE_HAND_MARKER,
            (uint16_t)frame->bytes[4] | ((uint16_t)frame->bytes[5] << 8),
            payload, 2u, frame->bytes, sizeof(frame->bytes));
        if (encoded) {frame->length = (uint8_t)encoded;hand_marker_pending = 0u;}
    }

    while (queue_count && !wire_pending && !waiting_ack
           && !(status & RETURN_UART_TX_FULL)) {
        struct return_frame *frame = &queue[queue_head];
        gesture_mmio_write(GESTURE_RETURN_UART_BASE, RETURN_UART_TXDATA,
                           frame->bytes[frame->position++]);
        status = gesture_mmio_read(GESTURE_RETURN_UART_BASE, RETURN_UART_STATUS);
        if (frame->position == frame->length) {
            active_web = frame->is_web;
            active_web_token = frame->web_token;
            active_web_sequence = (uint16_t)frame->bytes[4]
                                | ((uint16_t)frame->bytes[5] << 8);
            if (active_web) {
                early_ack = 0u;
                waiting_ack = 1u;
                waiting_ack_sequence = active_web_sequence;
                waiting_ack_token = active_web_token;
                waiting_ack_since = cycle_count();
            }
            if(hand_marker_slot_valid&&queue_head==hand_marker_slot)
                hand_marker_slot_valid=0u;
            queue_head = (uint8_t)((queue_head + 1u) % GESTURE_RETURN_QUEUE_DEPTH);
            --queue_count;
            wire_pending = 1u;
        }
    }

    if (waiting_ack && (uint32_t)(cycle_count() - waiting_ack_since)
                      >= GESTURE_RETURN_ACK_TIMEOUT_CYCLES) {
        queue_web_status(waiting_ack_token, GESTURE_RETURN_STATUS_TIMEOUT,
                         0u, waiting_ack_sequence);
        waiting_ack = 0u;
    }
    flush_web_status();
    service_active = 0u;
}
