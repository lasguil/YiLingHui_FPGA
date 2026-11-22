#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../software/gesture_uart.h"
#include "../software/style_system.h"
#include "../software/style_ui_protocol.h"
#include "../software/style_ui_catalog.h"
#include "../software/style_model_directory.h"

enum { TABLE_SOURCE_BUILTIN=0,TABLE_SOURCE_DDR=1 };
typedef struct { const char *name; uint32_t address; uint8_t source,preset,ready; } test_table_asset;
static const test_table_asset test_tables[]={STYLE_TABLE_ASSET_ROWS};

static uint8_t frame[GESTURE_PROTOCOL_FRAME_MAX];
static unsigned frame_length;
static uint16_t next_sequence;

static uint16_t crc16(const uint8_t *data,unsigned length)
{
    uint16_t crc=0xffffu;
    for(unsigned i=0;i<length;i++){
        crc^=(uint16_t)data[i]<<8;
        for(unsigned bit=0;bit<8;bit++)
            crc=(crc&0x8000u)?(uint16_t)((crc<<1)^0x1021u):(uint16_t)(crc<<1);
    }
    return crc;
}

static void make_frame(uint8_t type,const uint8_t *payload,uint16_t length)
{
    assert(length<=GESTURE_PROTOCOL_FRAME_MAX-10u);
    frame[0]=GESTURE_PROTOCOL_SYNC0;frame[1]=GESTURE_PROTOCOL_SYNC1;
    frame[2]=GESTURE_PROTOCOL_VERSION;frame[3]=type;
    frame[4]=(uint8_t)next_sequence;frame[5]=(uint8_t)(next_sequence>>8);next_sequence++;
    frame[6]=(uint8_t)length;frame[7]=(uint8_t)(length>>8);
    if(length)memcpy(frame+8,payload,length);
    uint16_t crc=crc16(frame+2,6u+length);
    frame[8u+length]=(uint8_t)crc;frame[9u+length]=(uint8_t)(crc>>8);
    frame_length=10u+length;
}

static void send_frame(gesture_uart_parser *parser,style_input_state *state)
{
    static uint32_t now=100u;
    parser->ack_count=0;parser->ack_head=0;parser->ack_pos=0; /* Model an ACK consumer between commands. */
    for(unsigned i=0;i<frame_length;i++){
        now+=8680u;
        gesture_uart_parser_feed(parser,frame[i],now,state);
    }
}

