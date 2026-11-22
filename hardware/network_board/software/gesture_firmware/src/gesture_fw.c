#include "gesture_fw.h"

#define Q16 65536LL
#define Q8 256LL
#define T_POLL_Q16 655u        /* 0.01 */
#define T_LOCK_Q16 42598u      /* 0.65 */
#define T_LOST_Q16 22938u      /* 0.35 */
/* Temporary board-test adjustment: permit finger chain/direct ratios below 1.50. */
#define PALM_STRAIGHT_NUM 2
#define PALM_STRAIGHT_DEN 3
#define PALM_SPREAD_MIN_AVG_Q8 (12u * 256u)
#define PALM_THUMB_NUM 10
#define PALM_THUMB_DEN 9
#define OK_PINCH_PCT 45u
#define OK_SPAN_PCT 25u
#define OK_STRAIGHT_PCT 130u
#define OK_STABLE_FRAMES 3u
#define OK_RELEASE_FRAMES 3u
#define OPEN_STABLE_FRAMES 3
#define LOST_FRAMES 6
#define READY_LOST_FRAMES 6
#define MARKER_HOLD_FRAMES 3
#define ACQUIRE_MAX 12
#define SWIPE_CONFIRM_FRAMES 2
#define SWIPE_RETURN_FRAMES 3
#define SWIPE_DELTA_TENTHS 45

static const int palm_ids[7] = {0, 5, 9, 13, 17, 1, 2};
static const int finger_roots[4] = {5, 9, 13, 17};
static const int finger_tips[4] = {8, 12, 16, 20};
static const int finger_mid1[4] = {6, 10, 14, 18};
static const int finger_mid2[4] = {7, 11, 15, 19};

/* Q16 sigmoid samples at |x| = 0, 0.5, ..., 8. Linear interpolation keeps
 * the deployed INT8 logits in the same probability domain as the model. */
static const uint16_t sigmoid_half_q16[17] = {
    32768, 40793, 47911, 53581, 57724, 60565, 62428, 63615, 64357,
    64816, 65097, 65269, 65374, 65438, 65476, 65500, 65514
};

static uint32_t sigmoid_q16(int32_t logit_q16)
{
    uint32_t mag = (uint32_t)(logit_q16 < 0 ? -logit_q16 : logit_q16);
    uint32_t p;
    if (mag >= 8u * 65536u) return logit_q16 < 0 ? 0u : 65536u;
    {
        uint32_t index = mag >> 15;
        uint32_t fraction = mag & 32767u;
        uint32_t low = sigmoid_half_q16[index];
        uint32_t delta = sigmoid_half_q16[index + 1u] - low;
        p = low + ((delta * fraction) >> 15);
    }
    return logit_q16 < 0 ? 65536u - p : p;
}

static uint64_t isqrt_u64(uint64_t x)
{
    uint64_t r = 0, bit = (uint64_t)1 << 62;
    while (bit > x) bit >>= 2;
    while (bit != 0) {
        if (x >= r + bit) {
            x -= r + bit;
            r = (r >> 1) + bit;
        } else r >>= 1;
        bit >>= 2;
    }
    return r;
}

static uint64_t distance_q8(int32_t ax, int32_t ay, int32_t bx, int32_t by)
{
    int64_t dx = (int64_t)ax - bx, dy = (int64_t)ay - by;
    return isqrt_u64((uint64_t)(dx * dx + dy * dy));
}

/* Integer atan2 approximation, returned in degrees*256. Maximum error is
 * below one degree over the 0..180 degree range used for adjacent fingers. */
static uint32_t angle_q8(uint64_t cross, int64_t dot)
{
    uint64_t ad = dot < 0 ? (uint64_t)(-dot) : (uint64_t)dot;
    uint32_t z, base, rad_q16, result;
    uint32_t c, a;
    if (ad == 0) return 90u * 256u;
    /* Scale the ratio into 16-bit operands so RV32 needs no 64-bit divider. */
    while (cross > 0xffffu || ad > 0xffffu) { cross >>= 1; ad >>= 1; }
    c = (uint32_t)cross; a = (uint32_t)ad;
    if (c <= a) z = (c << 16) / a;
    else z = (a << 16) / c;
    base = 51472u + (17891u * (65536u - z) >> 16);
    rad_q16 = z * base >> 16;
    result = rad_q16 * 14669u >> 16;
    if (cross > ad) result = 90u * 256u - result;
    if (dot < 0) result = 180u * 256u - result;
    return (uint32_t)result;
}

