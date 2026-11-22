#ifndef GESTURE_RETURN_PROTOCOL_H
#define GESTURE_RETURN_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define GESTURE_RETURN_PROTOCOL_VERSION 1u
#define GESTURE_RETURN_SYNC0 0xa5u
#define GESTURE_RETURN_SYNC1 0x5au
#define GESTURE_RETURN_TYPE_GESTURE_EVENT 0x01u
#define GESTURE_RETURN_TYPE_PAUSE_SET 0x02u
#define GESTURE_RETURN_TYPE_UI_SET 0x27u
#define GESTURE_RETURN_SET_MODEL 1u
#define GESTURE_RETURN_SET_TABLE 2u
#define GESTURE_RETURN_SET_AI 3u
#define GESTURE_RETURN_SET_FX 4u
#define GESTURE_RETURN_SET_WAVE 5u
#define GESTURE_RETURN_TYPE_VIDEO_MODE_SET 0x10u
#define GESTURE_RETURN_TYPE_SCENE_SET 0x11u
#define GESTURE_RETURN_TYPE_VIEW_SET 0x12u
#define GESTURE_RETURN_TYPE_EFFECT_SET 0x13u
#define GESTURE_RETURN_TYPE_PARAMETER_SET 0x14u
#define GESTURE_RETURN_TYPE_LUT_BEGIN 0x15u
#define GESTURE_RETURN_TYPE_LUT_CHUNK 0x16u
#define GESTURE_RETURN_TYPE_LUT_COMMIT 0x17u
#define GESTURE_RETURN_TYPE_CONFIG_BEGIN 0x18u
#define GESTURE_RETURN_TYPE_CONFIG_COMMIT 0x19u
#define GESTURE_RETURN_TYPE_CAPS_QUERY 0x20u
#define GESTURE_RETURN_TYPE_CAPS_REPORT 0x21u
#define GESTURE_RETURN_TYPE_STATUS_QUERY 0x22u
#define GESTURE_RETURN_TYPE_STATUS_REPORT 0x23u
#define GESTURE_RETURN_TYPE_ACK 0x30u
#define GESTURE_RETURN_TYPE_UI_POINTER 0x24u
#define GESTURE_RETURN_TYPE_UI_ACTION 0x25u
#define GESTURE_RETURN_TYPE_HAND_MARKER 0x26u
#define GESTURE_RETURN_EVENT_LEFT 0x01u
#define GESTURE_RETURN_EVENT_RIGHT 0x02u
#define GESTURE_RETURN_EVENT_READY 0x03u
#define GESTURE_RETURN_EVENT_CANCEL 0x04u
#define GESTURE_RETURN_PAYLOAD_EVENT_BYTES 5u
#define GESTURE_RETURN_FRAME_MAX 64u
#define GESTURE_RETURN_PAYLOAD_MAX (GESTURE_RETURN_FRAME_MAX - 10u)
#define GESTURE_RETURN_LUT_CHUNK_MAX 48u
#define GESTURE_RETURN_QUEUE_DEPTH 4u
#define GESTURE_RETURN_ACK_TIMEOUT_CYCLES 50000000u
#define GESTURE_RETURN_RX_FRAME_TIMEOUT_CYCLES 5000000u
#define GESTURE_RETURN_STATUS_ACCEPTED 5u
#define GESTURE_RETURN_STATUS_REJECTED 7u
#define GESTURE_RETURN_STATUS_TIMEOUT 10u

enum gesture_return_scene { GESTURE_RETURN_SCENE_WIPE = 1u };
enum gesture_return_video_mode { GESTURE_RETURN_VIDEO_1080P30 = 0u,
    GESTURE_RETURN_VIDEO_720P30 = 1u, GESTURE_RETURN_VIDEO_480P30 = 2u,
    GESTURE_RETURN_VIDEO_480P60 = 3u };
enum gesture_return_effect { GESTURE_RETURN_EFFECT_DIRECT = 0u,
    GESTURE_RETURN_EFFECT_LINE = 4u, GESTURE_RETURN_EFFECT_COMIC = 5u,
    GESTURE_RETURN_EFFECT_EMBOSS = 6u };
