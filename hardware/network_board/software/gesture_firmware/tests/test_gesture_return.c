#include "gesture_platform.h"
#include "gesture_return_protocol.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint8_t tx_stream[1024];
static unsigned tx_length;
static unsigned tx_fifo_count;
static unsigned tx_busy;
static uint32_t baud_div;
static uint8_t web_record[64];
static unsigned web_length, web_position;
static uint32_t web_status_token, web_status_meta;
static unsigned web_status_commits;
static uint32_t web_status_token_log[32], web_status_meta_log[32];
static uint8_t rx_stream[128];
static unsigned rx_length, rx_position;
static uint32_t test_cycles;

uint32_t gesture_test_cycle_count(void) { return test_cycles; }

uint32_t gesture_mmio_read(uint32_t base, uint32_t offset)
{
    if (base == GESTURE_WEB_CONTROL_BASE) {
        if (offset == WEB_CONTROL_STATUS)
            return (web_position >= web_length ? WEB_CONTROL_CMD_EMPTY : 0u);
        if (offset == WEB_CONTROL_CMD_BYTE && web_position < web_length)
            return web_record[web_position++];
        return 0;
    }
    assert(base == GESTURE_RETURN_UART_BASE);
    if (offset == RETURN_UART_STATUS) {
        uint32_t status = 0;
        if (!tx_fifo_count) status |= RETURN_UART_TX_EMPTY;
        if (tx_fifo_count == 64u) status |= RETURN_UART_TX_FULL;
        if (tx_busy) status |= RETURN_UART_TX_BUSY;
        if (rx_position >= rx_length) status |= RETURN_UART_RX_EMPTY;
        if (rx_length - rx_position >= 64u) status |= RETURN_UART_RX_FULL;
        return status;
    }
    if (offset == RETURN_UART_RXDATA)
        return rx_position < rx_length ? rx_stream[rx_position++] : 0u;
    return 0;
}

void gesture_mmio_write(uint32_t base, uint32_t offset, uint32_t value)
{
    if (base == GESTURE_WEB_CONTROL_BASE) {
        if (offset == WEB_CONTROL_STATUS_TOKEN) web_status_token = value;
        else if (offset == WEB_CONTROL_STATUS_META) web_status_meta = value;
        else if (offset == WEB_CONTROL_STATUS_COMMIT) {
            if (web_status_commits < 32u) {
                web_status_token_log[web_status_commits] = web_status_token;
                web_status_meta_log[web_status_commits] = web_status_meta;
            }
            ++web_status_commits;
        }
        return;
    }
    assert(base == GESTURE_RETURN_UART_BASE);
    if (offset == RETURN_UART_BAUD_DIV) {
        baud_div = value;
    } else if (offset == RETURN_UART_TXDATA) {
        assert(tx_fifo_count < 64u);
        assert(tx_length < sizeof(tx_stream));
        tx_stream[tx_length++] = (uint8_t)value;
        ++tx_fifo_count;
    }
}

uint8_t gesture_ddr_read8(uint32_t address) { (void)address; return 0; }
void gesture_console_init(void) { }
int gesture_console_putc(char value) { (void)value; return 1; }

static void drain_fifo(void)
{
    tx_fifo_count = 0;
}

static void complete_uart(void)
{
    drain_fifo();
    tx_busy = 0u;
    gesture_return_service();
}

static void inject_ack(uint16_t sequence, uint8_t status, uint8_t error, int corrupt)
{
    uint8_t payload[4] = {(uint8_t)sequence, (uint8_t)(sequence >> 8), status, error};
    rx_length = (unsigned)gesture_return_encode(GESTURE_RETURN_TYPE_ACK, sequence,
        payload, sizeof(payload), rx_stream, sizeof(rx_stream));
    rx_position = 0u;
    if (corrupt) rx_stream[rx_length - 1u] ^= 0x80u;
}