static int clamp_i32(int64_t x, int32_t lo, int32_t hi)
{
    if (x < lo) return lo;
    if (x > hi) return hi;
    return (int)x;
}

static int open_palm(const int32_t *x, const int32_t *y, uint32_t *width_q8)
{
    uint32_t widest = (uint32_t)distance_q8(x[5], y[5], x[17], y[17]);
    uint32_t chain, direct;
    int32_t vx[4], vy[4];
    uint32_t spread_sum_q8 = 0;
    int i, straight = 1, spread, thumb = 0;
    if (widest < 4u * Q8) return 0;
    for (i = 0; i < 4; ++i) {
        chain = (uint32_t)distance_q8(x[finger_roots[i]], y[finger_roots[i]],
                               x[finger_mid1[i]], y[finger_mid1[i]])
                 + (uint32_t)distance_q8(x[finger_mid1[i]], y[finger_mid1[i]],
                               x[finger_mid2[i]], y[finger_mid2[i]])
                 + (uint32_t)distance_q8(x[finger_mid2[i]], y[finger_mid2[i]],
                               x[finger_tips[i]], y[finger_tips[i]]);
        direct = (uint32_t)distance_q8(x[finger_roots[i]], y[finger_roots[i]],
                                x[finger_tips[i]], y[finger_tips[i]]);
        vx[i] = x[finger_tips[i]] - x[finger_roots[i]];
        vy[i] = y[finger_tips[i]] - y[finger_roots[i]];
        if (direct == 0 || chain * PALM_STRAIGHT_NUM >= direct * PALM_STRAIGHT_DEN)
            straight = 0;
    }
    for (i = 0; i < 3; ++i) {
        int64_t dot = (int64_t)vx[i] * vx[i + 1] + (int64_t)vy[i] * vy[i + 1];
        int64_t cross_signed = (int64_t)vx[i] * vy[i + 1] - (int64_t)vy[i] * vx[i + 1];
        uint64_t cross = cross_signed < 0 ? (uint64_t)(-cross_signed) : (uint64_t)cross_signed;
        spread_sum_q8 += angle_q8(cross, dot);
    }
    spread = spread_sum_q8 > 3u * PALM_SPREAD_MIN_AVG_Q8;
    thumb = (uint32_t)distance_q8(x[4], y[4], x[5], y[5]) * PALM_THUMB_NUM
          > widest * PALM_THUMB_DEN;
    *width_q8 = (uint32_t)widest;
    return straight && spread && thumb;
}

/* Same scale-independent integer geometry as PC ok_metrics. The index
 * finger bends to form the ring; only the other three must stay straight. */
static int ok_gesture(const int32_t *x, const int32_t *y)
{
    uint32_t palm = (uint32_t)distance_q8(x[5], y[5], x[17], y[17]);
    unsigned i;
    if (palm < 4u * 256u) return 0;
    if ((uint32_t)distance_q8(x[4], y[4], x[8], y[8]) * 100u >= palm * OK_PINCH_PCT
        || (uint32_t)distance_q8(x[5], y[5], x[8], y[8]) * 100u <= palm * OK_SPAN_PCT)
        return 0;
    for (i = 1; i < 4; ++i) {
        unsigned r = (unsigned)finger_roots[i];
        uint32_t chain = (uint32_t)distance_q8(x[r], y[r], x[r+1], y[r+1])
                       + (uint32_t)distance_q8(x[r+1], y[r+1], x[r+2], y[r+2])
                       + (uint32_t)distance_q8(x[r+2], y[r+2], x[r+3], y[r+3]);
        uint32_t direct = (uint32_t)distance_q8(x[r], y[r], x[r+3], y[r+3]);
        if (!direct || chain * 100u >= direct * OK_STRAIGHT_PCT) return 0;
    }
    return 1;
}

