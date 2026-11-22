#include "gesture_uart.h"
#include "style_system.h"

#define GESTURE_UART_TIMEOUT_CYCLES UINT32_C(2000000) /* 20 ms at 100 MHz. */
#define GESTURE_UART_DUPLICATE_WINDOW UINT32_C(10000000) /* 100 ms at 100 MHz. */
#define GESTURE_UART_RX_ERROR_MASK ((1u<<1)|(1u<<2))

enum {
    TYPE_GESTURE_EVENT=0x01, TYPE_GESTURE_PAUSE_SET=GESTURE_PROTOCOL_TYPE_PAUSE_SET,
    TYPE_VIDEO_MODE_SET=0x10,
    TYPE_UI_POINTER=0x24, TYPE_UI_ACTION=0x25,
    TYPE_HAND_MARKER=0x26, TYPE_UI_SET=0x27, TYPE_ACK=0x30
};

gesture_uart_parser gesture_uart_state;

static uint16_t crc16_ccitt_false(const uint8_t *data, unsigned length)
{
    uint16_t crc=0xffffu;
    for(unsigned i=0;i<length;i++){
        crc^=(uint16_t)data[i]<<8;
        for(unsigned bit=0;bit<8;bit++)
            crc=(crc&0x8000u)?(uint16_t)((crc<<1)^0x1021u):(uint16_t)(crc<<1);
    }
    return crc;
}

static uint16_t get16(const uint8_t *p)
{ return (uint16_t)p[0]|((uint16_t)p[1]<<8); }

static uint32_t get32(const uint8_t *p)
{ return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }

static void ack_enqueue(gesture_uart_parser *parser,uint16_t sequence,uint8_t status,uint8_t error)
{
    unsigned slot;uint8_t *frame;
    uint16_t crc;
    if(parser->ack_count>=GESTURE_UART_ACK_DEPTH){parser->ack_dropped++;return;}
    slot=(parser->ack_head+parser->ack_count)&(GESTURE_UART_ACK_DEPTH-1u);
    frame=parser->ack[slot];
    frame[0]=GESTURE_PROTOCOL_SYNC0;frame[1]=GESTURE_PROTOCOL_SYNC1;
    frame[2]=GESTURE_PROTOCOL_VERSION;frame[3]=TYPE_ACK;
    frame[4]=(uint8_t)sequence;frame[5]=(uint8_t)(sequence>>8);
    frame[6]=4u;frame[7]=0u;
    frame[8]=frame[4];frame[9]=frame[5];frame[10]=status;frame[11]=error;
    crc=crc16_ccitt_false(frame+2u,10u);
    frame[12]=(uint8_t)crc;frame[13]=(uint8_t)(crc>>8);
    parser->ack_count++;
}

static void request_model_step(style_input_state *state,int direction)
{
    if(state->paused){state->hint=1u;return;}
    state->model_step=(int8_t)direction;
    state->hint=1u;
    state->dirty=1u;
}
static void cancel_remote_touch(style_input_state *state,uint32_t time_ms)
{
    ch9350_event event={.type=CH9350_CANCEL,.id=STYLE_INPUT_REMOTE_TOUCH_ID,
        .time_ms=time_ms};
    style_input_touch(&event,state,1u);
}