static void test_input_commands_and_gestures(void)
{
    style_input_state s={.scene=3,.table_count=2,.ui_enable=1,.wipe_x=320,
        .ui={.page=STYLE_UI_PAGE_HOME}};
    assert(style_input_command('2',&s)==STYLE_INPUT_NONE&&s.mode==2);
    assert(style_input_command('e',&s)==STYLE_INPUT_NONE&&s.post==1);
    assert(style_input_command('w',&s)==STYLE_INPUT_NONE&&s.scene==2&&s.wipe_x==960);
    assert(style_input_command('v',&s)==STYLE_INPUT_NONE&&s.scene==3);
    assert(style_input_command('p',&s)==STYLE_INPUT_NONE&&s.paused);
    assert(style_input_command('t',&s)==STYLE_INPUT_NONE&&s.table==1);
    assert(style_input_command('u',&s)==STYLE_INPUT_NONE&&!s.ui_enable);
    assert(style_input_command('g',&s)==STYLE_INPUT_NONE&&s.ui.page==STYLE_UI_PAGE_COLOR);
    assert(style_input_command('j',&s)==STYLE_INPUT_NONE&&s.ui.page==STYLE_UI_PAGE_ADJUST);
    assert(style_input_command('k',&s)==STYLE_INPUT_NONE&&s.ui.page==STYLE_UI_PAGE_KEEP);
    assert(style_input_command('c',&s)==STYLE_INPUT_CLEAR);
    assert(style_input_command('d',&s)==STYLE_INPUT_DIAGNOSTICS);

    s=(style_input_state){.scene=2,.ui_enable=1,.wipe_x=960,
        .ui={.fx=100,.ai=95,.sat=195,.out_sat=195,.preserve=1}};
    assert(style_input_action(STYLE_ACTION_FX_PLUS,&s)&&s.ui.fx==100);
    s.ui.ai=0;assert(style_input_action(STYLE_ACTION_AI_MINUS,&s)&&s.ui.ai==0);
    assert(style_input_action(STYLE_ACTION_AI_PLUS,&s)&&s.ui.ai==5);
    s.ui.preserve=0;assert(style_input_action(STYLE_ACTION_SAT_PLUS,&s)&&s.ui.sat==200);
    s.ui.preserve=1;
    assert(!style_input_action(STYLE_ACTION_OUT_PLUS,&s)&&s.ui.out_sat==195);
    s.ui.preserve=0;assert(!style_input_action(STYLE_ACTION_OUT_PLUS,&s)&&s.ui.out_sat==195);
    assert(style_input_action(0,&s)==0&&style_input_action(STYLE_ACTION_WAVE+1,&s)==0);
    assert(style_input_action(STYLE_ACTION_WAVE,&s)&&s.wave==STYLE_WAVE_CORE);
    assert(style_input_action(STYLE_ACTION_WAVE,&s)&&s.wave==STYLE_WAVE_EXT);
    assert(style_input_action(STYLE_ACTION_WAVE,&s)&&s.wave==STYLE_WAVE_OFF);
    assert(style_input_action(STYLE_ACTION_UI_HIDE_ALL,&s)&&s.ui_hidden_all&&!s.ui_enable&&s.ui.page==STYLE_UI_PAGE_HOME);
    assert(style_input_action(STYLE_ACTION_PAUSE,&s)&&s.paused);
    assert(style_input_action(STYLE_ACTION_VFLIP,&s)&&s.vflip);
    assert(!style_input_action(STYLE_ACTION_CLEAN,&s)&&s.ui_hidden_all&&!s.ui_enable);
    assert(style_input_action(STYLE_ACTION_UI_RESTORE,&s)&&!s.ui_hidden_all&&s.ui_enable&&s.ui.page==STYLE_UI_PAGE_HOME);
    static const uint8_t expected_presets[3][6]={{128,255,0,145,0,145},
        {0,75,55,255,0,120},{0,160,0,185,100,255}};
    for(unsigned step=1;step<=6;step++){
        assert(style_input_action(STYLE_ACTION_RANGE,&s));
        unsigned expected=step%3u;
        assert(s.ui.range==expected);
        assert(memcmp(s.ui.bounds,expected_presets[expected],6)==0);
    }
    assert(!style_input_action(STYLE_ACTION_RGB,&s)&&!style_input_action(STYLE_ACTION_B0M,&s));

    s=(style_input_state){.scene=0,.ui_enable=1,.wipe_x=960,.ui={.page=STYLE_UI_PAGE_HOME}};
    ch9350_event local_down={.type=CH9350_DOWN,.id=0,.screen_x=1400,.screen_y=1000,.time_ms=10};
    ch9350_event remote_down={.type=CH9350_DOWN,.id=STYLE_INPUT_REMOTE_TOUCH_ID,.screen_x=1400,.screen_y=1000,.time_ms=11};
    ch9350_event local_up=local_down,remote_up=remote_down;
    local_up.type=remote_up.type=CH9350_UP;local_up.time_ms=20;remote_up.time_ms=21;
    style_input_touch(&local_down,&s,0);style_input_touch(&remote_down,&s,0);
    style_input_touch(&local_up,&s,0);style_input_touch(&remote_up,&s,0);
    assert(!s.paused); /* Each contact toggled PAUSE once; contexts did not splice. */
    remote_down.time_ms=30;style_input_touch(&remote_down,&s,0);
    ch9350_event cancel=remote_down;cancel.type=CH9350_CANCEL;
    style_input_touch(&cancel,&s,1);
    local_down.time_ms=31;style_input_touch(&local_down,&s,0);
    local_up.time_ms=40;style_input_touch(&local_up,&s,0);
    assert(s.paused); /* Cancelling the remote contact leaves a local gesture intact. */
}

static void test_compact_touch_event(void)
{
    ch9350_touch touch={0};ch9350_event event;
    uint8_t report[CH9350_FRAME_BYTES]={0x57,0xab,0x88,0x43,0x41,0x04,0x40,0,0x20,0,0x20};
    for(unsigned i=5;i<=69;i++)report[70]=(uint8_t)(report[70]+report[i]);
    ch9350_touch_init(&touch,NULL);
    for(unsigned i=0;i<sizeof(report);i++)ch9350_touch_feed(&touch,report[i],i);
    assert(ch9350_touch_event_pop(&touch,&event));
    assert(event.type==CH9350_DOWN&&event.id==0);
    assert(event.screen_x>=958&&event.screen_x<=960&&event.screen_y>=538&&event.screen_y<=539);
    assert(!ch9350_touch_event_pop(&touch,&event));
}