static void build_sweep(struct gesture_tracker *t)
{
    static const int32_t scale_q16[2] = {55706, 39322}; /* 0.85, 0.60 */
    const int32_t stride_q16 = 22938;                  /* 0.35 */
    uint32_t s, i, j, n = 0;
    for (s = 0; s < 2; ++s) {
        int64_t side = (int64_t)t->height * scale_q16[s];
        int64_t step = (side * stride_q16) >> 16;
        int64_t nx, ny, offx, offy;
        if (step < 16 * Q16) step = 16 * Q16;
        nx = ((int32_t)t->width * (int32_t)Q16 - (int32_t)side
              + (int32_t)step - 1) / (int32_t)step + 1;
        ny = ((int32_t)t->height * (int32_t)Q16 - (int32_t)side
              + (int32_t)step - 1) / (int32_t)step + 1;
        if (nx < 1) nx = 1;
        if (ny < 1) ny = 1;
        offx = ((int32_t)t->width * (int32_t)Q16
                - (nx - 1) * (int32_t)step - (int32_t)side) / 2;
        offy = ((int32_t)t->height * (int32_t)Q16
                - (ny - 1) * (int32_t)step - (int32_t)side) / 2;
        for (j = 0; j < (uint32_t)ny; ++j) {
            for (i = 0; i < (uint32_t)nx; ++i) {
                struct gesture_scan_window *r;
                if (n >= 64) break;
                r = &t->windows[n++];
                r->x = (offx + (int32_t)i * (int32_t)step) / (int32_t)Q16;
                r->y = (offy + (int32_t)j * (int32_t)step) / (int32_t)Q16;
                r->side = (uint32_t)side / Q16;
            }
        }
    }
    t->window_count = n;
    t->window_index = 0;
    t->state = GESTURE_POLL;
    t->acquire_count = 0;
}

void gesture_tracker_init(struct gesture_tracker *t, uint32_t width, uint32_t height)
{
    unsigned i;
    for (i = 0; i < sizeof(*t); ++i) ((uint8_t *)t)[i] = 0;
    t->width = width;
    t->height = height;
    build_sweep(t);
}

void gesture_tracker_reset_scan(struct gesture_tracker *t)
{
    t->have_seed = 0;
    t->gesture_waiting = 0;
    t->gesture_latched = 0;
    t->open_count = t->lost_gesture_count = t->return_count = t->swipe_count = 0;
    t->ok_count = t->ok_release_count = 0;
    t->ok_latched = 0;
    t->lost_count = 0;
    t->pending_valid = 0;
    t->event = GESTURE_EVENT_NONE;
    t->marker_valid = 0;
    t->marker_age = MARKER_HOLD_FRAMES;
    build_sweep(t);
}

static void poll_to_frame(const struct gesture_roi *r, uint32_t w, uint32_t h,
                          const struct gesture_result *result,
                          int32_t *x, int32_t *y)
{
    unsigned i;
    (void)w; (void)h;
    for (i = 0; i < 21; ++i) {
        x[i] = result->x_q8[i] * (int32_t)r->side / GESTURE_NPU_W + r->x * (int32_t)Q8;
        y[i] = result->y_q8[i] * (int32_t)r->side / GESTURE_NPU_H + r->y * (int32_t)Q8;
    }
}

