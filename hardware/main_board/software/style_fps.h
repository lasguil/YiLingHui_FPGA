#ifndef STYLE_FPS_H
#define STYLE_FPS_H
#include <stdint.h>

typedef struct {
    uint32_t window_cycles;
    uint16_t window_frames;
    uint16_t tenths;
    unsigned started;
    unsigned paused;
    unsigned valid;
} style_fps_state;

/* Feed the current 32-bit 100 MHz mtime low word and 16-bit completed-frame
 * counter. Calls must continue at least once per second while work is busy. */
unsigned style_fps_sample(style_fps_state *state,uint32_t now,uint16_t frames,
                          unsigned paused);
uint16_t style_fps_to_bcd(uint16_t tenths);
#endif