static void append_ack(uint16_t sequence, uint8_t status, uint8_t error, int corrupt)
{
    uint8_t frame[GESTURE_RETURN_FRAME_MAX];
    uint8_t payload[4] = {(uint8_t)sequence, (uint8_t)(sequence >> 8), status, error};
    size_t length = gesture_return_encode(GESTURE_RETURN_TYPE_ACK, sequence,
        payload, sizeof(payload), frame, sizeof(frame));
    assert(length != 0u && rx_length + length <= sizeof(rx_stream));
    memcpy(rx_stream + rx_length, frame, length);
    if (corrupt) rx_stream[rx_length + length - 1u] ^= 0x80u;
    rx_length += (unsigned)length;
}

static void append_web_command(uint32_t token, uint8_t type,
                              const uint8_t *payload, uint8_t length)
{
    unsigned i;
    assert(web_length + 6u + length <= sizeof(web_record));
    web_record[web_length++] = (uint8_t)token;
    web_record[web_length++] = (uint8_t)(token >> 8);
    web_record[web_length++] = (uint8_t)(token >> 16);
    web_record[web_length++] = (uint8_t)(token >> 24);
    web_record[web_length++] = type;
    web_record[web_length++] = length;
    for (i = 0; i < length; ++i) web_record[web_length++] = payload[i];
}

static int saw_web_status(uint32_t token, uint8_t stage)
{
    unsigned i, count = web_status_commits < 32u ? web_status_commits : 32u;
    for (i = 0; i < count; ++i) {
        if (web_status_token_log[i] == token
            && (web_status_meta_log[i] & 0xffu) == stage) return 1;
    }
    return 0;
}