static void test_13_table_catalog(void)
{
    style_input_state s={.scene=2,.ui_enable=1,.table=0,.table_count=STYLE_UI_CATALOG_TABLE_SLOTS,
        .ui={.page=STYLE_UI_PAGE_COLOR}};
    assert(sizeof(test_tables)/sizeof(test_tables[0])==13u);
    uint32_t catalog_info=style_ui_catalog_info(STYLE_MODEL_ASSET_COUNT,
        (unsigned)(sizeof(test_tables)/sizeof(test_tables[0])));
    assert((catalog_info&STYLE_UI_COUNT_MODEL_MASK)==26u);
    assert(((catalog_info>>STYLE_UI_COUNT_TABLE_SHIFT)&STYLE_UI_COUNT_TABLE_MASK)==13u);
    assert(test_tables[0].source==TABLE_SOURCE_BUILTIN&&test_tables[0].address==0u);
    assert(strcmp(test_tables[0].name,"IDENTITY")==0);
    for(unsigned i=1;i<13;i++){
        assert(test_tables[i].source==TABLE_SOURCE_DDR&&test_tables[i].ready);
        assert(test_tables[i].address==STYLE_MODEL_DDR_LUT_BASE+(i-1u)*STYLE_LUT_TABLE_BYTES);
        assert(test_tables[i].address>=UINT32_C(0x01c68000));
        assert(test_tables[i].address+STYLE_LUT_TABLE_BYTES<=UINT32_C(0x01c6a400));
    }
    for(unsigned i=1;i<13;i++){
        assert(style_input_action(STYLE_ACTION_TABLE_NEXT,&s)&&s.table==i);
        uint32_t metadata=style_ui_metadata(STYLE_UI_PAGE_COLOR,0,0,s.table,0,0,0,0,0,0);
        assert(((metadata>>STYLE_UI_METADATA_TABLE_INDEX_LOW_SHIFT)&7u)==(i&7u));
        assert(((metadata>>STYLE_UI_METADATA_TABLE_INDEX_BIT3)&1u)==((i>>3)&1u));
        assert(style_ui_catalog_table_index(i)==416u+i*16u);
        if(i>=6u)assert(style_ui_catalog_table_index(i)>=512u);
        if(i==8u)assert(strcmp(test_tables[i].name,"FOREST")==0);
        if(i==12u)assert(strcmp(test_tables[i].name,"INVERT")==0);
    }
    assert(style_input_action(STYLE_ACTION_TABLE_NEXT,&s)&&s.table==0u);
    assert(style_input_action(STYLE_ACTION_TABLE_PREV,&s)&&s.table==12u);
    assert(style_input_action(STYLE_ACTION_TABLE_PREV,&s)&&s.table==11u);
}

