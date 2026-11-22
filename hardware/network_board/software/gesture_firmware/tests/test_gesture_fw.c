#include "gesture_fw.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static const int px[21] = {
    112,80,65,49,22, 82,67,53,42, 100,98,96,95,
    120,125,130,135, 138,153,167,180
};
static const int py[21] = {
    200,165,145,126,108, 128,106,83,58, 122,99,75,50,
    122,100,78,56, 128,109,90,70
};

static uint8_t coord_code(int v)
{
    int c = 65 + (v * 256 + 150) / 300;
    if (c < 0) c = 0;
    if (c > 255) c = 255;
    return (uint8_t)c;
}

static void make_result(const struct gesture_roi *roi, uint8_t hand[1], uint8_t handed[1],
                        uint8_t landmarks[63], int dx)
{
    unsigned i;
    hand[0] = 255;
    handed[0] = 170;
    for (i = 0; i < 21; ++i) {
        int local_x = ((px[i] + dx - roi->x) * GESTURE_NPU_W) / (int)roi->side;
        int local_y = ((py[i] - roi->y) * GESTURE_NPU_H) / (int)roi->side;
        landmarks[i * 3] = coord_code(local_x);
        landmarks[i * 3 + 1] = coord_code(local_y);
        landmarks[i * 3 + 2] = 128;
    }
}

static void feed(struct gesture_tracker *t, int dx)
{
    struct gesture_roi roi;
    uint8_t hand[1], handed[1], landmarks[63];
    assert(gesture_tracker_next_roi(t, &roi));
    make_result(&roi, hand, handed, landmarks, dx);
    gesture_tracker_result(t, hand, handed, landmarks);
}

static void feed_hand_code(struct gesture_tracker *t, int dx, uint8_t code)
{
    struct gesture_roi roi;
    uint8_t hand[1], handed[1], landmarks[63];
    assert(gesture_tracker_next_roi(t, &roi));
    make_result(&roi, hand, handed, landmarks, dx);
    hand[0] = code;
    gesture_tracker_result(t, hand, handed, landmarks);
}

static void feed_low_conf_extreme(struct gesture_tracker *t)
{
    struct gesture_roi roi;
    uint8_t hand[1] = {129}, handed[1] = {120}, landmarks[63];
    unsigned i;
    assert(gesture_tracker_next_roi(t, &roi));
    make_result(&roi, hand, handed, landmarks, 0);
    hand[0] = 129;
    for (i = 0; i < sizeof(landmarks); ++i) landmarks[i] = 255;
    gesture_tracker_result(t, hand, handed, landmarks);
}

static void consume_no_hand(struct gesture_tracker *t)
{
    uint8_t hand[1] = {55}, handed[1] = {120}, landmarks[63] = {0};
    t->pending_valid = 1;
    gesture_tracker_result(t, hand, handed, landmarks);
}

static void prime_locked_tracker(struct gesture_tracker *t)
{
    struct gesture_roi roi;
    uint8_t hand[1] = {255}, handed[1] = {160}, landmarks[63];
    unsigned i;
    gesture_tracker_init(t, 640, 360);
    assert(gesture_tracker_next_roi(t, &roi));
    make_result(&roi, hand, handed, landmarks, 0);
    gesture_tracker_result(t, hand, handed, landmarks);
    assert(t->state == GESTURE_ACQUIRE);
    assert(gesture_tracker_next_roi(t, &roi));
    make_result(&roi, hand, handed, landmarks, 0);
    gesture_tracker_result(t, hand, handed, landmarks);
    assert(t->state == GESTURE_TRACK);
    for (i = 0; i < 5; ++i) feed(t, 0);
    assert(t->gesture_waiting);
}

static void feed_closed(struct gesture_tracker *t)
{
    struct gesture_roi roi;uint8_t hand[1],handed[1],landmarks[63];
    assert(gesture_tracker_next_roi(t,&roi));make_result(&roi,hand,handed,landmarks,0);
    for(unsigned root=5;root<=17;root+=4){
        landmarks[(root+3)*3]=landmarks[root*3];
        landmarks[(root+3)*3+1]=landmarks[root*3+1];
    }
    gesture_tracker_result(t,hand,handed,landmarks);
}

