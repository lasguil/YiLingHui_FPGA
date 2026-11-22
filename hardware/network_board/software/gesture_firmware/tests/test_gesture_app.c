#include "gesture_app.h"
#include "gesture_fw.h"
#include "gesture_platform.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint32_t published = 1;
static uint32_t video_status = VIDEO_STATUS_FRAME_VALID;
static uint32_t roi_status;
static uint32_t npu_status;
static uint32_t roi_mode;
static uint32_t npu_mode;
static uint32_t roi_delay;
static unsigned roi_starts;
static unsigned npu_starts;
static unsigned return_service_calls;
static uint32_t ddr_base_offset;
static uint32_t frame0, frame1;
static uint32_t roi_x, roi_y, roi_side, output_base;
static uint8_t fake_hand_code = 55;
static unsigned fake_pose, pause_calls;
static char console_capture[1024];
static unsigned console_length;
volatile uint32_t gesture_return_frames_queued;
volatile uint32_t gesture_return_frames_sent;
volatile uint32_t gesture_return_frames_dropped;
volatile uint32_t gesture_return_uart_errors;

void gesture_console_init(void) { }

int gesture_console_putc(char value)
{
    if (console_length + 1u < sizeof(console_capture)) {
        console_capture[console_length++] = value;
        console_capture[console_length] = '\0';
    }
    return 1;
}

int gesture_return_send(enum gesture_event_code event, uint32_t frame_sequence)
{
    (void)event;
    (void)frame_sequence;
    return -1;
}

int gesture_return_cmd_pause(uint8_t paused) { assert(paused == 1u); ++pause_calls; return 0; }

void gesture_return_prompt(unsigned ready,uint32_t frame_sequence) {(void)ready;(void)frame_sequence;}
void gesture_return_hand_marker(unsigned valid,int32_t x_q8,int32_t y_q8)
{ (void)valid;(void)x_q8;(void)y_q8; }
void gesture_return_init(void) { }
void gesture_return_service(void) { ++return_service_calls; }
void gesture_ddr_write32(uint32_t address, uint32_t value)
{
    (void)address;
    (void)value;
}

uint32_t gesture_mmio_read(uint32_t base, uint32_t offset)
{
    if (base == GESTURE_NPU_APB_BASE) {
        if (offset == NPU_REG_VERSION) return NPU_VERSION_EXPECTED;
        if (offset == NPU_REG_STATUS) return npu_status;
        return 0;
    }
    assert(base == GESTURE_VIDEO_APB_BASE);
    switch (offset) {
    case VIDEO_REG_STATUS:
        if (roi_mode == 1 && roi_delay) {
            --roi_delay;
            return video_status | VIDEO_STATUS_BUSY;
        }
        return video_status | roi_status;
    case VIDEO_REG_PUBLISHED: return published;
    case VIDEO_REG_SELECTED: return published;
    default: return 0;
    }
}

void gesture_mmio_write(uint32_t base, uint32_t offset, uint32_t value)
{
    if (base == GESTURE_NPU_APB_BASE) {
        if (offset == NPU_REG_DDR_OFFSET) ddr_base_offset = value;
        if (offset == NPU_REG_CTRL && (value & 1u)) {
            ++npu_starts;
            npu_status = npu_mode == 1 ? NPU_STATUS_ERROR
                       : npu_mode == 2 ? NPU_STATUS_BUSY : NPU_STATUS_DONE;
        }
        return;
    }
    assert(base == GESTURE_VIDEO_APB_BASE);
    switch (offset) {
    case VIDEO_REG_CTRL:
        if (value & 2u) roi_status = 0;
        if (value & 1u) {
            ++roi_starts;
            roi_status = roi_mode == 2 ? VIDEO_STATUS_DONE | VIDEO_STATUS_ERROR
                       : roi_mode == 4 ? VIDEO_STATUS_DONE | VIDEO_STATUS_CAPTURE_OVERFLOW
                       : roi_mode == 3 ? VIDEO_STATUS_BUSY
                       : VIDEO_STATUS_DONE;
            roi_delay = roi_mode == 1 ? 2u : 0u;
        }
        break;
    case VIDEO_REG_FRAME0: frame0 = value; break;
    case VIDEO_REG_FRAME1: frame1 = value; break;
    case VIDEO_REG_ROI_X: roi_x = value; break;
    case VIDEO_REG_ROI_Y: roi_y = value; break;
    case VIDEO_REG_ROI_SIDE: roi_side = value; break;
    case VIDEO_REG_OUTPUT_BASE: output_base = value; break;
    default: break;
    }
}