static int apply_command(gesture_uart_parser *parser,style_input_state *state,uint32_t now_cycles)
{
    const uint8_t *p=parser->bytes+8;
    unsigned length=parser->bytes[6]|((unsigned)parser->bytes[7]<<8);
    unsigned type=parser->bytes[3];

    switch(type){
    case TYPE_UI_POINTER:{
        ch9350_event event;
        if(state->ui_hidden_all)return 0;
        if(length!=9u||p[0]<1u||p[0]>4u)return 0;
        event.screen_x=get16(p+1u);event.screen_y=get16(p+3u);
        if(event.screen_x>1919u||event.screen_y>1079u)return 0;
        if((p[0]==1u&&parser->remote_active)||(p[0]!=1u&&!parser->remote_active))return 0;
        event.type=p[0];event.id=STYLE_INPUT_REMOTE_TOUCH_ID;
        event.time_ms=get32(p+5u);
        style_input_touch(&event,state,0u);
        parser->remote_active=(uint8_t)(p[0]==1u||p[0]==2u);
        parser->remote_last_cycles=now_cycles;
        return 1;
    }
    case TYPE_UI_ACTION:
        if(length!=1u||p[0]<STYLE_ACTION_MODE||p[0]>STYLE_ACTION_WAVE)return 0;
        if(parser->remote_active){cancel_remote_touch(state,0u);parser->remote_active=0;}
        return (int)style_input_action(p[0],state);
    case TYPE_UI_SET:
        if(length!=2u)return 0;
        if(parser->remote_active){cancel_remote_touch(state,0u);parser->remote_active=0;}
        return (int)style_input_set(p[0],p[1],state);
    case TYPE_GESTURE_EVENT:
        if(length!=5u || p[0]<1u || p[0]>4u)return 0;
        state->gesture_ready=(uint8_t)(state->wave==STYLE_WAVE_EXT&&!state->paused&&p[0]==3u);
        parser->gesture_last_cycles=now_cycles;
        /* Valid events from an unselected detector are consumed and ACKed;
         * they must not trigger a switch or provoke sender retries. */
        if(state->wave==STYLE_WAVE_EXT&&p[0]<=2u)request_model_step(state,p[0]==1u?1:-1);
        return 1;
    case TYPE_GESTURE_PAUSE_SET:
        if(length!=1u||p[0]>1u)return 0;
        if(state->wave==STYLE_WAVE_EXT){
            state->gesture_ready=0u;
            if(state->paused!=p[0]){state->paused=p[0];state->dirty=1u;}
        }
        return 1;
    case TYPE_VIDEO_MODE_SET:
        if(length!=1u || p[0]>3u)return 0;
        if(state->mode!=p[0]){state->mode=p[0];state->dirty=1u;}
        return 1;
    case TYPE_HAND_MARKER:{
        unsigned packed,x,y;
        if(length!=2u)return 0;
        packed=(unsigned)p[0]|((unsigned)p[1]<<8);
        x=packed&0x7fu;y=(packed>>7)&0x7fu;
        parser->hand_marker_last_cycles=now_cycles;
        if(state->wave!=STYLE_WAVE_EXT||x==GESTURE_HAND_MARKER_INVALID||x>=120u||y>=68u){
            parser->hand_marker_valid=0u;parser->hand_marker=GESTURE_HAND_MARKER_INVALID;
        }else{
            parser->hand_marker_valid=1u;parser->hand_marker=(uint16_t)packed;
        }
        return 1;
    }
    default:return -1;
    }
}

static void reset_frame(gesture_uart_parser *parser)
{ parser->used=0u;parser->expected=0u; }

static void finish_frame(gesture_uart_parser *parser,style_input_state *state)
{
    unsigned payload_length=parser->bytes[6]|((unsigned)parser->bytes[7]<<8);
    uint16_t sequence=get16(parser->bytes+4u);
    uint16_t got=get16(parser->bytes+8u+payload_length);
    uint16_t expected=crc16_ccitt_false(parser->bytes+2u,6u+payload_length);
    int applied;uint8_t ack_status=0u,ack_error=0u;
    uint8_t no_ack=(uint8_t)(parser->bytes[3]==TYPE_HAND_MARKER);
    if(got!=expected){parser->bad_frames++;return;}
    if(parser->sequence_valid){
        if(sequence==parser->last_sequence && got==parser->last_crc &&
           (uint32_t)(parser->last_byte_cycles-parser->last_frame_cycles)<GESTURE_UART_DUPLICATE_WINDOW){
            parser->bad_frames++;
            if(!no_ack)ack_enqueue(parser,sequence,parser->last_ack_status,parser->last_ack_error);
            return;
        }
    }
    parser->sequence_valid=1u;parser->last_sequence=sequence;parser->last_crc=got;
    parser->last_frame_cycles=parser->last_byte_cycles;
    if(!no_ack&&parser->ack_count>=GESTURE_UART_ACK_DEPTH-1u){applied=-2;ack_status=1u;ack_error=3u;}
    else applied=apply_command(parser,state,parser->last_byte_cycles);
    if(applied>0)parser->good_frames++;
    else if(applied==0){parser->bad_frames++;ack_status=1u;ack_error=1u;}
    else if(applied==-1){parser->unsupported++;ack_status=1u;ack_error=2u;}
    parser->last_ack_status=ack_status;parser->last_ack_error=ack_error;
    if(!no_ack)ack_enqueue(parser,sequence,ack_status,ack_error);
}