#define GESTURE_RETURN_EFFECT_COLOR_MASK 0x0003u
#define GESTURE_RETURN_EFFECT_PRESERVE  0x0004u
#define GESTURE_RETURN_EFFECT_LUT       0x0008u
#define GESTURE_RETURN_EFFECT_EMBOSS_DIR_MASK 0x0030u
#define GESTURE_RETURN_EFFECT_EMBOSS_REVERSE  0x0040u
enum gesture_return_parameter { GESTURE_RETURN_PARAM_SATURATION = 1u,
    GESTURE_RETURN_PARAM_SATURATION_OUT, GESTURE_RETURN_PARAM_ALPHA,
    GESTURE_RETURN_PARAM_AI_ALPHA, GESTURE_RETURN_PARAM_AI_ENABLE,
    GESTURE_RETURN_PARAM_COLOR_MIN, GESTURE_RETURN_PARAM_COLOR_MAX,
    GESTURE_RETURN_PARAM_EDGE_THRESHOLD, GESTURE_RETURN_PARAM_LINE_COLOR,
    GESTURE_RETURN_PARAM_BACKGROUND, GESTURE_RETURN_PARAM_ST_LO,
    GESTURE_RETURN_PARAM_ST_HI };
enum gesture_return_lut_kind { GESTURE_RETURN_LUT_CURVE = 0u,
    GESTURE_RETURN_LUT_COLOR = 1u };

struct gesture_return_view {
    /* Serialized in this order: source/destination rect u16, then Q16.16 scales. */
    uint16_t src_x, src_y, src_width, src_height;
    uint16_t dst_x, dst_y, dst_width, dst_height;
    uint32_t scale_x_16_16, scale_y_16_16;
};

/* Frame: A5 5A, version, type, seqLE16, lengthLE16, payload, CRC16LE.
 * CRC-16/CCITT-FALSE covers version through the final payload byte. */
uint16_t gesture_return_crc16(const uint8_t *data, size_t length);
size_t gesture_return_encode(uint8_t type, uint16_t sequence,
                             const uint8_t *payload, uint16_t payload_length,
                             uint8_t *output, size_t output_capacity);
int gesture_return_enqueue(uint8_t type, const uint8_t *payload, uint16_t payload_length);
/* Latest-value-only 16px HDMI grid position; x=127 encodes hidden. */
void gesture_return_hand_marker(unsigned valid, int32_t x_q8, int32_t y_q8);
int gesture_return_enqueue_web(uint32_t token, uint8_t type,
                              const uint8_t *payload, uint16_t payload_length);
int gesture_return_cmd_video_mode(uint8_t mode);
/* Absolute pause, effective only in board1 WAVE PRO. Never toggles. */
int gesture_return_cmd_pause(uint8_t paused);
int gesture_return_cmd_ui_set(uint8_t field, uint8_t value);
int gesture_return_cmd_scene(enum gesture_return_scene scene, uint8_t source_a,
                             uint8_t source_b);
int gesture_return_cmd_view(const struct gesture_return_view *view);
int gesture_return_cmd_effect(enum gesture_return_effect effect, uint16_t flags);
int gesture_return_cmd_parameter(enum gesture_return_parameter id, int32_t value);
int gesture_return_cmd_lut_begin(enum gesture_return_lut_kind kind,
                                 uint16_t byte_count, uint32_t crc32);
int gesture_return_cmd_lut_chunk(enum gesture_return_lut_kind kind,
                                 uint32_t offset, const uint8_t *bytes, uint8_t count);
int gesture_return_cmd_lut_commit(enum gesture_return_lut_kind kind,
                                  uint16_t generation, uint32_t crc32);
int gesture_return_cmd_config_begin(uint16_t transaction, uint8_t command_count);
int gesture_return_cmd_config_commit(uint16_t transaction, uint32_t frame_boundary);
int gesture_return_cmd_caps_query(uint8_t min_version, uint8_t max_version);
int gesture_return_cmd_status_query(uint32_t requested_groups);

/* Debug counters: sent means the local transmitter reached wire-idle; it does
 * not indicate that a peer received or applied the command. */
extern volatile uint32_t gesture_return_frames_queued;
extern volatile uint32_t gesture_return_frames_sent;
extern volatile uint32_t gesture_return_frames_dropped;
extern volatile uint32_t gesture_return_uart_errors;

#endif