int main(void)
{
    static const uint8_t check[] = "123456789";
    uint8_t frame[GESTURE_RETURN_FRAME_MAX];
    uint8_t payload[GESTURE_RETURN_PAYLOAD_EVENT_BYTES] = {1, 0x44, 0x33, 0x22, 0x11};
    size_t length;
    unsigned before;
    uint32_t queued_before,sent_before,dropped_before,errors_before;

    assert(gesture_return_crc16(check, sizeof(check) - 1u) == 0x29b1u);
    length = gesture_return_encode(GESTURE_RETURN_TYPE_GESTURE_EVENT, 0x1234u,
                                   payload, sizeof(payload), frame, sizeof(frame));
    assert(length == 15u && frame[0] == 0xa5u && frame[1] == 0x5au);
    assert(frame[2] == 1u && frame[3] == GESTURE_RETURN_TYPE_GESTURE_EVENT);
    assert(frame[4] == 0x34u && frame[5] == 0x12u);
    assert(frame[6] == 5u && frame[7] == 0u);
    assert(memcmp(frame + 8, payload, sizeof(payload)) == 0);
    assert(frame[13] == (uint8_t)gesture_return_crc16(frame + 2, 11u));
    assert(frame[14] == (uint8_t)(gesture_return_crc16(frame + 2, 11u) >> 8));
    assert(gesture_return_encode(GESTURE_RETURN_TYPE_STATUS_REPORT, 0, payload,
                                 GESTURE_RETURN_PAYLOAD_MAX + 1u, frame,
                                 sizeof(frame)) == 0u);

    gesture_return_init();
    assert(baud_div == RETURN_UART_BAUD_DIV_100M_115200);
    assert(gesture_return_send(RETURN_LEFT, 0x11223344u) == 0);
    assert(tx_length == 15u && tx_fifo_count == 15u);
    assert(tx_stream[8] == GESTURE_RETURN_EVENT_LEFT);
    assert(tx_stream[9] == 0x44u && tx_stream[12] == 0x11u);
    assert(gesture_return_frames_sent == 0u);
    drain_fifo();
    tx_busy = 1u;
    gesture_return_service();
    assert(gesture_return_frames_sent == 0u);
    tx_busy = 0u;
    gesture_return_service();
    assert(gesture_return_frames_sent == 1u);

    // Position reports use one replaceable low-priority slot and no peer ACK.
    queued_before=gesture_return_frames_queued;sent_before=gesture_return_frames_sent;
    dropped_before=gesture_return_frames_dropped;errors_before=gesture_return_uart_errors;
    gesture_return_init();tx_length=0u;tx_fifo_count=64u;tx_busy=0u;
    assert(gesture_return_send(RETURN_LEFT,7u)==0);
    gesture_return_hand_marker(1u,320*256,180*256);
    gesture_return_hand_marker(1u,639*256,359*256);
    gesture_return_service();
    assert(tx_length==0u); /* Full FIFO keeps the ordinary event queued. */
    tx_fifo_count=0u;gesture_return_service();
    assert(tx_length==15u&&tx_stream[3]==GESTURE_RETURN_TYPE_GESTURE_EVENT);
    complete_uart();
    assert(tx_length==27u&&tx_stream[18]==GESTURE_RETURN_TYPE_HAND_MARKER);
    assert(tx_stream[23]==(uint8_t)(119u|(67u<<7))&&tx_stream[24]==(67u>>1));
    complete_uart();gesture_return_init();
    gesture_return_frames_queued=queued_before;gesture_return_frames_sent=sent_before;
    gesture_return_frames_dropped=dropped_before;gesture_return_uart_errors=errors_before;

    // Browser record enters the same UART queue/serializer used by gestures.
    before = tx_length;
    web_record[0] = 0x78u; web_record[1] = 0x56u;
    web_record[2] = 0x34u; web_record[3] = 0x12u;
    web_record[4] = GESTURE_RETURN_TYPE_VIDEO_MODE_SET;
    web_record[5] = 1u; web_record[6] = 2u;
    web_length = 7u; web_position = 0u;
    gesture_return_service();
    assert(web_position == web_length);
    assert(tx_length == before + 11u);
    assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_VIDEO_MODE_SET);
    assert(tx_stream[before + 8u] == 2u);
    assert(web_status_commits == 1u && web_status_token == 0x12345678u);
    assert((web_status_meta & 0xffu) == 2u);
    complete_uart();
    assert(web_status_commits == 2u && (web_status_meta & 0xffu) == 4u);
    inject_ack((uint16_t)(tx_stream[before + 4u]
                        | ((uint16_t)tx_stream[before + 5u] << 8)), 0u, 0u, 0);
    rx_length = 8u; /* Truncated header must expire before a later ACK arrives. */
    gesture_return_service();
    assert(rx_position == 8u && (web_status_meta & 0xffu) == 4u);
    test_cycles += GESTURE_RETURN_RX_FRAME_TIMEOUT_CYCLES;
    gesture_return_service();
    rx_length = rx_position = 0u;
    append_ack((uint16_t)(tx_stream[before + 4u]
                        | ((uint16_t)tx_stream[before + 5u] << 8)) + 1u,
               0u, 0u, 0);
    append_ack((uint16_t)tx_stream[before + 4u]
             | ((uint16_t)tx_stream[before + 5u] << 8), 0u, 0u, 1);
    append_ack((uint16_t)tx_stream[before + 4u]
             | ((uint16_t)tx_stream[before + 5u] << 8), 0u, 0u, 0);
    gesture_return_service();
    assert(rx_position == rx_length);
    assert((web_status_meta & 0xffu) == GESTURE_RETURN_STATUS_ACCEPTED);
    assert(web_status_token == 0x12345678u);

    // Two browser commands retain separate tokens and cannot overlap ACK waits.
    {
        const uint8_t mode_a[1] = {2u}, mode_b[1] = {3u};
        unsigned first_frame, second_frame;
        web_length = web_position = 0u;
        append_web_command(0x01020304u, GESTURE_RETURN_TYPE_VIDEO_MODE_SET, mode_a, 1u);
        append_web_command(0xa1b2c3d4u, GESTURE_RETURN_TYPE_VIDEO_MODE_SET, mode_b, 1u);
        first_frame = tx_length;
        gesture_return_service();
        assert((uint16_t)tx_stream[first_frame + 6u] == 1u);
        assert(web_position == 7u && tx_length == first_frame + 11u);
        complete_uart();
        second_frame = tx_length;
        gesture_return_service();
        assert(web_position == web_length && tx_length == second_frame);
        assert(web_status_token == 0xa1b2c3d4u);
        append_ack((uint16_t)tx_stream[first_frame + 4u]
                 | ((uint16_t)tx_stream[first_frame + 5u] << 8), 0u, 0u, 0);
        gesture_return_service();
        assert(tx_length == second_frame + 11u);
        assert((uint16_t)tx_stream[second_frame + 6u] == 1u);
        complete_uart();
        append_ack((uint16_t)tx_stream[second_frame + 4u]
                 | ((uint16_t)tx_stream[second_frame + 5u] << 8), 0u, 0u, 0);
        gesture_return_service();
        assert(web_status_token == 0xa1b2c3d4u);
        assert((web_status_meta & 0xffu) == GESTURE_RETURN_STATUS_ACCEPTED);
        assert(saw_web_status(0x01020304u, GESTURE_RETURN_STATUS_ACCEPTED));
        assert(saw_web_status(0xa1b2c3d4u, GESTURE_RETURN_STATUS_ACCEPTED));
    }

    // A second command waits for its own ACK and times out once, without replay.
    before = tx_length;
    web_record[0] = 0x11u; web_record[1] = 0x22u;
    web_record[2] = 0x33u; web_record[3] = 0x44u;
    web_record[4] = GESTURE_RETURN_TYPE_VIDEO_MODE_SET;
    web_record[5] = 1u; web_record[6] = 1u;
    web_length = 7u; web_position = 0u;
    gesture_return_service();
    complete_uart();
    assert(web_status_token == 0x44332211u && (web_status_meta & 0xffu) == 4u);
    test_cycles += GESTURE_RETURN_ACK_TIMEOUT_CYCLES;
    gesture_return_service();
    assert((web_status_meta & 0xffu) == GESTURE_RETURN_STATUS_TIMEOUT);
    assert(tx_length > before && tx_length < before + 22u);

    web_record[0] = 0xddu; web_record[1] = 0xccu;
    web_record[2] = 0xbbu; web_record[3] = 0xaau;
    web_record[4] = GESTURE_RETURN_TYPE_VIDEO_MODE_SET;
    web_record[5] = 1u; web_record[6] = 0u;
    web_length = 7u; web_position = 0u;
    before = tx_length;
    gesture_return_service();
    complete_uart();
    inject_ack((uint16_t)tx_stream[before + 4u]
             | ((uint16_t)tx_stream[before + 5u] << 8), 1u, 2u, 0);
    gesture_return_service();
    assert(web_status_token == 0xaabbccddu);
    assert((web_status_meta & 0xffu) == GESTURE_RETURN_STATUS_REJECTED);
    assert(((web_status_meta >> 8) & 0xffu) == 2u);

    before = tx_length;
    assert(gesture_return_cmd_video_mode(3u) == 0);
    assert(tx_length == before + 11u && tx_stream[before + 3u] == GESTURE_RETURN_TYPE_VIDEO_MODE_SET);
    assert(tx_stream[before + 6u] == 1u && tx_stream[before + 8u] == 3u);
    complete_uart();

    {
        struct gesture_return_view view = {1, 2, 640, 360, 3, 4, 1280, 720,
                                           0x00020000u, 0x00018000u};
        before = tx_length;
        assert(gesture_return_cmd_scene(GESTURE_RETURN_SCENE_WIPE, 1u, 2u) == 0);
        complete_uart();
        assert(gesture_return_cmd_view(&view) == 0);
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_SCENE_SET);
        assert(tx_stream[before + 8u] == GESTURE_RETURN_SCENE_WIPE);
        complete_uart();
        before = tx_length - 34u;
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_VIEW_SET);
        assert(tx_stream[before + 6u] == 24u && tx_stream[before + 8u] == 1u);
        assert(tx_stream[before + 24u] == 0u && tx_stream[before + 25u] == 0u
               && tx_stream[before + 26u] == 2u && tx_stream[before + 27u] == 0u);
    }

    before = tx_length;
    assert(gesture_return_cmd_effect(GESTURE_RETURN_EFFECT_EMBOSS, 0x0055u) == 0);
    complete_uart();
    assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_EFFECT_SET);
    assert(tx_stream[before + 8u] == GESTURE_RETURN_EFFECT_EMBOSS);
    before = tx_length;
    assert(gesture_return_cmd_parameter(GESTURE_RETURN_PARAM_ALPHA, 256) == 0);
    complete_uart();
    assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_PARAMETER_SET);
    assert(tx_stream[before + 8u] == GESTURE_RETURN_PARAM_ALPHA);
    assert(tx_stream[before + 9u] == 0u && tx_stream[before + 10u] == 1u
           && tx_stream[before + 11u] == 0u && tx_stream[before + 12u] == 0u);

    {
        uint8_t lut_data[GESTURE_RETURN_LUT_CHUNK_MAX];
        uint8_t max_payload[GESTURE_RETURN_PAYLOAD_MAX];
        unsigned i;
        for (i = 0; i < sizeof(lut_data); ++i) lut_data[i] = (uint8_t)i;
        for (i = 0; i < sizeof(max_payload); ++i) max_payload[i] = (uint8_t)(255u - i);
        before = tx_length;
        assert(gesture_return_cmd_lut_chunk(GESTURE_RETURN_LUT_CURVE, 0x12345678u,
                                            lut_data, sizeof(lut_data)) == 0);
        assert(tx_length == before + 64u && tx_fifo_count == 64u);
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_LUT_CHUNK);
        assert(tx_stream[before + 6u] == GESTURE_RETURN_PAYLOAD_MAX);
        assert(tx_stream[before + 8u] == GESTURE_RETURN_LUT_CURVE);
        assert(memcmp(tx_stream + before + 14u, lut_data, sizeof(lut_data)) == 0);
        assert(tx_stream[before + 62u] == (uint8_t)gesture_return_crc16(tx_stream + before + 2u, 60u));
        assert(tx_stream[before + 63u] == (uint8_t)(gesture_return_crc16(tx_stream + before + 2u, 60u) >> 8));
        complete_uart();
        before = tx_length;
        assert(gesture_return_cmd_lut_begin(GESTURE_RETURN_LUT_CURVE, 768u, 0x12345678u) == 0);
        complete_uart();
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_LUT_BEGIN);
        assert(tx_stream[before + 8u] == GESTURE_RETURN_LUT_CURVE);
        assert(tx_stream[before + 9u] == 0u && tx_stream[before + 10u] == 3u);
        before = tx_length;
        assert(gesture_return_cmd_lut_commit(GESTURE_RETURN_LUT_CURVE, 9u, 0x12345678u) == 0);
        complete_uart();
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_LUT_COMMIT);
        assert(tx_stream[before + 9u] == 9u && tx_stream[before + 10u] == 0u);
        before = tx_length;
        assert(gesture_return_cmd_config_begin(0x2345u, 3u) == 0);
        complete_uart();
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_CONFIG_BEGIN);
        assert(tx_stream[before + 8u] == 0x45u && tx_stream[before + 9u] == 0x23u);
        before = tx_length;
        assert(gesture_return_cmd_config_commit(0x2345u, 0x11223344u) == 0);
        complete_uart();
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_CONFIG_COMMIT);
        assert(tx_stream[before + 10u] == 0x44u && tx_stream[before + 13u] == 0x11u);
        before = tx_length;
        assert(gesture_return_cmd_caps_query(1u, 2u) == 0);
        complete_uart();
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_CAPS_QUERY);
        assert(tx_stream[before + 8u] == 1u && tx_stream[before + 9u] == 2u);
        before = tx_length;
        assert(gesture_return_cmd_status_query(0x78563412u) == 0);
        complete_uart();
        assert(tx_stream[before + 3u] == GESTURE_RETURN_TYPE_STATUS_QUERY);
        assert(tx_stream[before + 8u] == 0x12u && tx_stream[before + 11u] == 0x78u);
        before = tx_length;
        assert(gesture_return_enqueue(GESTURE_RETURN_TYPE_STATUS_REPORT, max_payload,
                                      sizeof(max_payload)) == 0);
        assert(tx_length == before + GESTURE_RETURN_FRAME_MAX);
        assert(tx_stream[before + 6u] == GESTURE_RETURN_PAYLOAD_MAX);
        complete_uart();
        assert(gesture_return_enqueue(GESTURE_RETURN_TYPE_STATUS_REPORT, max_payload,
                                      GESTURE_RETURN_PAYLOAD_MAX + 1u) == -1);
        assert(gesture_return_cmd_video_mode(4u) == -1);
    }

    tx_fifo_count = 60u;
    before = tx_length;
    assert(gesture_return_send(RETURN_RIGHT, 7u) == 0);
    assert(tx_fifo_count == 64u && tx_length == before + 4u);
    drain_fifo();
    gesture_return_service();
    assert(tx_length == before + 15u && tx_fifo_count == 11u);
    drain_fifo();
    gesture_return_service();
    assert(gesture_return_frames_sent == 20u);

    tx_fifo_count = 64u;
    assert(gesture_return_send(RETURN_LEFT, 1u) == 0);
    assert(gesture_return_send(RETURN_RIGHT, 2u) == 0);
    assert(gesture_return_send(RETURN_LEFT, 3u) == 0);
    assert(gesture_return_send(RETURN_RIGHT, 4u) == 0);
    assert(gesture_return_send(RETURN_LEFT, 5u) == -2);
    assert(gesture_return_frames_dropped == 2u);
    tx_fifo_count=tx_busy=0;web_position=web_length;tx_length=0;test_cycles=0;
    gesture_return_init();
    gesture_return_prompt(0,1);complete_uart();assert(tx_length==15 && tx_stream[8]==RETURN_CANCEL);
    gesture_return_prompt(0,2);assert(tx_length==15);
    gesture_return_prompt(1,3);complete_uart();assert(tx_length==30 && tx_stream[23]==RETURN_READY);
    gesture_return_prompt(1,4);assert(tx_length==30);
    test_cycles=50000000u;gesture_return_prompt(1,5);complete_uart();assert(tx_length==45 && tx_stream[38]==RETURN_READY);
    gesture_return_prompt(0,6);complete_uart();assert(tx_length==60 && tx_stream[53]==RETURN_CANCEL);
    test_cycles+=50000000u;gesture_return_prompt(0,7);assert(tx_length==60);
    /* New absolute commands pass the same queue/CRC and per-token ACK path. */
    tx_length=tx_fifo_count=tx_busy=0; web_position=web_length; test_cycles=0;
    gesture_return_init();
    assert(gesture_return_cmd_pause(2u)==-1);
    assert(gesture_return_cmd_pause(1u)==0); complete_uart();
    assert(tx_length==11u && tx_stream[3]==2u && tx_stream[8]==1u);
    assert(tx_stream[9]==(uint8_t)gesture_return_crc16(tx_stream+2,7));
    assert(tx_stream[10]==(uint8_t)(gesture_return_crc16(tx_stream+2,7)>>8));
    assert(gesture_return_cmd_ui_set(GESTURE_RETURN_SET_AI,101u)==-1);
    assert(gesture_return_cmd_ui_set(GESTURE_RETURN_SET_WAVE,3u)==-1);
    assert(gesture_return_cmd_ui_set(GESTURE_RETURN_SET_MODEL,28u)==0); complete_uart();
    assert(tx_stream[14]==0x27u && tx_stream[19]==1u && tx_stream[20]==28u);
    tx_length=tx_fifo_count=tx_busy=0;web_length=web_position=0;
    web_status_commits=0;gesture_return_init();
    { uint8_t set[2]={GESTURE_RETURN_SET_WAVE,2};
      append_web_command(0x7711u,GESTURE_RETURN_TYPE_UI_SET,set,2); }
    gesture_return_service();complete_uart();
    assert(tx_length==12 && tx_stream[3]==0x27 && tx_stream[8]==5 && tx_stream[9]==2);
    inject_ack(0u,0u,0u,0);gesture_return_service();
    assert(saw_web_status(0x7711u,GESTURE_RETURN_STATUS_ACCEPTED));
    puts("PASS: absolute pause/UI_SET wire encoding and matching web ACK");
    puts("PASS: return protocol CRC, semantic serialization, full 64-byte frames, FIFO backpressure, bounded queue");
    return 0;
}