static int tracked_roi(struct gesture_tracker *t, struct gesture_roi *r)
{
    const int32_t *px = t->state == GESTURE_ACQUIRE ? t->seed_x_q8 : t->points_x_q8;
    const int32_t *py = t->state == GESTURE_ACQUIRE ? t->seed_y_q8 : t->points_y_q8;
    int32_t minx = px[palm_ids[0]], maxx = minx;
    int32_t miny = py[palm_ids[0]], maxy = miny;
    int64_t whx, why, cx, cy, halfx, halfy, bx0, by0, bx1, by1;
    int32_t big_x0, big_y0, big_x1, big_y1, bias_x, bias_y, big_side;
    int32_t padx, pady, x0, y0, x1, y1;
    unsigned i;
    for (i = 1; i < 7; ++i) {
        int p = palm_ids[i];
        if (px[p] < minx) minx = px[p];
        if (px[p] > maxx) maxx = px[p];
        if (py[p] < miny) miny = py[p];
        if (py[p] > maxy) maxy = py[p];
    }
    whx = maxx - minx; why = maxy - miny;
    if (whx < Q8 || why < Q8) return 0;

    /* Match webcam_landmark_poll.infer_tracked's initial 4x palm crop and
     * replicated square padding, which defines the local model-image origin. */
    cx = (minx + maxx) / 2;
    cy = (miny + maxy) / 2;
    big_x0 = clamp_i32((cx - 2 * whx) / Q8, 0, (int32_t)t->width);
    big_x1 = clamp_i32((cx + 2 * whx) / Q8, 0, (int32_t)t->width);
    big_y0 = clamp_i32((cy - 2 * why) / Q8, 0, (int32_t)t->height);
    big_y1 = clamp_i32((cy + 2 * why) / Q8, 0, (int32_t)t->height);
    if (big_x1 <= big_x0 || big_y1 <= big_y0) return 0;
    big_side = big_x1 - big_x0;
    if (big_y1 - big_y0 > big_side) big_side = big_y1 - big_y0;
    bias_x = big_x0 - ((big_side - (big_x1 - big_x0)) / 2);
    bias_y = big_y0 - ((big_side - (big_y1 - big_y0)) / 2);

    minx = maxx = px[palm_ids[0]] - (int64_t)bias_x * Q8;
    miny = maxy = py[palm_ids[0]] - (int64_t)bias_y * Q8;
    for (i = 1; i < 7; ++i) {
        int p = palm_ids[i];
        int64_t px_local = px[p] - (int64_t)bias_x * Q8;
        int64_t py_local = py[p] - (int64_t)bias_y * Q8;
        if (px_local < minx) minx = (int32_t)px_local;
        if (px_local > maxx) maxx = (int32_t)px_local;
        if (py_local < miny) miny = (int32_t)py_local;
        if (py_local > maxy) maxy = (int32_t)py_local;
    }
    whx = maxx - minx; why = maxy - miny;
    if (whx < Q8 || why < Q8) return 0;
    cx = (minx + maxx) / 2;
    cy = (miny + maxy) / 2 - ((int32_t)(why * 2) / 5); /* PALM_BOX_SHIFT=(0,-0.4) */
    halfx = whx * 3 / 2; halfy = why * 3 / 2; /* PALM_BOX_ENLARGE=3 */
    bx0 = cx - halfx; by0 = cy - halfy; bx1 = cx + halfx; by1 = cy + halfy;
    x0 = clamp_i32(bx0 / Q8, 0, big_side);
    y0 = clamp_i32(by0 / Q8, 0, big_side);
    x1 = clamp_i32(bx1 / Q8, 0, big_side);
    y1 = clamp_i32(by1 / Q8, 0, big_side);
    if (x1 <= x0 || y1 <= y0) return 0;
    {
        int32_t cw = x1 - x0, ch = y1 - y0;
        uint32_t side = (uint32_t)(cw > ch ? cw : ch);
        padx = (int32_t)(side - (uint32_t)cw) / 2;
        pady = (int32_t)(side - (uint32_t)ch) / 2;
        r->x = x0 - padx + bias_x;
        r->y = y0 - pady + bias_y;
        r->side = side;
        t->pending_map_center_x_q8 = (x0 + x1) * (int32_t)Q8 / 2 + bias_x * (int32_t)Q8;
        t->pending_map_center_y_q8 = (y0 + y1) * (int32_t)Q8 / 2 + bias_y * (int32_t)Q8;
        t->pending_pad_bias_x_q8 = r->x * (int32_t)Q8;
        t->pending_pad_bias_y_q8 = r->y * (int32_t)Q8;
    }
    r->kind = GESTURE_ROI_TRACK;
    return r->side != 0;
}

int gesture_tracker_next_roi(struct gesture_tracker *t, struct gesture_roi *out)
{
    struct gesture_roi r;
    if (t->pending_valid) return 0;
    if (t->state == GESTURE_POLL) {
        if (t->window_index >= t->window_count) {
            build_sweep(t);
            return 0;
        }
        {
            const struct gesture_scan_window *w = &t->windows[t->window_index++];
            r.x = w->x; r.y = w->y; r.side = w->side; r.kind = GESTURE_ROI_POLL;
        }
    } else {
        if (!tracked_roi(t, &r)) {
            gesture_tracker_reset_scan(t);
            return 0;
        }
    }
    t->pending_roi = r;
    t->pending_valid = 1;
    *out = r;
    return 1;
}

void gesture_decode_outputs(const uint8_t hand[1], const uint8_t handed[1],
                            const uint8_t landmarks[63], struct gesture_result *out)
{
    unsigned i;
    int32_t hand_logit = ((int32_t)hand[0] - 143) * 3539;       /* 0.053990975 * 65536 */
    int32_t handed_logit = ((int32_t)handed[0] - 120) * 1694;   /* 0.025854109 * 65536 */
    out->conf_q16 = sigmoid_q16(hand_logit);
    out->handed_q16 = sigmoid_q16(handed_logit);
    for (i = 0; i < 21; ++i) {
        int32_t x = ((int32_t)landmarks[i * 3] - 65) * 76811 / 256;
        int32_t y = ((int32_t)landmarks[i * 3 + 1] - 65) * 76811 / 256;
        out->x_q8[i] = x;
        out->y_q8[i] = y;
    }
}

