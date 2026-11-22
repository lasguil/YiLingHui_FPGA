#include "style_fps.h"

static unsigned changed(const style_fps_state *s,uint16_t old_value,unsigned old_valid)
{
    return s->tenths!=old_value || s->valid!=old_valid;
}

unsigned style_fps_sample(style_fps_state *s,uint32_t now,uint16_t frames,unsigned paused)
{
    uint16_t old_value=s->tenths;
    unsigned old_valid=s->valid;
    paused=paused!=0u;
    if(!s->started){
        s->started=1;s->window_cycles=now;s->window_frames=frames;s->paused=paused;
        if(paused){s->tenths=0;s->valid=1;}
        return changed(s,old_value,old_valid);
    }
    if(paused!=s->paused){
        s->paused=paused;s->window_cycles=now;s->window_frames=frames;
        s->tenths=0;s->valid=paused;
        return changed(s,old_value,old_valid);
    }
    if(paused)return 0;

    /* Unsigned subtraction is intentional: this low-word delta is wrap safe.
     * The caller samples from poll_controls during every bounded wait, keeping
     * each measurement window far below the 2^31-cycle ambiguity point. */
    uint32_t elapsed=now-s->window_cycles;
    if(elapsed>=UINT32_C(100000000)){
        uint16_t delta=(uint16_t)(frames-s->window_frames);
        uint32_t divisor=elapsed/100u;
        uint32_t scale=UINT32_C(10000000),whole=scale/divisor,part=scale%divisor;
        /* Compute delta*part/divisor in 16 bounded steps. Since part<divisor,
         * the partial remainder stays below 3*divisor (<129M for a 32-bit
         * mtime window), avoiding a costly 64-bit divide in the tiny OCR ROM. */
        uint32_t remainder=0,fraction=0;
        for(int bit=15;bit>=0;bit--){
            remainder=remainder*2u+(((delta>>bit)&1u)?part:0u);
            fraction=fraction*2u;
            while(remainder>=divisor){remainder-=divisor;fraction++;}
        }
        uint32_t value=(uint32_t)delta*whole+fraction;
        if(value>9999u)value=9999u;
        s->tenths=(uint16_t)value;
        s->valid=1;
        s->window_cycles=now;s->window_frames=frames;
    }
    return changed(s,old_value,old_valid);
}

uint16_t style_fps_to_bcd(uint16_t tenths)
{
    if(tenths>9999u)tenths=9999u;
    uint16_t result=0;
    for(unsigned digit=0;digit<4;digit++){
        result|=(uint16_t)((tenths%10u)<<(digit*4u));
        tenths=(uint16_t)(tenths/10u);
    }
    return result;
}
