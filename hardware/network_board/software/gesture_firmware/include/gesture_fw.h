#ifndef GESTURE_FW_H
#define GESTURE_FW_H

#include <stdint.h>

#define GESTURE_FRAME_W 640
#define GESTURE_FRAME_H 360
#define GESTURE_NPU_W 224
#define GESTURE_NPU_H 224
#define GESTURE_NPU_CHANNELS_PADDED 32

enum gesture_scan_state { GESTURE_POLL = 0, GESTURE_ACQUIRE = 1, GESTURE_TRACK = 2 };
enum gesture_event { GESTURE_EVENT_NONE = 0, GESTURE_EVENT_LEFT = 1, GESTURE_EVENT_RIGHT = 2, GESTURE_EVENT_OK = 3 };
enum gesture_roi_kind { GESTURE_ROI_POLL = 0, GESTURE_ROI_TRACK = 1 };

struct gesture_roi {
    int32_t x;
    int32_t y;
    uint32_t side;
    enum gesture_roi_kind kind;
};

struct gesture_result {
    int32_t x_q8[21];
    int32_t y_q8[21];
    uint32_t conf_q16;
    uint32_t handed_q16;
};

/* Fixed 640x360 scan windows: coordinates fit signed 16 bits.
 * Keep 64 slots, without redundant per-window ROI kind or 32-bit padding. */
struct gesture_scan_window { int16_t x, y; uint16_t side; };

struct gesture_tracker {
    uint32_t width, height;
    enum gesture_scan_state state;
    struct gesture_roi pending_roi;
    int32_t pending_map_center_x_q8, pending_map_center_y_q8;
    int32_t pending_pad_bias_x_q8, pending_pad_bias_y_q8;
    int pending_valid;
    int have_seed;
    int32_t seed_x_q8[21], seed_y_q8[21];
    int32_t points_x_q8[21], points_y_q8[21];
    uint32_t conf_q16, handed_q16;
    uint32_t lost_count, acquire_count, lock_count, inference_count;
    struct gesture_scan_window windows[64];
    uint32_t window_count, window_index;
    int gesture_waiting, gesture_latched;
    uint32_t open_count, lost_gesture_count, return_count, swipe_count;
    uint32_t ok_count, ok_release_count;
    int ok_latched;
    int swipe_direction;
    int32_t gesture_anchor_x_q8, gesture_return_x_q8;
    uint32_t gesture_width_q8;
    enum gesture_event event;
    int32_t marker_x_q8, marker_y_q8;
    uint32_t marker_age;
    int marker_valid;
};

void gesture_tracker_init(struct gesture_tracker *t, uint32_t width, uint32_t height);
int gesture_tracker_next_roi(struct gesture_tracker *t, struct gesture_roi *out);
void gesture_decode_outputs(const uint8_t hand[1], const uint8_t handed[1],
                            const uint8_t landmarks[63], struct gesture_result *out);
void gesture_tracker_result(struct gesture_tracker *t, const uint8_t hand[1],
                           const uint8_t handed[1], const uint8_t landmarks[63]);
enum gesture_event gesture_tracker_take_event(struct gesture_tracker *t);
int gesture_tracker_position_q8(const struct gesture_tracker *t,
                                int32_t *x_q8, int32_t *y_q8);
void gesture_tracker_reset_scan(struct gesture_tracker *t);

#endif
