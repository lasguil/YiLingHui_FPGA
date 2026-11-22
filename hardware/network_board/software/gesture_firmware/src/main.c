#include "gesture_fw.h"
#include "gesture_app.h"
#include "gesture_platform.h"
#include "gesture_flash_loader.h"
#include "model_crc.h"
#include "gesture_return_protocol.h"

#define MODEL_WAIT_SPINS 10000000u
#ifndef DDR_CAL_TIMEOUT_SPINS
#define DDR_CAL_TIMEOUT_SPINS 10000000u
#endif
#ifndef NPU_WAIT_SPINS
#define NPU_WAIT_SPINS 200000000u
#endif
#ifndef ROI_WAIT_SPINS
#define ROI_WAIT_SPINS 50000000u
#endif

volatile uint32_t gesture_last_event;
volatile uint32_t gesture_last_frame;
volatile uint32_t gesture_inference_total;
volatile uint32_t gesture_tracker_state;
volatile uint32_t gesture_video_status;
volatile uint32_t gesture_npu_status;
volatile uint32_t gesture_roi_status;
volatile uint32_t gesture_fatal;
volatile int32_t gesture_return_status;
volatile uint32_t gesture_model_ready;
volatile uint32_t gesture_gesture_waiting;
volatile uint32_t gesture_uart_dropped;
extern volatile uint32_t gesture_return_frames_queued;
extern volatile uint32_t gesture_return_frames_sent;
extern volatile uint32_t gesture_return_frames_dropped;
extern volatile uint32_t gesture_return_uart_errors;

static struct gesture_tracker fw_tracker;
static uint32_t previous_token = 0xffffffffu;
static uint32_t reported_return_dropped;
static uint32_t reported_return_uart_errors;
static int fw_initialized;

static void console_puts(const char *text)
{
    while (*text) {
        if (!gesture_console_putc(*text++)) ++gesture_uart_dropped;
    }
}

static void console_hex(uint32_t value)
{
    int shift;
    for (shift = 28; shift >= 0; shift -= 4) {
        unsigned digit = (value >> shift) & 0xfu;
        char c = (char)(digit < 10u ? '0' + digit : 'A' + digit - 10u);
        if (!gesture_console_putc(c)) ++gesture_uart_dropped;
    }
}

int gesture_dispatch_event(enum gesture_event_code event, uint32_t frame_sequence)
{
    int rc = gesture_return_send(event, frame_sequence);
    gesture_return_status = rc;
    if (rc == 0) {
        console_puts("RETURN_QUEUED code=");
        console_hex((uint32_t)event);
        console_puts(" frame=");
        console_hex(frame_sequence);
        console_puts("\r\n");
    } else {
        console_puts("RETURN_FAIL code=");
        console_hex((uint32_t)event);
        console_puts(" frame=");
        console_hex(frame_sequence);
        console_puts(" rc=");
        console_hex((uint32_t)rc);
        console_puts("\r\n");
    }
    return rc;
}

static uint32_t crc32_ddr(uint32_t address, uint32_t bytes)
{
    uint32_t crc = 0xffffffffu;
    uint32_t i;
    for (i = 0; i < bytes; ++i) {
        unsigned bit;
        crc ^= gesture_ddr_read8(address + i);
        for (bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (uint32_t)-(int32_t)(crc & 1u));
        if ((i & 255u) == 255u) gesture_return_service();
    }
    return ~crc;
}

static int model_is_loaded(void)
{
    return crc32_ddr(GESTURE_WEIGHTS_DDR, MODEL_WEIGHTS_BYTES) == MODEL_WEIGHTS_CRC32
        && crc32_ddr(GESTURE_PARAMS_DDR, MODEL_PARAMS_BYTES) == MODEL_PARAMS_CRC32;
}

int gesture_demo_model_is_loaded(void)
{
    return model_is_loaded();
}

static int wait_npu(void)
{
    uint32_t left = NPU_WAIT_SPINS;
    while (left--) {
        uint32_t s = gesture_mmio_read(GESTURE_NPU_APB_BASE, NPU_REG_STATUS);
        gesture_npu_status = s;
        if (s & NPU_STATUS_ERROR) return -1;
        if ((s & NPU_STATUS_DONE) && !(s & NPU_STATUS_BUSY)) return 0;
        if ((left & 255u) == 0u) gesture_return_service();
    }
    return -2;
}

