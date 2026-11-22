#ifndef GESTURE_APP_H
#define GESTURE_APP_H

#include <stdint.h>
#include "gesture_platform.h"

int gesture_demo_init(void);
void gesture_demo_step(void);
int gesture_demo_model_is_loaded(void);

extern volatile uint32_t gesture_last_event;
extern volatile uint32_t gesture_last_frame;
extern volatile uint32_t gesture_inference_total;
extern volatile uint32_t gesture_tracker_state;
extern volatile uint32_t gesture_video_status;
extern volatile uint32_t gesture_npu_status;
extern volatile uint32_t gesture_roi_status;
extern volatile uint32_t gesture_fatal;
extern volatile int32_t gesture_return_status;
extern volatile uint32_t gesture_gesture_waiting;
extern volatile uint32_t gesture_uart_dropped;
int gesture_dispatch_event(enum gesture_event_code event, uint32_t frame_sequence);

#endif
