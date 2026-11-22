#ifndef CH9350_TOUCH_H
#define CH9350_TOUCH_H
#include <stddef.h>
#include <stdint.h>

#define CH9350_TOUCH_IDS 10u
#define CH9350_EVENT_CAP 32u /* Safe: <=30 events can arise in one 128-byte RX drain. */
#define CH9350_HID_BYTES 65u
#define CH9350_FRAME_BYTES 71u

typedef enum { CH9350_DOWN=1, CH9350_MOVE=2, CH9350_UP=3, CH9350_CANCEL=4 } ch9350_event_type;
typedef struct { uint8_t type, id; uint16_t screen_x, screen_y; uint32_t time_ms; } ch9350_event;
typedef struct {
    uint16_t min_x,max_x,min_y,max_y,screen_w,screen_h;
    uint32_t release_timeout_ms;
} ch9350_calibration;
typedef struct {
    uint32_t good_frames, bad_checksum, bad_id, bad_addr, bad_length, duplicate_sequence;
    uint32_t sequence_gaps, duplicate_contacts, invalid_contacts, query_frames;
    uint32_t event_overflow, noise_bytes, timeout_releases;
} ch9350_stats;
typedef struct {
    uint8_t frame[CH9350_FRAME_BYTES];
    uint8_t used, expected, seq_valid, last_seq;
    uint32_t last_byte_ms;
    uint8_t active[CH9350_TOUCH_IDS];
    uint16_t last_x[CH9350_TOUCH_IDS],last_y[CH9350_TOUCH_IDS];
    uint32_t last_seen[CH9350_TOUCH_IDS];
    ch9350_event events[CH9350_EVENT_CAP];
    uint8_t event_head,event_count;
    ch9350_calibration calibration;
    ch9350_stats stats;
} ch9350_touch;

void ch9350_touch_init(ch9350_touch *ctx, const ch9350_calibration *cal);
void ch9350_touch_feed(ch9350_touch *ctx, uint8_t byte, uint32_t now_ms);
void ch9350_touch_tick(ch9350_touch *ctx, uint32_t now_ms);
int ch9350_touch_event_pop(ch9350_touch *ctx, ch9350_event *event);
void ch9350_touch_release_all(ch9350_touch *ctx, uint32_t now_ms);
#endif
