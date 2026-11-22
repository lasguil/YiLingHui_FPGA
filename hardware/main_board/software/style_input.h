#ifndef STYLE_INPUT_H
#define STYLE_INPUT_H
#include <stdint.h>
#include "ch9350_touch.h"
enum { STYLE_INPUT_NONE=0, STYLE_INPUT_CLEAR=1, STYLE_INPUT_DIAGNOSTICS=2 };
/* Stable wire action IDs used by UI_ACTION; keep this list in A_* order. */
enum {
    STYLE_ACTION_NONE=0, STYLE_ACTION_MODE, STYLE_ACTION_COLOR, STYLE_ACTION_ADJUST,
    STYLE_ACTION_KEEP, STYLE_ACTION_RGB, STYLE_ACTION_VIEW, STYLE_ACTION_PAUSE,
    STYLE_ACTION_CLEAN, STYLE_ACTION_TABLE_PREV, STYLE_ACTION_TABLE_NEXT,
    STYLE_ACTION_COLOR0, STYLE_ACTION_COLOR1, STYLE_ACTION_COLOR2, STYLE_ACTION_COLOR3,
    STYLE_ACTION_FX_MINUS, STYLE_ACTION_FX_PLUS, STYLE_ACTION_AI_MINUS, STYLE_ACTION_AI_PLUS,
    STYLE_ACTION_SAT_MINUS, STYLE_ACTION_SAT_PLUS, STYLE_ACTION_OUT_MINUS, STYLE_ACTION_OUT_PLUS,
    STYLE_ACTION_KEEP_TOGGLE, STYLE_ACTION_RANGE, STYLE_ACTION_RGB_BACK,
    STYLE_ACTION_B0M, STYLE_ACTION_B0P, STYLE_ACTION_B1M, STYLE_ACTION_B1P,
    STYLE_ACTION_B2M, STYLE_ACTION_B2P, STYLE_ACTION_B3M, STYLE_ACTION_B3P,
    STYLE_ACTION_B4M, STYLE_ACTION_B4P, STYLE_ACTION_B5M, STYLE_ACTION_B5P,
    STYLE_ACTION_MODEL_PREV, STYLE_ACTION_MODEL_NEXT, STYLE_ACTION_CLOSE,
    STYLE_ACTION_ADJ_BASIC, STYLE_ACTION_ADJ_KEEP, STYLE_ACTION_RESET, STYLE_ACTION_VFLIP,
    STYLE_ACTION_UI_HIDE_ALL, STYLE_ACTION_UI_RESTORE, STYLE_ACTION_WAVE
};
#define STYLE_INPUT_REMOTE_TOUCH_ID 255u
/* UI_SET (0x27): field u8, absolute value u8. Old action IDs stay stable. */
enum { STYLE_SET_MODEL=1, STYLE_SET_TABLE=2, STYLE_SET_AI=3, STYLE_SET_FX=4,
       STYLE_SET_WAVE=5, STYLE_SET_PAUSE=6, STYLE_SET_SAT=7,
       STYLE_SET_KEEP=8, STYLE_SET_KEEP_RANGE=9, STYLE_SET_BOUND0=10, STYLE_SET_BOUND5=15 };
enum { STYLE_WAVE_OFF=0, STYLE_WAVE_CORE=1, STYLE_WAVE_EXT=2 };
static inline int8_t style_input_core_wave_step(unsigned source,unsigned changes)
{
    if(source!=STYLE_WAVE_CORE||(changes!=1u&&changes!=2u))return 0;
    /* 核心板检测方向与显示交互方向相反；仅交换 LITE，不影响 PRO。 */
    return changes==1u?-1:1;
}
/* Shared touch/renderer geometry: 0..100 maps to x=1384..1784. */
#define STYLE_SLIDER_X0 1384u
#define STYLE_SLIDER_X1 1784u
typedef struct {
    uint8_t ai,fx,sat,out_sat; /* Display percent; saturation is capped at 200%. */
    uint8_t bounds[6],page,preserve,range;
} style_ui_config;
typedef struct {
    uint16_t wipe_x,generation;
    style_ui_config ui;
    uint8_t mode,scene,ui_enable,paused,table,table_count,post,dirty,hint,gesture_ready,vflip,ui_hidden_all,wave; /* STYLE_WAVE_* */
    int8_t model_step; /* -1/+1 relative; 2+index absolute; 0 idle. */
} style_input_state;
unsigned style_input_command(unsigned char key,style_input_state *state);
void style_input_touch(const ch9350_event *event,style_input_state *state,unsigned cancel_event);
unsigned style_input_set(unsigned field,unsigned value,style_input_state *state);
unsigned style_input_action(unsigned action,style_input_state *state);
#endif