static int prepare_roi(const struct gesture_roi *roi, uint32_t *selected_token)
{
    uint32_t left = ROI_WAIT_SPINS;
    uint32_t status;
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_CTRL, 2u);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_ROI_X, (uint32_t)roi->x);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_ROI_Y, (uint32_t)roi->y);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_ROI_SIDE, roi->side);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_OUTPUT_BASE, GESTURE_IMAGE_DDR);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_CTRL, 1u);
    *selected_token = gesture_mmio_read(GESTURE_VIDEO_APB_BASE, VIDEO_REG_SELECTED);
    while (left--) {
        status = gesture_mmio_read(GESTURE_VIDEO_APB_BASE, VIDEO_REG_STATUS);
        gesture_roi_status = status;
        if ((status & VIDEO_STATUS_DONE) && !(status & VIDEO_STATUS_BUSY))
            return (status & (VIDEO_STATUS_ERROR | VIDEO_STATUS_CAPTURE_OVERFLOW
                              | VIDEO_STATUS_CAPTURE_ERROR)) ? -1 : 0;
        if ((left & 255u) == 0u) gesture_return_service();
    }
    return -2;
}

static void run_one_inference(struct gesture_tracker *tracker, uint32_t frame_token,
                              const struct gesture_roi *roi)
{
    uint8_t hand[1], handed[1], landmarks[63];
    uint32_t selected = frame_token;
    int roi_was_track = roi->kind == GESTURE_ROI_TRACK;
    unsigned i;
    int roi_rc = prepare_roi(roi, &selected);
    int rc = roi_rc;
    if (roi_rc == -2) {
        gesture_fatal = 0x100u | (gesture_roi_status & 0xffu);
        return;
    }
    if (roi_rc == -1) {
        console_puts("ROI_ERROR status=");
        console_hex(gesture_roi_status);
        console_puts(" token=");
        console_hex(frame_token);
        console_puts("\r\n");
    }
    if (roi_rc == 0) {
        gesture_mmio_read(GESTURE_NPU_APB_BASE, NPU_REG_IRQ); /* W1C/read-clear */
        gesture_mmio_write(GESTURE_NPU_APB_BASE, NPU_REG_CTRL, 1u);
        rc = wait_npu();
    }
    if (roi_rc == 0 && rc == -2) {
        gesture_fatal = 0x200u | (gesture_npu_status & 0xffu);
        return;
    }
    if (roi_rc == 0 && rc == -1) {
        console_puts("NPU_ERROR status=");
        console_hex(gesture_npu_status);
        console_puts(" token=");
        console_hex(frame_token);
        console_puts("\r\n");
    }
    if (roi_rc == 0 && rc == -1 && (gesture_npu_status & NPU_STATUS_BUSY)) {
        gesture_fatal = 0x300u | (gesture_npu_status & 0xffu);
        return;
    }
    if (rc != 0) {
        hand[0] = 55; handed[0] = 120;
        for (i = 0; i < 63; ++i) landmarks[i] = 0;
    } else {
        hand[0] = gesture_ddr_read8(GESTURE_HEAD_HAND_DDR);
        handed[0] = gesture_ddr_read8(GESTURE_HEAD_HANDED_DDR);
        for (i = 0; i < 63; ++i)
            landmarks[i] = gesture_ddr_read8(GESTURE_HEAD_LANDMARK_DDR + i);
    }
    gesture_tracker_result(tracker, hand, handed, landmarks);
    {
        int32_t x_q8=0,y_q8=0;
        int position_valid=(rc==0&&roi_rc==0&&roi_was_track)
            ? gesture_tracker_position_q8(tracker,&x_q8,&y_q8) : 0;
        gesture_return_hand_marker((unsigned)position_valid,x_q8,y_q8);
    }
    ++gesture_inference_total;
    gesture_tracker_state = (uint32_t)tracker->state;
    gesture_gesture_waiting = (uint32_t)tracker->gesture_waiting;
    gesture_last_frame = selected >> 1;
    {
        enum gesture_event event = gesture_tracker_take_event(tracker);
        if (event != GESTURE_EVENT_NONE) {
            gesture_last_event = (uint32_t)event;
            if (event == GESTURE_EVENT_OK) {
                gesture_return_status = gesture_return_cmd_pause(1u);
                console_puts(gesture_return_status == 0 ? "OK_PAUSE_QUEUED\r\n"
                                                       : "OK_PAUSE_FAIL\r\n");
            } else {
                (void)gesture_dispatch_event(
                    event == GESTURE_EVENT_LEFT ? RETURN_LEFT : RETURN_RIGHT, selected >> 1);
            }
        }
    }
}

int gesture_demo_init(void)
{
    if (gesture_mmio_read(GESTURE_NPU_APB_BASE, NPU_REG_VERSION) != NPU_VERSION_EXPECTED)
        return -1;

    /* All descriptor addresses are packed-image offsets; the RTL adds this once. */
    gesture_mmio_write(GESTURE_NPU_APB_BASE, NPU_REG_DDR_OFFSET, GESTURE_DDR_BASE);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_FRAME0, GESTURE_CAPTURE_FRAME0);
    gesture_mmio_write(GESTURE_VIDEO_APB_BASE, VIDEO_REG_FRAME1, GESTURE_CAPTURE_FRAME1);
    gesture_tracker_init(&fw_tracker, GESTURE_FRAME_W, GESTURE_FRAME_H);
    gesture_fatal = gesture_roi_status = gesture_npu_status = gesture_video_status = 0;
    gesture_last_event = gesture_last_frame = gesture_inference_total = 0;
    gesture_tracker_state = GESTURE_POLL;
    gesture_gesture_waiting = 0;
    gesture_return_status = 0;
    gesture_model_ready = 0u;
    gesture_uart_dropped = 0;
    reported_return_dropped = 0;
    reported_return_uart_errors = 0;
    previous_token = 0xffffffffu;
    fw_initialized = 1;
    return 0;
}