uint8_t gesture_ddr_read8(uint32_t address)
{
    if (address == GESTURE_HEAD_HAND_DDR) return fake_hand_code;
    if (address == GESTURE_HEAD_HANDED_DDR) return 120;
    if (address >= GESTURE_HEAD_LANDMARK_DDR
            && address < GESTURE_HEAD_LANDMARK_DDR + 63u)
    {
        static const int x[21] = {112,80,65,49,22,82,67,53,42,100,98,96,95,120,125,130,135,138,153,167,180};
        static const int y[21] = {200,165,145,126,108,128,106,83,58,122,99,75,50,122,100,78,56,128,109,90,70};
        unsigned n = address-GESTURE_HEAD_LANDMARK_DDR, i=n/3, axis=n%3;
        if (!fake_pose) return 65;
        if (axis==2) return 128;
        int v = axis ? y[i] : x[i];
        if (fake_pose==2) {
            if (i==4 || i==8) v=axis?100:55;
            if (i==6) v=axis?95:65;
            if (i==7) v=axis?90:50;
        }
        int local=(v-(axis?(int32_t)roi_y:(int32_t)roi_x))*224/(int)roi_side;
        int code=65+(local*256+150)/300;
        return (uint8_t)(code<0?0:code>255?255:code);
    }
    return 0;
}

static void publish_next(void)
{
    ++published;
}

int main(void)
{
    assert(gesture_demo_init() == 0);
    assert(ddr_base_offset == GESTURE_DDR_BASE);
    assert(frame0 == GESTURE_CAPTURE_FRAME0 && frame1 == GESTURE_CAPTURE_FRAME1);

    gesture_demo_step();
    assert(roi_starts == 1 && npu_starts == 1);
    assert(output_base == GESTURE_IMAGE_DDR && roi_side != 0);
    assert(roi_x == (uint32_t)-47 && roi_y == (uint32_t)-26);
    assert(gesture_tracker_state == GESTURE_POLL);
    gesture_demo_step();
    assert(roi_starts == 1 && npu_starts == 1); /* same token is not inferred twice */

    roi_mode = 1; /* ROI remains busy for two polls before fresh done */
    publish_next();
    gesture_demo_step();
    assert(roi_starts == 2 && npu_starts == 2);
    assert((gesture_roi_status & (VIDEO_STATUS_DONE | VIDEO_STATUS_BUSY)) == VIDEO_STATUS_DONE);

    roi_mode = 2; /* completed ROI error becomes a no-detection result; NPU is not started */
    publish_next();
    gesture_demo_step();
    assert(roi_starts == 3 && npu_starts == 2);
    assert(gesture_fatal == 0 && (gesture_roi_status & VIDEO_STATUS_ERROR));

    roi_mode = 4; /* capture overflow also suppresses inference */
    publish_next();
    gesture_demo_step();
    assert(roi_starts == 4 && npu_starts == 2);
    assert(gesture_roi_status & VIDEO_STATUS_CAPTURE_OVERFLOW);

    roi_mode = 0;
    npu_mode = 1; /* completed NPU error is decoded as no hand and can be retried */
    publish_next();
    gesture_demo_step();
    assert(npu_starts == 3 && gesture_fatal == 0);
    assert(gesture_npu_status & NPU_STATUS_ERROR);
    assert(strstr(console_capture, "ROI_ERROR status=") != 0);
    assert(strstr(console_capture, "NPU_ERROR status=") != 0);

    video_status = VIDEO_STATUS_VIDEO_LOST;
    gesture_demo_step();
    assert(gesture_tracker_state == GESTURE_POLL && !gesture_gesture_waiting);
    video_status = VIDEO_STATUS_FRAME_VALID;
    npu_mode = 0;
    publish_next();
    gesture_demo_step();
    assert(npu_starts == 4 && gesture_fatal == 0);

    roi_mode = 3; /* timeout with busy ROI parks the real main-loop stepper */
    publish_next();
    gesture_demo_step();
    assert(gesture_fatal != 0 && npu_starts == 4);
    unsigned services_before_fatal_step = return_service_calls;
    gesture_demo_step();
    assert(roi_starts == 7); /* fatal prevents any stale-done retry */
    assert(return_service_calls > services_before_fatal_step);

    assert(gesture_demo_init() == 0);
    roi_mode = 0;
    npu_mode = 2; /* busy NPU timeout also parks before another frame can start it */
    publish_next();
    gesture_demo_step();
    assert(gesture_fatal != 0 && npu_starts == 5);
    assert(gesture_uart_dropped == 0);
    services_before_fatal_step = return_service_calls;
    gesture_demo_step();
    assert(npu_starts == 5);
    assert(return_service_calls > services_before_fatal_step);

    assert(gesture_dispatch_event(RETURN_LEFT, 0x45u) == -1);
    assert(strstr(console_capture, "RETURN_FAIL code=00000001 frame=00000045") != 0);

    assert(gesture_demo_init()==0);
    roi_mode=npu_mode=0; fake_hand_code=255; fake_pose=1;
    for(unsigned i=0;i<7;i++){publish_next();gesture_demo_step();}
    assert(gesture_gesture_waiting && pause_calls==0);
    fake_pose=2;
    for(unsigned i=0;i<2;i++){publish_next();gesture_demo_step();}
    assert(pause_calls==0);
    publish_next();gesture_demo_step();
    assert(pause_calls==1 && gesture_last_event==GESTURE_EVENT_OK);
    for(unsigned i=0;i<8;i++){publish_next();gesture_demo_step();}
    assert(pause_calls==1);
    assert(strstr(console_capture,"OK_PAUSE_QUEUED")!=0);

    puts("PASS: main-loop register simulation covers token scheduling, drop/error recovery, UART diagnostics, and send failure reporting");
    return 0;
}
