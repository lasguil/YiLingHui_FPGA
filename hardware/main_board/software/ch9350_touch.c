#include "ch9350_touch.h"
#include <string.h>

static uint16_t clamp16(uint16_t v,uint16_t hi){return v>hi?hi:v;}
static uint16_t map_axis(uint16_t v,uint16_t lo,uint16_t hi,uint16_t extent){
    uint32_t bounded=v<lo?lo:(v>hi?hi:v);
    uint32_t span=hi>lo?(uint32_t)hi-lo:1u;
    uint32_t out=(bounded-lo)*(extent?extent-1u:0u)/span;
    return (uint16_t)out;
}
static void emit(ch9350_touch *c,uint8_t type,uint8_t id,uint16_t x,uint16_t y,uint32_t now){
    ch9350_event *e;
    if(c->event_count==CH9350_EVENT_CAP){c->stats.event_overflow++;return;}
    e=&c->events[(c->event_head+c->event_count)%CH9350_EVENT_CAP];
    e->type=type;e->id=id;e->time_ms=now;
    e->screen_x=map_axis(x,c->calibration.min_x,c->calibration.max_x,c->calibration.screen_w);
    e->screen_y=map_axis(y,c->calibration.min_y,c->calibration.max_y,c->calibration.screen_h);
    c->event_count++;
}
static void release_id(ch9350_touch *c,unsigned id,uint32_t now){
    if(c->active[id]){emit(c,CH9350_UP,(uint8_t)id,c->last_x[id],c->last_y[id],now);c->active[id]=0;}
}
void ch9350_touch_init(ch9350_touch *c,const ch9350_calibration *cal){
    memset(c,0,sizeof(*c));
    c->calibration=(ch9350_calibration){0,16383,0,16383,1920,1080,250};
    if(cal)c->calibration=*cal;
    c->calibration.max_x=clamp16(c->calibration.max_x,16383);
    c->calibration.max_y=clamp16(c->calibration.max_y,16383);
    if(c->calibration.max_x<=c->calibration.min_x){c->calibration.min_x=0;c->calibration.max_x=16383;}
    if(c->calibration.max_y<=c->calibration.min_y){c->calibration.min_y=0;c->calibration.max_y=16383;}
}
void ch9350_touch_release_all(ch9350_touch *c,uint32_t now){for(unsigned i=0;i<CH9350_TOUCH_IDS;i++)release_id(c,i,now);}
void ch9350_touch_tick(ch9350_touch *c,uint32_t now){
    uint32_t timeout=c->calibration.release_timeout_ms;
    if(!timeout)return;
    for(unsigned i=0;i<CH9350_TOUCH_IDS;i++)if(c->active[i]&&(uint32_t)(now-c->last_seen[i])>=timeout){
        release_id(c,i,now);c->stats.timeout_releases++;
    }
}
int ch9350_touch_event_pop(ch9350_touch *c,ch9350_event *e){
    if(!c->event_count)return 0;
    *e=c->events[c->event_head];c->event_head=(uint8_t)((c->event_head+1u)%CH9350_EVENT_CAP);c->event_count--;return 1;
}
static void consume_touch(ch9350_touch *c,uint32_t now){
    const uint8_t *hid=&c->frame[5];
    uint8_t seen[CH9350_TOUCH_IDS]={0},down[CH9350_TOUCH_IDS]={0};
    uint16_t xs[CH9350_TOUCH_IDS]={0},ys[CH9350_TOUCH_IDS]={0};
    if(hid[0]!=0x04){c->stats.bad_id++;return;}
    if(c->seq_valid){uint8_t delta=(uint8_t)(c->frame[69]-c->last_seq);
        if(delta==0){c->stats.duplicate_sequence++;return;}
        if(delta!=1)c->stats.sequence_gaps+=(uint8_t)(delta-1u);
    }
    c->seq_valid=1;c->last_seq=c->frame[69];c->stats.good_frames++;
    for(unsigned s=0;s<10;s++){
        const uint8_t *p=&hid[1+s*5];uint8_t st=p[0],id=st&0x3f;
        if(st==0 && p[1]==0 && p[2]==0 && p[3]==0 && p[4]==0)continue;
        if(id>=CH9350_TOUCH_IDS){c->stats.invalid_contacts++;continue;}
        if(seen[id]){c->stats.duplicate_contacts++;continue;}
        seen[id]=1;down[id]=(st&0x40)!=0;
        xs[id]=(uint16_t)((p[1]|((uint16_t)p[2]<<8))&0x3fff);
        ys[id]=(uint16_t)((p[3]|((uint16_t)p[4]<<8))&0x3fff);
    }
    for(unsigned id=0;id<CH9350_TOUCH_IDS;id++){
        if(!seen[id]||!down[id]){release_id(c,id,now);continue;}
        if(!c->active[id])emit(c,CH9350_DOWN,(uint8_t)id,xs[id],ys[id],now);
        else if(c->last_x[id]!=xs[id]||c->last_y[id]!=ys[id])emit(c,CH9350_MOVE,(uint8_t)id,xs[id],ys[id],now);
        c->active[id]=1;c->last_x[id]=xs[id];c->last_y[id]=ys[id];c->last_seen[id]=now;
    }
}
static void consume_frame(ch9350_touch *c,uint32_t now){
    uint8_t sum=0;for(unsigned i=5;i<=69;i++)sum=(uint8_t)(sum+c->frame[i]);
    if(sum!=c->frame[70]){c->stats.bad_checksum++;return;}
    if(c->frame[4]!=0x41){c->stats.bad_addr++;return;}
    if(c->frame[5]!=0x04){c->stats.bad_id++;return;}
    consume_touch(c,now);
}
void ch9350_touch_feed(ch9350_touch *c,uint8_t b,uint32_t now){
    ch9350_touch_tick(c,now);
    if(c->used && (uint32_t)(now-c->last_byte_ms)>20u)c->used=0;
    c->last_byte_ms=now;
    if(c->used==0){if(b==0x57){c->frame[0]=b;c->used=1;}else c->stats.noise_bytes++;return;}
    if(c->used==1){if(b==0xab){c->frame[1]=b;c->used=2;}else{c->stats.noise_bytes+=(b==0x57?0u:2u);c->used=0;if(b==0x57){c->frame[0]=b;c->used=1;}}return;}
    if(c->used==2){c->frame[2]=b;if(b==0x82){c->expected=4;}else if(b==0x88){c->expected=CH9350_FRAME_BYTES;}else{c->stats.noise_bytes++;c->used=0;if(b==0x57){c->frame[0]=0x57;c->used=1;}return;}c->used=3;return;}
    if(c->used==3){c->frame[3]=b;if(c->frame[2]==0x82){if(b!=0xa3){c->stats.bad_length++;c->used=0;return;}c->used=0;c->stats.query_frames++;return;}
        if(b!=0x43){c->stats.bad_length++;c->used=0;if(b==0x57){c->frame[0]=0x57;c->used=1;}return;}c->used=4;return;}
    if(c->used<CH9350_FRAME_BYTES)c->frame[c->used++]=b;
    if(c->used==CH9350_FRAME_BYTES){consume_frame(c,now);c->used=0;}
}