static int32_t palm_center_x(const int32_t *x)
{
    int32_t sum = 0;
    unsigned i;
    for (i = 0; i < 7; ++i) sum += x[palm_ids[i]];
    return (int32_t)sum / 7;
}

int gesture_tracker_position_q8(const struct gesture_tracker *t,
                                int32_t *x_q8, int32_t *y_q8)
{
    if (!t || !x_q8 || !y_q8 || !t->marker_valid) return 0;
    *x_q8 = t->marker_x_q8;
    *y_q8 = t->marker_y_q8;
    return 1;
}

static void gesture_ready_lost(struct gesture_tracker *t)
{
    /* A low-confidence/missing result breaks every consecutive confirmation. */
    t->ok_count = t->ok_release_count = 0;
    t->open_count = t->swipe_count = t->return_count = 0;
    if (!t->gesture_waiting) return;
    if (t->lost_gesture_count < READY_LOST_FRAMES) ++t->lost_gesture_count;
    if (t->lost_gesture_count >= READY_LOST_FRAMES) {
        t->gesture_waiting = t->gesture_latched = 0;
        t->open_count = t->swipe_count = t->return_count = 0;
    }
}

static void gesture_update(struct gesture_tracker *t, uint32_t conf)
{
    uint32_t width = 0;
    /* OK takes precedence over the deliberately permissive palm classifier. */
    int ok = conf >= T_LOCK_Q16 && ok_gesture(t->points_x_q8, t->points_y_q8);
    int open = !ok && conf >= T_LOCK_Q16 && open_palm(t->points_x_q8, t->points_y_q8, &width);
    int32_t center = palm_center_x(t->points_x_q8);
    if (t->ok_latched) {
        /* Release requires reliable non-OK observations; missing hands cannot
         * silently rearm. A fresh three-frame open palm is required afterward. */
        if (!ok && conf >= T_LOCK_Q16) {
            if (++t->ok_release_count >= OK_RELEASE_FRAMES) t->ok_latched = 0;
        } else t->ok_release_count = 0;
        return;
    }
    if (ok && t->gesture_waiting) {
        t->swipe_count = t->return_count = 0;
        t->lost_gesture_count = 0;
        if (++t->ok_count >= OK_STABLE_FRAMES) {
            t->event = GESTURE_EVENT_OK;
            t->ok_latched = 1;
            t->ok_release_count = 0;
            t->gesture_waiting = t->gesture_latched = 0;
            t->open_count = t->ok_count = 0;
        }
        return;
    }
    t->ok_count = 0;
    if (!t->gesture_waiting) {
        if (open) {
            if (t->open_count < OPEN_STABLE_FRAMES) ++t->open_count;
            if (t->open_count >= OPEN_STABLE_FRAMES) {
                t->gesture_waiting = 1;
                t->lost_gesture_count=0;
                t->gesture_anchor_x_q8 = center;
                t->gesture_return_x_q8 = center;
                t->gesture_width_q8 = width;
                t->gesture_latched = 0;
                t->swipe_count = t->return_count = 0;
            }
        } else t->open_count = 0;
        return;
    }
    if(!open){
        gesture_ready_lost(t);
        return;
    }
    t->lost_gesture_count=0;
    if (t->gesture_latched) {
        int64_t delta = (int64_t)center - t->gesture_anchor_x_q8;
        if (delta < 0) delta = -delta;
        if ((uint64_t)delta * 4u <= (uint64_t)t->gesture_width_q8) {
            if (++t->return_count >= SWIPE_RETURN_FRAMES) {
                t->gesture_latched = 0;
                t->gesture_anchor_x_q8 = center;
                t->gesture_width_q8 = width ? width : t->gesture_width_q8;
                t->return_count = t->swipe_count = 0;
            }
        } else t->return_count = 0;
        return;
    }
    {
        int64_t delta = (int64_t)center - t->gesture_anchor_x_q8;
        int direction = 0;
        if (delta * 100 <= -(int64_t)t->gesture_width_q8 * SWIPE_DELTA_TENTHS) direction = -1;
        if (delta * 100 >=  (int64_t)t->gesture_width_q8 * SWIPE_DELTA_TENTHS) direction = 1;
        if (direction) {
            if (t->swipe_direction != direction) t->swipe_count = 0;
            t->swipe_direction = direction;
            if (++t->swipe_count >= SWIPE_CONFIRM_FRAMES) {
                t->event = direction < 0 ? GESTURE_EVENT_LEFT : GESTURE_EVENT_RIGHT;
                t->gesture_latched = 1;
                t->gesture_return_x_q8 = t->gesture_anchor_x_q8;
                t->return_count = 0;
                t->swipe_count = 0;
                t->swipe_direction = 0;
            }
        } else t->swipe_count = 0;
    }
}

