#ifndef STYLE_POST_STATE_H
#define STYLE_POST_STATE_H
#include <stdint.h>

typedef struct {
    uint8_t desired;
    uint8_t configured_next;
    uint8_t active_frame;
    uint8_t displayed;
    uint8_t table_desired;
    uint8_t table_configured_next;
    uint8_t table_active_frame;
    uint8_t table_displayed;
} style_post_state;

static inline unsigned style_post_pending(const style_post_state *s)
{ return s->desired!=s->configured_next || s->table_desired!=s->table_configured_next; }

static inline unsigned style_post_configure_next(style_post_state *s)
{
    if(!style_post_pending(s))return 0;
    s->configured_next=s->desired;
    s->table_configured_next=s->table_desired;
    return 1;
}

static inline unsigned style_post_begin_frame(style_post_state *s)
{ s->active_frame=s->configured_next;s->table_active_frame=s->table_configured_next;return s->active_frame; }

static inline unsigned style_post_publish(style_post_state *s)
{ s->displayed=s->active_frame;s->table_displayed=s->table_active_frame;return s->displayed; }

#endif
