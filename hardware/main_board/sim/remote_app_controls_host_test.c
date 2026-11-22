#include "gesture_return_protocol.h"
#include "gesture_uart.h"
#include <assert.h>
#include <stdio.h>
static gesture_uart_parser parser;
static style_input_state state;
static uint16_t sequence;
static void send_command(uint8_t type,const uint8_t *p,unsigned len,unsigned accepted)
{
    uint8_t frame[64];
    size_t n=gesture_return_encode(type,++sequence,p,(uint16_t)len,frame,sizeof frame);
    assert(n);parser.ack_count=parser.ack_head=parser.ack_pos=0;
    for(size_t i=0;i<n;i++)gesture_uart_parser_feed(&parser,frame[i],sequence*100000u+(uint32_t)i,&state);
    assert(parser.ack_count==1);assert(parser.ack[0][10]==(accepted?0:1));
}
static void set(unsigned field,unsigned value,unsigned accepted)
{uint8_t p[2]={(uint8_t)field,(uint8_t)value};send_command(0x27,p,2,accepted);}
int main(void)
{
    uint8_t pause=1,action;
    state.table_count=13;state.ui_enable=1;state.ui.preserve=1;
    send_command(2,&pause,1,1);assert(!state.paused);
    set(5,1,1);send_command(2,&pause,1,1);assert(!state.paused);
    set(5,2,1);assert(state.wave==2 && state.ui.preserve==1);
    send_command(2,&pause,1,1);assert(state.paused);
    send_command(2,&pause,1,1);assert(state.paused);
    set(1,28,0);set(2,12,1);assert(state.table==12);
    pause=0;send_command(2,&pause,1,1);assert(!state.paused);
    for(unsigned i=0;i<29;i++){set(1,i,1);assert(state.model_step==(int)(i+2));}
    set(1,29,0);set(2,13,0);set(5,3,0);
    set(3,65,1);set(4,20,1);assert(state.ui.ai==65 && state.ui.fx==20);
    set(3,101,0);set(4,101,0);
    action=44;send_command(0x25,&action,1,1);assert(state.vflip);
    action=45;send_command(0x25,&action,1,1);assert(state.ui_hidden_all);
    action=46;send_command(0x25,&action,1,1);assert(!state.ui_hidden_all);
    action=47;send_command(0x25,&action,1,1);assert(state.wave==0);
    /* Manual UI pause is independent of gesture source and idempotent. */
    for(unsigned wave=0;wave<3;wave++){
        set(5,wave,1);set(6,1,1);assert(state.paused);
        set(6,1,1);assert(state.paused);set(6,0,1);assert(!state.paused);
    }
    set(6,2,0);set(7,200,1);assert(state.ui.sat==200);set(7,201,0);
    set(8,1,1);assert(state.ui.preserve);set(8,0,1);assert(!state.ui.preserve);set(8,2,0);
    for(unsigned range=0;range<3;range++){
        set(9,range,1);assert(state.ui.range==range);
    }
    set(9,3,0);set(9,0,1);
    set(10,100,1);set(11,210,1);set(12,20,1);set(13,130,1);set(14,10,1);set(15,120,1);
    assert(state.ui.bounds[0]==100&&state.ui.bounds[5]==120);
    set(10,211,0);set(11,99,0);set(16,1,0);
    action=45;send_command(0x25,&action,1,1);assert(state.ui_hidden_all);
    set(6,1,1);set(7,150,1);set(9,1,1);assert(state.paused&&state.ui.sat==150&&state.ui.range==1&&state.ui_hidden_all);
    puts("PASS: board2 serializer -> latest board1 parser: 29 models, 13 tables, WAVE, idempotent pause, actions44-47, manual pause across WAVE modes, saturation, preserve, RGB presets/bounds");
    return 0;
}
/* No MMIO is involved: only the serializer and parser run in this test. */
uint32_t gesture_test_cycle_count(void) { assert(0); return 0; }
uint32_t gesture_mmio_read(uint32_t base,uint32_t offset) { (void)base;(void)offset;assert(0);return 0; }
void gesture_mmio_write(uint32_t base,uint32_t offset,uint32_t value) { (void)base;(void)offset;(void)value;assert(0); }