static void touch(style_input_state *s,unsigned type,unsigned id,unsigned x,unsigned y,unsigned ms)
{
    ch9350_event e={.type=type,.id=id,.screen_x=x,.screen_y=y,.time_ms=ms};
    style_input_touch(&e,s,0);
}
static void test_absolute_and_sliders(void)
{
    gesture_uart_parser parser={0};
    style_input_state s={.table_count=13,.ui_enable=1,.ui={.page=STYLE_UI_PAGE_ADJUST}};
    uint8_t payload[3]={STYLE_SET_MODEL,25,0};
    make_frame(0x27,payload,2);send_frame(&parser,&s);
    assert(s.model_step==27&&parser.ack[0][10]==0);
    make_frame(0x27,payload,2);send_frame(&parser,&s);assert(s.model_step==27);
    payload[1]=26;make_frame(0x27,payload,2);send_frame(&parser,&s);
    assert(parser.ack[0][10]==1&&s.model_step==27);
    s.paused=1;payload[1]=0;make_frame(0x27,payload,2);send_frame(&parser,&s);
    assert(parser.ack[0][10]==1&&s.model_step==27);s.paused=0;
    for(unsigned field=STYLE_SET_TABLE;field<=STYLE_SET_FX;field++){
        payload[0]=(uint8_t)field;payload[1]=(uint8_t)(field==STYLE_SET_TABLE?12:73);
        make_frame(0x27,payload,2);send_frame(&parser,&s);assert(parser.ack[0][10]==0);
        uint16_t gen=s.generation;
        make_frame(0x27,payload,2);send_frame(&parser,&s);assert(s.generation==gen);
        payload[1]=(uint8_t)(field==STYLE_SET_TABLE?13:101);
        make_frame(0x27,payload,2);send_frame(&parser,&s);assert(parser.ack[0][10]==1);
    }
    assert(s.table==12&&s.ui.ai==73&&s.ui.fx==73);
    payload[0]=0;make_frame(0x27,payload,2);send_frame(&parser,&s);assert(parser.ack[0][10]==1);
    make_frame(0x27,payload,1);send_frame(&parser,&s);assert(parser.ack[0][10]==1);
    make_frame(0x27,payload,3);send_frame(&parser,&s);assert(parser.ack[0][10]==1);
    touch(&s,CH9350_DOWN,0,1384,378,10);assert(s.ui.ai==0);
    touch(&s,CH9350_MOVE,0,1584,378,100);assert(s.ui.ai==50);
    touch(&s,CH9350_UP,0,1919,378,2200);assert(s.ui.ai==100); // long drag/clamp
    touch(&s,CH9350_DOWN,0,1784,474,2300);assert(s.ui.fx==100);
    touch(&s,CH9350_MOVE,0,0,474,2400);assert(s.ui.fx==0);
    touch(&s,CH9350_CANCEL,0,1784,474,2500);assert(s.ui.fx==0);
    touch(&s,CH9350_UP,0,1784,474,2600);assert(s.ui.fx==0);
    touch(&s,CH9350_DOWN,0,1584,378,2700);s.ui.page=STYLE_UI_PAGE_HOME;
    touch(&s,CH9350_UP,0,1784,378,2800);assert(s.ui.ai==50); // changed menu cancels
    s.ui.page=STYLE_UI_PAGE_COLOR;
    touch(&s,CH9350_DOWN,0,1484,810,2900);
    touch(&s,CH9350_UP,0,1684,810,3000);assert(s.ui.fx==0); // no Color slider
    s.ui.page=STYLE_UI_PAGE_ADJUST;
    touch(&s,CH9350_DOWN,0,1384,570,3010);assert(s.ui.sat==0);
    touch(&s,CH9350_MOVE,0,1584,570,3020);assert(s.ui.sat==100);
    touch(&s,CH9350_MOVE,0,1586,570,3030);assert(s.ui.sat==101);
    touch(&s,CH9350_UP,0,1919,570,3040);assert(s.ui.sat==200);
    s.ui.preserve=1;
    touch(&s,CH9350_DOWN,0,1384,570,3050);
    touch(&s,CH9350_UP,0,1384,570,3060);assert(s.ui.sat==200);
    s.ui.preserve=0;s.post=IPX_GRAY_PALETTE;
    touch(&s,CH9350_DOWN,0,1384,570,3070);
    touch(&s,CH9350_UP,0,1384,570,3080);assert(s.ui.sat==200);
    s.post=IPX_RGB_CURVE;
    s.ui.page=STYLE_UI_PAGE_HOME;s.model_step=0;
    touch(&s,CH9350_DOWN,0,1000,400,3100);
    touch(&s,CH9350_UP,0,500,400,3200);assert(s.model_step==1);
}
static unsigned load_calls,load_indices[3],fail_target,fail_restore;
static style_model_asset assets[3]={{"a",1,1,1,1},{"b",2,1,1,1},{"c",3,1,1,1}};
static int load_test(void *context,const style_model_asset *asset)
{
    (void)context;unsigned i=(unsigned)(asset-assets);load_indices[load_calls++]=i;
    return (i==2&&fail_target)||(i==0&&fail_restore)?0:1;
}
static void test_exact_model_load(void)
{
    unsigned next=0;
    assert(style_model_try_select(assets,3,0,2,load_test,NULL,&next)==1);
    assert(next==2&&load_calls==1&&load_indices[0]==2);
    load_calls=0;fail_target=1;next=0;
    assert(style_model_try_select(assets,3,0,2,load_test,NULL,&next)==0);
    assert(next==0&&load_calls==2&&load_indices[0]==2&&load_indices[1]==0);
    load_calls=0;fail_restore=1;
    assert(style_model_try_select(assets,3,0,2,load_test,NULL,&next)==-1);
    load_calls=0;
    assert(style_model_try_select(assets,3,0,0,load_test,NULL,&next)==0&&load_calls==0);
    assert(style_model_try_select(assets,3,0,3,load_test,NULL,&next)==0&&load_calls==0);
}