/* Synthetic OK in frame coordinates, encoded through the real INT8 decoder. */
static void feed_ok(struct gesture_tracker *t, uint8_t confidence, int bad)
{
    struct gesture_roi roi;
    uint8_t hand[1], handed[1], landmarks[63];
    assert(gesture_tracker_next_roi(t, &roi));
    make_result(&roi, hand, handed, landmarks, 0);
    /* Bend index into a ring; thumb tip touches index tip. */
    const int ids[4] = {4, 6, 7, 8};
    const int xs[4] = {55, 65, 50, 55}, ys[4] = {100, 95, 90, 100};
    for (unsigned k=0;k<4;k++) {
        landmarks[ids[k]*3] = coord_code((xs[k]-roi.x)*224/(int)roi.side);
        landmarks[ids[k]*3+1] = coord_code((ys[k]-roi.y)*224/(int)roi.side);
    }
    if (bad == 1) { /* separated thumb: pinch must fail */
        landmarks[4*3] = landmarks[17*3];
        landmarks[4*3+1] = landmarks[17*3+1];
    }
    if (bad == 2) { /* curled middle finger: direct length zero */
        landmarks[12*3] = landmarks[9*3];
        landmarks[12*3+1] = landmarks[9*3+1];
    }
    if (bad == 3) { /* ring collapsed at index root: span must fail */
        landmarks[8*3] = landmarks[4*3] = landmarks[5*3];
        landmarks[8*3+1] = landmarks[4*3+1] = landmarks[5*3+1];
    }
    hand[0] = confidence;
    gesture_tracker_result(t, hand, handed, landmarks);
}

static void test_ok(void)
{
    struct gesture_tracker t;
    unsigned i;
    prime_locked_tracker(&t);
    t.gesture_waiting=0; t.open_count=0;
    for (i=0;i<8;i++) feed_ok(&t,255,0);
    assert(!t.gesture_waiting && !t.ok_count);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    /* A stable open palm must precede each OK event. */
    for(i=0;i<3;i++) feed(&t,0);
    assert(t.gesture_waiting);
    feed_ok(&t,255,0); feed_ok(&t,255,0);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    feed_ok(&t,129,0); /* lost confidence breaks consecutive OK */
    feed_ok(&t,255,0); feed_ok(&t,255,0);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    feed_ok(&t,255,0);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_OK);
    assert(!t.gesture_waiting && t.ok_latched);
    for(i=0;i<12;i++) feed_ok(&t,255,0);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    /* Two release frames, then OK: still latched. */
    feed(&t,0); feed(&t,0); feed_ok(&t,255,0);
    assert(t.ok_latched);
    for(i=0;i<3;i++) feed(&t,0);
    assert(!t.ok_latched && !t.gesture_waiting);
    for(i=0;i<3;i++) feed(&t,0);
    assert(t.gesture_waiting);
    for(i=0;i<3;i++) feed_ok(&t,255,0);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_OK);
    gesture_tracker_reset_scan(&t);
    assert(!t.ok_count && !t.ok_release_count && !t.ok_latched && !t.gesture_waiting);
    for(int bad=1;bad<=3;bad++) {
        prime_locked_tracker(&t);
        for(i=0;i<5;i++) feed_ok(&t,255,bad);
        assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    }
    /* OK cannot finish a pending swipe confirmation. */
    prime_locked_tracker(&t);
    feed(&t,-60); feed_ok(&t,255,0); feed(&t,-60);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    feed(&t,-60);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_LEFT);
    puts("PASS: palm -> OK debounce, confidence gap, release/rearm, negatives and swipe isolation");
}