void gesture_tracker_result(struct gesture_tracker *t, const uint8_t hand[1],
                            const uint8_t handed[1], const uint8_t landmarks[63])
{
    struct gesture_result r;
    unsigned i;
    if (!t->pending_valid) return;
    gesture_decode_outputs(hand, handed, landmarks, &r);
    ++t->inference_count;
    if (t->state == GESTURE_POLL) {
        if (r.conf_q16 >= T_POLL_Q16) {
            poll_to_frame(&t->pending_roi, t->width, t->height, &r,
                          t->seed_x_q8, t->seed_y_q8);
            t->have_seed = 1;
            t->conf_q16 = r.conf_q16;
            t->state = GESTURE_ACQUIRE;
            t->acquire_count = 0;
        }
    } else {
        if (t->state == GESTURE_ACQUIRE || r.conf_q16 >= T_LOST_Q16) {
            if (t->pending_roi.kind == GESTURE_ROI_POLL) {
                poll_to_frame(&t->pending_roi, t->width, t->height, &r,
                              t->points_x_q8, t->points_y_q8);
                for (i = 0; i < 21; ++i) {
                    t->seed_x_q8[i] = t->points_x_q8[i];
                    t->seed_y_q8[i] = t->points_y_q8[i];
                }
            } else {
                uint32_t side = t->pending_roi.side;
                /* Match webcam_landmark_poll._map_back with rotation disabled. */
                for (i = 0; i < 21; ++i) {
                    t->points_x_q8[i] = t->pending_pad_bias_x_q8
                        + r.x_q8[i] * (int32_t)side / GESTURE_NPU_W;
                    t->points_y_q8[i] = t->pending_pad_bias_y_q8
                        + r.y_q8[i] * (int32_t)side / GESTURE_NPU_H;
                }
            }
        }
        t->conf_q16 = r.conf_q16;
        t->handed_q16 = r.handed_q16;
        if (t->state == GESTURE_ACQUIRE) {
            ++t->acquire_count;
            for (i = 0; i < 21; ++i) {
                t->seed_x_q8[i] = t->points_x_q8[i];
                t->seed_y_q8[i] = t->points_y_q8[i];
            }
            if (r.conf_q16 >= T_LOCK_Q16) {
                t->state = GESTURE_TRACK;
                ++t->lock_count;
                t->lost_count = 0;
            } else if (t->acquire_count >= ACQUIRE_MAX) {
                t->state = GESTURE_POLL;
                if (t->window_index >= t->window_count) build_sweep(t);
            }
        } else if (r.conf_q16 < T_LOST_Q16) {
            if (++t->lost_count >= LOST_FRAMES) gesture_tracker_reset_scan(t);
            else gesture_ready_lost(t);
        } else {
            t->lost_count = 0;
            gesture_update(t, r.conf_q16);
        }
    }
    if (t->state == GESTURE_TRACK && t->pending_roi.kind == GESTURE_ROI_TRACK
        && r.conf_q16 >= T_LOST_Q16) {
        int32_t x_q8 = palm_center_x(t->points_x_q8), y_q8 = 0;
        int32_t sum_y = 0;
        for (i = 0; i < 7; ++i) sum_y += t->points_y_q8[palm_ids[i]];
        y_q8 = (int32_t)(sum_y / 7);
        if (t->marker_valid) {
            t->marker_x_q8 = (3 * t->marker_x_q8 + x_q8) / 4;
            t->marker_y_q8 = (3 * t->marker_y_q8 + y_q8) / 4;
        } else {
            t->marker_x_q8 = x_q8;
            t->marker_y_q8 = y_q8;
        }
        t->marker_age = 0;
        t->marker_valid = 1;
    } else if (t->marker_valid) {
        if (t->marker_age <= MARKER_HOLD_FRAMES) ++t->marker_age;
        if (t->marker_age > MARKER_HOLD_FRAMES) t->marker_valid = 0;
    }
    t->pending_valid = 0;
}

enum gesture_event gesture_tracker_take_event(struct gesture_tracker *t)
{
    enum gesture_event e = t->event;
    t->event = GESTURE_EVENT_NONE;
    return e;
}