/* Source selection regression: prepared here, not compiled/run until allowed. */
static void test_wave_sources(void)
{
    style_input_state s={.ui_enable=1,.ui={.preserve=1}};
    gesture_uart_parser parser={0};
    uint8_t event[5]={1,0,0,0,0};
    uint16_t generation=s.generation;
    for(unsigned source=STYLE_WAVE_OFF;source<=STYLE_WAVE_EXT;source++){
        assert(style_input_set(STYLE_SET_WAVE,source,&s)&&s.wave==source);
        assert(s.ui.preserve==1&&s.generation==generation);
        for(unsigned direction=1;direction<=2;direction++){
            s.model_step=0;event[0]=(uint8_t)direction;
            make_frame(0x01,event,5);send_frame(&parser,&s);
            assert(parser.ack[0][10]==0); /* Disabled sources are ACKed, not retried. */
            assert(s.model_step==(source==STYLE_WAVE_EXT?(direction==1?1:-1):0));
            assert(style_input_core_wave_step(source,direction)==
                (source==STYLE_WAVE_CORE?(direction==1?-1:1):0));
        }
        event[0]=3;make_frame(0x01,event,5);send_frame(&parser,&s);
        assert(s.gesture_ready==(source==STYLE_WAVE_EXT));
        uint8_t pause[1]={1};
        make_frame(GESTURE_PROTOCOL_TYPE_PAUSE_SET,pause,1);send_frame(&parser,&s);
        assert(s.paused==(source==STYLE_WAVE_EXT)&&parser.ack[0][10]==0);
        make_frame(GESTURE_PROTOCOL_TYPE_PAUSE_SET,pause,1);send_frame(&parser,&s);
        assert(s.paused==(source==STYLE_WAVE_EXT)); /* Repeated hold does not toggle. */
        if(source==STYLE_WAVE_EXT){
            assert(!s.gesture_ready);
            event[0]=3;make_frame(0x01,event,5);send_frame(&parser,&s);assert(!s.gesture_ready);
        }
        pause[0]=0;make_frame(GESTURE_PROTOCOL_TYPE_PAUSE_SET,pause,1);send_frame(&parser,&s);
        assert(!s.paused&&parser.ack[0][10]==0);
        pause[0]=2;make_frame(GESTURE_PROTOCOL_TYPE_PAUSE_SET,pause,1);send_frame(&parser,&s);
        assert(!s.paused&&parser.ack[0][10]==1);
        make_frame(GESTURE_PROTOCOL_TYPE_PAUSE_SET,pause,0);send_frame(&parser,&s);
        assert(parser.ack[0][10]==1);
        assert(style_input_core_wave_step(source,0)==0&&style_input_core_wave_step(source,3)==0);
        uint32_t bits=style_ui_wave_metadata(source);
        assert((((bits>>15)&1u)<<1|((bits>>16)&1u))==source);
        assert(!(bits&~((1u<<15)|(1u<<16)))&&!(bits&(1u<<17)));
        uint8_t set[2]={STYLE_SET_WAVE,(uint8_t)source};
        make_frame(0x27,set,2);send_frame(&parser,&s);assert(parser.ack[0][10]==0&&s.wave==source);
    }
    assert(!style_input_set(STYLE_SET_WAVE,3,&s)&&s.wave==STYLE_WAVE_EXT);
    assert(style_input_action(STYLE_ACTION_WAVE,&s)&&s.wave==STYLE_WAVE_OFF&&!s.gesture_ready);
    assert(style_input_action(STYLE_ACTION_WAVE,&s)&&s.wave==STYLE_WAVE_CORE);
    assert(style_input_action(STYLE_ACTION_WAVE,&s)&&s.wave==STYLE_WAVE_EXT);
    uint8_t action[1]={STYLE_ACTION_WAVE};
    make_frame(0x25,action,1);send_frame(&parser,&s);assert(s.wave==STYLE_WAVE_OFF&&parser.ack[0][10]==0);
    /* Explicit remote model selection still works when gestures are OFF. */
    uint8_t set_model[2]={STYLE_SET_MODEL,1};
    make_frame(0x27,set_model,2);send_frame(&parser,&s);assert(s.model_step==3&&parser.ack[0][10]==0);
}