int main(void)
{
    struct gesture_tracker t;
    struct gesture_roi roi;
    unsigned i;
    test_ok();

    {
        uint8_t hand[1], handed[1] = {120}, landmarks[63] = {0};
        struct gesture_result decoded;
        uint32_t previous = 0;
        for (i = 0; i < 256; ++i) {
            hand[0] = (uint8_t)i;
            gesture_decode_outputs(hand, handed, landmarks, &decoded);
            assert(decoded.conf_q16 >= previous);
            previous = decoded.conf_q16;
            assert((decoded.conf_q16 >= 655u) == (i >= 58));
            assert((decoded.conf_q16 >= 22938u) == (i >= 132));
            assert((decoded.conf_q16 >= 42598u) == (i >= 155));
        }
        previous = 0;
        for (i = 0; i < 256; ++i) {
            hand[0] = 143;
            handed[0] = (uint8_t)i;
            gesture_decode_outputs(hand, handed, landmarks, &decoded);
            assert(decoded.handed_q16 >= previous);
            previous = decoded.handed_q16;
        }
    }

    gesture_tracker_init(&t, 640, 360);
    {
        uint8_t hand[1], handed[1], landmarks[63];
        assert(gesture_tracker_next_roi(&t, &roi));
        make_result(&roi, hand, handed, landmarks, 0);
        hand[0] = 57; /* Below the first-search threshold. */
        gesture_tracker_result(&t, hand, handed, landmarks);
        assert(t.state == GESTURE_POLL && !t.gesture_waiting);
        assert(gesture_tracker_next_roi(&t, &roi));
        make_result(&roi, hand, handed, landmarks, 0);
        hand[0] = 58; /* Search candidate starts acquire, never READY. */
        gesture_tracker_result(&t, hand, handed, landmarks);
        assert(t.state == GESTURE_ACQUIRE && !t.gesture_waiting);
    }

    gesture_tracker_init(&t, 640, 360);
    assert(t.window_count == 31);
    assert(gesture_tracker_next_roi(&t, &roi));
    assert(roi.kind == GESTURE_ROI_POLL && roi.x == -47 && roi.y == -26 && roi.side == 306);
    consume_no_hand(&t);
    assert(t.state == GESTURE_POLL && !t.gesture_waiting);
    for (i = 0; i < 4; ++i) {
        assert(gesture_tracker_next_roi(&t, &roi));
        assert(roi.kind == GESTURE_ROI_POLL);
        consume_no_hand(&t);
    }
    assert(gesture_tracker_next_roi(&t, &roi));
    assert(roi.y == 80 && roi.x == -47);
    consume_no_hand(&t);
    for (i = 6; i < 31; ++i) {
        assert(gesture_tracker_next_roi(&t, &roi));
        consume_no_hand(&t);
    }
    assert(roi.side == 216);

    prime_locked_tracker(&t);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_NONE);
    {
        int32_t x_q8,y_q8;uint32_t saved_conf=t.conf_q16;
        assert(gesture_tracker_position_q8(&t,&x_q8,&y_q8));
        assert(x_q8>=0&&x_q8<640*256&&y_q8>=0&&y_q8<360*256);
        t.conf_q16=22937u;
        assert(gesture_tracker_position_q8(&t,&x_q8,&y_q8));
        t.conf_q16=saved_conf;
    }
    feed_hand_code(&t,0,129); feed_hand_code(&t,0,129);
    assert(t.state == GESTURE_TRACK);
    assert(t.gesture_waiting && t.marker_valid);
    feed_hand_code(&t,0,129);
    assert(t.state == GESTURE_TRACK && t.gesture_waiting && t.marker_valid);
    feed_hand_code(&t,0,129);
    assert(t.state == GESTURE_TRACK && t.gesture_waiting && !t.marker_valid);
    feed(&t,0);
    assert(t.state == GESTURE_TRACK && t.gesture_waiting && t.marker_valid);
    for (i = 0; i < 5; ++i) feed_hand_code(&t,0,129);
    assert(t.state == GESTURE_TRACK && t.gesture_waiting);
    feed(&t,0);
    assert(t.state == GESTURE_TRACK && t.gesture_waiting);
    {
        int32_t reliable_x[21], reliable_y[21];
        memcpy(reliable_x, t.points_x_q8, sizeof(reliable_x));
        memcpy(reliable_y, t.points_y_q8, sizeof(reliable_y));
        for (i = 0; i < 5; ++i) {
            feed_low_conf_extreme(&t);
            assert(t.state == GESTURE_TRACK);
            assert(memcmp(reliable_x, t.points_x_q8, sizeof(reliable_x)) == 0);
            assert(memcmp(reliable_y, t.points_y_q8, sizeof(reliable_y)) == 0);
        }
        feed(&t, 0);
        assert(t.state == GESTURE_TRACK);
        assert(t.points_x_q8[0] != 255);
    }
    for (i = 0; i < 6; ++i) feed_hand_code(&t,0,129);
    assert(t.state == GESTURE_POLL && !t.gesture_waiting && !t.marker_valid);

    prime_locked_tracker(&t);
    for (i = 0; i < 12; ++i) {
        feed(&t, (i & 1u) ? 4 : -4);
        assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_NONE);
    }
    assert(t.gesture_waiting && !t.gesture_latched);
    feed_closed(&t); feed_closed(&t); feed_closed(&t); feed_closed(&t); feed_closed(&t);
    assert(t.gesture_waiting);
    feed(&t,0);
    assert(t.gesture_waiting);
    for (i = 0; i < 6; ++i) feed_closed(&t);
    assert(!t.gesture_waiting && !t.gesture_latched);

    prime_locked_tracker(&t);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_NONE);
    feed(&t, -60);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_NONE);
    feed(&t, -60);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_LEFT);
    feed(&t, -60); feed(&t, -60);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_NONE);
    feed(&t, 0); feed(&t, 0); feed(&t, 0);
    feed(&t, 60);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_NONE);
    feed(&t, 60);
    assert(gesture_tracker_take_event(&t) == GESTURE_EVENT_RIGHT);
    prime_locked_tracker(&t);
    for (i = 0; i < 5; ++i) feed_closed(&t);
    assert(t.gesture_waiting);
    feed_closed(&t);assert(!t.gesture_waiting && !t.gesture_latched);
    assert(gesture_tracker_take_event(&t)==GESTURE_EVENT_NONE);
    printf("PASS: scan/no-hand, Q16 hysteresis, READY grace, marker hold/hide, stable left/right swipe latch\n");
    return 0;
}