void gesture_uart_parser_feed(gesture_uart_parser *parser,uint8_t byte,
                              uint32_t now_cycles,style_input_state *state)
{
    if(parser->used && (uint32_t)(now_cycles-parser->last_byte_cycles)>GESTURE_UART_TIMEOUT_CYCLES){
        parser->bad_frames++;
        reset_frame(parser);
    }
    parser->last_byte_cycles=now_cycles;
    if(parser->used==0u){
        if(byte==GESTURE_PROTOCOL_SYNC0){parser->bytes[0]=byte;parser->used=1u;}
        return;
    }
    if(parser->used==1u){
        if(byte==GESTURE_PROTOCOL_SYNC1){parser->bytes[1]=byte;parser->used=2u;}
        else if(byte==GESTURE_PROTOCOL_SYNC0)parser->bytes[0]=byte;
        else reset_frame(parser);
        return;
    }
    if(parser->used>=GESTURE_PROTOCOL_FRAME_MAX){parser->bad_frames++;reset_frame(parser);return;}
    parser->bytes[parser->used++]=byte;
    if(parser->used==3u && parser->bytes[2]!=GESTURE_PROTOCOL_VERSION){
        parser->bad_frames++;reset_frame(parser);return;
    }
    if(parser->used==8u){
        unsigned length=parser->bytes[6]|((unsigned)parser->bytes[7]<<8);
        if(length>GESTURE_PROTOCOL_FRAME_MAX-10u){parser->bad_frames++;reset_frame(parser);return;}
        parser->expected=(uint8_t)(10u+length);
    }
    if(parser->expected && parser->used==parser->expected){finish_frame(parser,state);reset_frame(parser);}
}

unsigned gesture_uart_service(style_input_state *state,uint32_t now)
{
    volatile uint32_t *regs=(volatile uint32_t *)(uintptr_t)GESTURE_UART_CSR_BASE;
    unsigned done=0;
    uint32_t status=regs[GESTURE_UART_STATUS/4u];
    if(status&GESTURE_UART_RX_ERROR_MASK){
        gesture_uart_state.bad_frames++;
        reset_frame(&gesture_uart_state);
        regs[GESTURE_UART_STATUS/4u]=status&GESTURE_UART_RX_ERROR_MASK;
        regs[GESTURE_UART_CONTROL/4u]=1u; /* Discard queued bytes so a damaged frame cannot join later data. */
    }else{
        while(done<GESTURE_UART_RX_BUDGET && regs[GESTURE_UART_LEVEL/4u]){
            gesture_uart_parser_feed(&gesture_uart_state,(uint8_t)regs[GESTURE_UART_DATA/4u],now,state);
            done++;
        }
    }
    return done;
}

void gesture_uart_tx_service(gesture_uart_parser *parser)
{
    volatile uint32_t *regs=(volatile uint32_t *)(uintptr_t)GESTURE_UART_TX_BASE;
    unsigned pos,slot;uint8_t byte;
    if(!parser->ack_count||!(regs[GESTURE_UART_TX_STATUS/4u]&1u))return;
    pos=parser->ack_pos;slot=parser->ack_head;
    byte=parser->ack[slot][pos];
    regs[GESTURE_UART_TX_DATA/4u]=byte;
    if(++parser->ack_pos==14u){parser->ack_pos=0;parser->ack_head=(uint8_t)((slot+1u)&(GESTURE_UART_ACK_DEPTH-1u));parser->ack_count--;}
}

void gesture_uart_remote_timeout(gesture_uart_parser *parser,style_input_state *state,
                                 uint32_t now_cycles,uint32_t now_ms)
{
    if(state->gesture_ready && (uint32_t)(now_cycles-parser->gesture_last_cycles)>=UINT32_C(500000000))
        state->gesture_ready=0;
    if(parser->remote_active&&(uint32_t)(now_cycles-parser->remote_last_cycles)>=UINT32_C(200000000)){
        cancel_remote_touch(state,now_ms);parser->remote_active=0u;
    }
    if(parser->hand_marker_valid&&
       (uint32_t)(now_cycles-parser->hand_marker_last_cycles)>=UINT32_C(30000000)){
        parser->hand_marker_valid=0u;parser->hand_marker=GESTURE_HAND_MARKER_INVALID;
    }
}