void gesture_demo_step(void)
{
    uint32_t token;
    struct gesture_roi roi;
    if (!fw_initialized) return;
    gesture_return_prompt(!gesture_fatal && fw_tracker.gesture_waiting && !fw_tracker.gesture_latched,previous_token>>1);
    gesture_return_service();
    if(gesture_fatal)return;
    if (gesture_return_frames_dropped != reported_return_dropped) {
        reported_return_dropped = gesture_return_frames_dropped;
        console_puts("RETURN_DROP count=");
        console_hex(reported_return_dropped);
        console_puts("\r\n");
    }
    if (gesture_return_uart_errors != reported_return_uart_errors) {
        reported_return_uart_errors = gesture_return_uart_errors;
        console_puts("RETURN_UART_ERROR status=");
        console_hex(reported_return_uart_errors);
        console_puts("\r\n");
    }
    gesture_video_status = gesture_mmio_read(GESTURE_VIDEO_APB_BASE, VIDEO_REG_STATUS);
    token = gesture_mmio_read(GESTURE_VIDEO_APB_BASE, VIDEO_REG_PUBLISHED);
    if (gesture_video_status & VIDEO_STATUS_VIDEO_LOST) {
        gesture_tracker_reset_scan(&fw_tracker);
        gesture_return_hand_marker(0u, 0, 0);
        previous_token = token;
        gesture_tracker_state = GESTURE_POLL;
        gesture_gesture_waiting = 0;
        gesture_return_prompt(0,token>>1);
        return;
    }
    if (!(gesture_video_status & VIDEO_STATUS_FRAME_VALID) || token == previous_token)
        return;
    previous_token = token;
    if (gesture_tracker_next_roi(&fw_tracker, &roi))
        run_one_inference(&fw_tracker, token, &roi);
    gesture_tracker_state = (uint32_t)fw_tracker.state;
    gesture_gesture_waiting = (uint32_t)fw_tracker.gesture_waiting;
    gesture_return_prompt(fw_tracker.gesture_waiting && !fw_tracker.gesture_latched,token>>1);
}

#ifndef GESTURE_APP_NO_MAIN
int main(void)
{
    uint32_t delay;
    uint32_t cal_left = DDR_CAL_TIMEOUT_SPINS;
    int cal_ready = 0;
    int flash_result;
    int loaded = 0;
    gesture_console_init();
    gesture_return_init();
    while (cal_left--) {
        if (gesture_mmio_read(PLATFORM_APB_BASE, 0x04u) & 1u) {
            cal_ready = 1;
            break;
        }
        __asm__ volatile("nop");
    }
    if (!cal_ready) {
        console_puts("DDR_CAL_TIMEOUT\r\n");
        for (;;) __asm__ volatile("wfi");
    }
    if (gesture_demo_init() != 0) {
        console_puts("INIT_ERROR\r\n");
        for (;;) __asm__ volatile("wfi");
    }

    flash_result = gesture_flash_try_load();
    if (flash_result == GESTURE_FLASH_BOOT_OK) loaded = 1;
    if (flash_result == GESTURE_FLASH_BOOT_BAD_CRC)
        console_puts("FLASH_MODEL_CRC_ERROR\r\n");
    else if (flash_result == GESTURE_FLASH_BOOT_IO_ERROR)
        console_puts("FLASH_MODEL_IO_ERROR\r\n");
    else if (flash_result == GESTURE_FLASH_BOOT_NO_HEADER)
        console_puts("FLASH_MODEL_ABSENT\r\n");
    while (!loaded && !model_is_loaded()) {
        for (delay = 0; delay < MODEL_WAIT_SPINS; ++delay) __asm__ volatile("nop");
        gesture_return_service();
    }
    gesture_model_ready = 1u;
    console_puts("MODEL_OK\r\n");
    for (;;) {
        gesture_demo_step();
        if (gesture_fatal) {
            gesture_return_prompt(0,gesture_last_frame);
            console_puts("FATAL code=");
            console_hex(gesture_fatal);
            console_puts(" video=");
            console_hex(gesture_video_status);
            console_puts(" roi=");
            console_hex(gesture_roi_status);
            console_puts(" npu=");
            console_hex(gesture_npu_status);
            console_puts("\r\n");
            /* Inference failure must not disable the independent web/UART bridge. */
            for (;;) gesture_return_service();
        }
        __asm__ volatile("nop");
    }
}
#endif