int main(void)
{
    gesture_uart_parser parser={0};
    style_input_state state={.mode=2,.scene=2,.ui_enable=1,.wave=STYLE_WAVE_EXT,.wipe_x=960,.ui={.ai=100,.fx=100,.sat=100,.out_sat=0},.generation=1};
    uint8_t event[5]={1,0x44,0x33,0x22,0x11};
    uint8_t mode[1]={3};
    uint8_t scene[3]={1,1,2};
    uint8_t effect[3]={0,2,0};
    uint8_t parameter[5]={4,0,1,0,0}; /* AI alpha 256 Q8. */
    uint8_t color_min[5]={6,0x11,0x22,0x33,0};
    uint8_t color_max[5]={7,0xaa,0xbb,0xcc,0};
    uint8_t unsupported[1]={0};
    uint8_t ui_action[1]={STYLE_ACTION_MODE};
    uint8_t hand_position[2];
    uint8_t pointer_down[9]={1,0x78,0x05,0xe8,0x03,10,0,0,0}; /* 1400,1000 */
    uint8_t pointer_up[9]={3,0x78,0x05,0xe8,0x03,20,0,0,0};
    uint8_t pointer_bad[9]={1,0x80,0x07,0,0,0,0,0,0}; /* x=1920 */
    uint8_t large_unsupported[GESTURE_PROTOCOL_FRAME_MAX-10u];
    static const uint8_t protocol_vector[]={0xa5,0x5a,0x01,0x01,0x02,0x00,0x05,0x00,
        0x01,0x44,0x33,0x22,0x11,0x9e,0x2c};

    gesture_uart_parser fixed_parser={0};
    style_input_state fixed_state={.wave=STYLE_WAVE_EXT};
    for(unsigned i=0;i<sizeof(protocol_vector);i++)
        gesture_uart_parser_feed(&fixed_parser,protocol_vector[i],100u+i*8680u,&fixed_state);
    assert(fixed_parser.good_frames==1&&fixed_state.model_step==1);
    test_input_commands_and_gestures();
    test_compact_touch_event();
    test_13_table_catalog();
    test_absolute_and_sliders();
    test_exact_model_load();
    test_wave_sources();

    gesture_uart_parser marker_parser={0};
    style_input_state marker_state={.wave=STYLE_WAVE_EXT};
    uint16_t marker=style_hand_marker_pack(119u,67u);
    hand_position[0]=(uint8_t)marker;hand_position[1]=(uint8_t)(marker>>8);
    make_frame(0x26,hand_position,2);send_frame(&marker_parser,&marker_state);
    assert(marker_parser.hand_marker_valid&&marker_parser.hand_marker==marker);
    assert(marker_parser.ack_count==0&&marker_parser.good_frames==1);
    uint32_t marker_time=marker_parser.hand_marker_last_cycles;
    gesture_uart_remote_timeout(&marker_parser,&marker_state,marker_time+UINT32_C(29999999),0);
    assert(marker_parser.hand_marker_valid);
    gesture_uart_remote_timeout(&marker_parser,&marker_state,marker_time+UINT32_C(30000000),0);
    assert(!marker_parser.hand_marker_valid&&marker_parser.hand_marker==GESTURE_HAND_MARKER_INVALID);
    marker=STYLE_HAND_MARKER_INVALID;hand_position[0]=(uint8_t)marker;hand_position[1]=(uint8_t)(marker>>8);
    make_frame(0x26,hand_position,2);send_frame(&marker_parser,&marker_state);
    assert(!marker_parser.hand_marker_valid&&marker_parser.ack_count==0);
    marker=(uint16_t)(120u|(68u<<7));hand_position[0]=(uint8_t)marker;hand_position[1]=(uint8_t)(marker>>8);
    make_frame(0x26,hand_position,2);send_frame(&marker_parser,&marker_state);
    assert(!marker_parser.hand_marker_valid&&marker_parser.ack_count==0);

    make_frame(0x01,event,5);send_frame(&parser,&state);
    assert(state.model_step==1&&state.hint&&parser.good_frames==1);
    make_frame(0x10,mode,1);send_frame(&parser,&state);assert(state.mode==3);
    make_frame(0x11,scene,3);send_frame(&parser,&state);
    assert(parser.unsupported==1&&parser.ack[0][10]==1&&parser.ack[0][11]==2);
    make_frame(0x13,effect,3);send_frame(&parser,&state);
    assert(parser.unsupported==2&&parser.ack[0][10]==1&&parser.ack[0][11]==2);
    make_frame(0x14,parameter,5);send_frame(&parser,&state);
    assert(parser.unsupported==3&&parser.ack[0][10]==1&&parser.ack[0][11]==2);
    assert(state.scene==2&&state.post==0&&state.ui.ai==100);
    make_frame(0x14,color_min,5);send_frame(&parser,&state);
    assert(parser.unsupported==4&&state.ui.bounds[0]==0&&state.ui.bounds[2]==0&&state.ui.bounds[4]==0);
    make_frame(0x14,color_max,5);send_frame(&parser,&state);
    assert(parser.unsupported==5&&state.ui.bounds[1]==0&&state.ui.bounds[3]==0&&state.ui.bounds[5]==0);
    make_frame(0x15,unsupported,1);send_frame(&parser,&state);assert(parser.unsupported==6);
    memset(large_unsupported,0x3c,sizeof(large_unsupported));
    make_frame(0x16,large_unsupported,sizeof(large_unsupported));send_frame(&parser,&state);
    assert(parser.unsupported==7);
    make_frame(0x10,mode,1);send_frame(&parser,&state);assert(state.mode==3);

    make_frame(0x10,mode,1);frame[frame_length-1]^=1u;send_frame(&parser,&state);
    assert(parser.bad_frames==1);
    make_frame(0x10,mode,1);
    for(unsigned i=0;i<frame_length;i++)gesture_uart_parser_feed(&parser,frame[i],2000000u+i,&state);
    unsigned good=parser.good_frames;
    for(unsigned i=0;i<frame_length;i++)gesture_uart_parser_feed(&parser,frame[i],3000000u+i,&state);
    assert(parser.bad_frames==2&&parser.good_frames==good);

    next_sequence=1000u;make_frame(0x01,event,5);send_frame(&parser,&state);
    event[0]=2;next_sequence=0;make_frame(0x01,event,5);send_frame(&parser,&state);
    assert(state.model_step==-1);
    next_sequence=1;make_frame(0x10,mode,1);send_frame(&parser,&state);assert(state.mode==3);

    gesture_uart_parser_feed(&parser,0xa5,5000000u,&state);
    gesture_uart_parser_feed(&parser,0x5a,5000001u,&state);
    gesture_uart_parser_feed(&parser,1,5000002u,&state);
    gesture_uart_parser_feed(&parser,0,7100000u,&state);
    assert(parser.bad_frames==3);

    gesture_uart_parser ui_parser={0};
    style_input_state ui_state={.mode=2,.scene=2,.ui_enable=1,.wave=STYLE_WAVE_EXT,.wipe_x=960,
        .ui={.ai=100,.fx=100,.sat=100,.out_sat=0},.generation=1};
    make_frame(0x25,ui_action,1);send_frame(&ui_parser,&ui_state);
    assert(ui_state.mode==3&&ui_parser.ack_count==1);
    assert(ui_parser.ack[0][0]==GESTURE_PROTOCOL_SYNC0&&ui_parser.ack[0][1]==GESTURE_PROTOCOL_SYNC1);
    assert(ui_parser.ack[0][2]==GESTURE_PROTOCOL_VERSION&&ui_parser.ack[0][3]==0x30);
    assert(ui_parser.ack[0][4]==frame[4]&&ui_parser.ack[0][5]==frame[5]);
    assert(ui_parser.ack[0][6]==4&&ui_parser.ack[0][7]==0);
    assert(ui_parser.ack[0][10]==0&&ui_parser.ack[0][11]==0);
    assert(crc16(ui_parser.ack[0]+2,10)==
        ((uint16_t)ui_parser.ack[0][12]|((uint16_t)ui_parser.ack[0][13]<<8)));
    make_frame(0x24,pointer_down,9);send_frame(&ui_parser,&ui_state);assert(ui_parser.remote_active&&ui_parser.ack[0][10]==0);
    make_frame(0x24,pointer_up,9);send_frame(&ui_parser,&ui_state);assert(!ui_parser.remote_active&&ui_state.paused);
    ui_state.paused=0;pointer_down[5]=30;make_frame(0x24,pointer_down,9);send_frame(&ui_parser,&ui_state);
    gesture_uart_remote_timeout(&ui_parser,&ui_state,ui_parser.remote_last_cycles+UINT32_C(200000000),3000u);
    assert(!ui_parser.remote_active&&!ui_state.paused);
    make_frame(0x24,pointer_bad,9);send_frame(&ui_parser,&ui_state);
    assert(ui_parser.ack[0][10]==1&&ui_parser.ack[0][11]==1);

    uint8_t hide_all[1]={STYLE_ACTION_UI_HIDE_ALL};
    assert(STYLE_ACTION_UI_HIDE_ALL==45&&STYLE_ACTION_UI_RESTORE==46);
    make_frame(0x25,hide_all,1);send_frame(&ui_parser,&ui_state);
    assert(ui_state.ui_hidden_all&&!ui_state.ui_enable&&ui_parser.ack[0][10]==0);
    make_frame(0x25,hide_all,1);send_frame(&ui_parser,&ui_state);
    assert(ui_state.ui_hidden_all&&!ui_state.ui_enable&&ui_parser.ack[0][10]==0); /* 45 is idempotent. */
    ch9350_event hidden_local_down={.type=CH9350_DOWN,.id=0,.screen_x=1400,.screen_y=1000,.time_ms=100};
    ch9350_event hidden_local_up=hidden_local_down;hidden_local_up.type=CH9350_UP;hidden_local_up.time_ms=110;
    style_input_touch(&hidden_local_down,&ui_state,0);style_input_touch(&hidden_local_up,&ui_state,0);
    assert(ui_state.ui_hidden_all&&!ui_state.ui_enable&&!ui_state.paused); /* Local input cannot restore or activate hidden UI. */
    uint8_t restore_pointer[9]={1,0xe0,0x06,0xe8,0x03,0,0,0,0}; /* DOWN at the old SHOW area. */
    make_frame(0x24,restore_pointer,9);send_frame(&ui_parser,&ui_state);
    assert(!ui_parser.remote_active&&ui_parser.ack[0][10]==1&&ui_parser.ack[0][11]==1);
    uint8_t hidden_gesture[5]={1,0,0,0,0};
    make_frame(0x01,hidden_gesture,5);send_frame(&ui_parser,&ui_state);
    assert(ui_state.model_step==1&&ui_parser.ack[0][10]==0);
    uint8_t hidden_vflip[1]={STYLE_ACTION_VFLIP};
    make_frame(0x25,hidden_vflip,1);send_frame(&ui_parser,&ui_state);
    assert(ui_state.vflip&&ui_state.ui_hidden_all&&!ui_state.ui_enable&&ui_parser.ack[0][10]==0); /* Remote effects remain available while hidden. */
    uint8_t restore[1]={STYLE_ACTION_UI_RESTORE};
    make_frame(0x25,restore,1);send_frame(&ui_parser,&ui_state);
    assert(!ui_state.ui_hidden_all&&ui_state.ui_enable&&ui_parser.ack[0][10]==0);
    make_frame(0x25,restore,1);send_frame(&ui_parser,&ui_state);
    assert(!ui_state.ui_hidden_all&&ui_state.ui_enable&&ui_parser.ack[0][10]==0); /* 46 is idempotent. */
    assert(STYLE_MODEL_ASSET_COUNT==26u&&STYLE_UI_CATALOG_MODEL_SLOTS==26u);
    assert(STYLE_UI_CATALOG_TABLE_SLOTS==13u&&STYLE_LUT_ASSET_COUNT==12u);
    uint32_t metadata=style_ui_metadata(STYLE_UI_PAGE_HOME,0,25,12,0,0,0,0,0,0);
    assert(((metadata>>STYLE_UI_METADATA_MODEL_INDEX_LOW_SHIFT)&7u)==(25u&7u));
    assert(((metadata>>STYLE_UI_METADATA_MODEL_INDEX_BIT3)&1u)==((25u>>3)&1u));
    assert(((metadata>>STYLE_UI_METADATA_MODEL_INDEX_BIT4)&1u)==((25u>>4)&1u));
    assert(((metadata>>STYLE_UI_METADATA_TABLE_INDEX_LOW_SHIFT)&7u)==(12u&7u));
    assert(((metadata>>28)&1u)==((12u>>3)&1u));
    uint8_t bad_action[1]={STYLE_ACTION_WAVE+1};
    make_frame(0x25,bad_action,1);
    uint8_t rejected[GESTURE_PROTOCOL_FRAME_MAX];unsigned rejected_length=frame_length;
    memcpy(rejected,frame,rejected_length);
    send_frame(&ui_parser,&ui_state);
    assert(ui_parser.ack[0][4]==rejected[4]&&ui_parser.ack[0][5]==rejected[5]);
    assert(ui_parser.ack[0][10]==1&&ui_parser.ack[0][11]==1);

    uint8_t readiness[5]={3,0,0,0,0};
    make_frame(0x01,readiness,5);send_frame(&parser,&state);
    assert(state.gesture_ready);
    uint32_t lease=parser.gesture_last_cycles;
    gesture_uart_remote_timeout(&parser,&state,lease+499999999u,0);
    assert(state.gesture_ready);
    gesture_uart_remote_timeout(&parser,&state,lease+500000000u,0);
    assert(!state.gesture_ready);
    make_frame(0x01,readiness,5);send_frame(&parser,&state);
    readiness[0]=1;make_frame(0x01,readiness,5);send_frame(&parser,&state);
    assert(!state.gesture_ready);
    readiness[0]=3;make_frame(0x01,readiness,5);send_frame(&parser,&state);
    readiness[0]=4;make_frame(0x01,readiness,5);send_frame(&parser,&state);
    assert(!state.gesture_ready);
    readiness[0]=5;make_frame(0x01,readiness,5);send_frame(&parser,&state);
    assert(!state.gesture_ready && parser.last_ack_status==1u);

    printf("PASS good=%lu bad=%lu unsupported=%lu\n",
           (unsigned long)parser.good_frames,(unsigned long)parser.bad_frames,
           (unsigned long)parser.unsupported);
    return 0;
}
