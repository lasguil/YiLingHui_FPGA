#include "style_input.h"
#include "ipx_regs.h"
#include "style_ui_protocol.h"

enum { G_NONE,G_BUTTON,G_WIPE,G_MODEL,G_AI,G_FX,G_SAT };
typedef struct { uint32_t time; uint16_t x,y; uint8_t id,kind,action,cancel; } input_gesture;
static input_gesture g_local,g_remote;
#define A_NONE STYLE_ACTION_NONE
#define A_MODE STYLE_ACTION_MODE
#define A_COLOR STYLE_ACTION_COLOR
#define A_ADJUST STYLE_ACTION_ADJUST
#define A_KEEP STYLE_ACTION_KEEP
#define A_RGB STYLE_ACTION_RGB
#define A_VIEW STYLE_ACTION_VIEW
#define A_PAUSE STYLE_ACTION_PAUSE
#define A_CLEAN STYLE_ACTION_CLEAN
#define A_TABLE_PREV STYLE_ACTION_TABLE_PREV
#define A_TABLE_NEXT STYLE_ACTION_TABLE_NEXT
#define A_COLOR0 STYLE_ACTION_COLOR0
#define A_COLOR1 STYLE_ACTION_COLOR1
#define A_COLOR2 STYLE_ACTION_COLOR2
#define A_COLOR3 STYLE_ACTION_COLOR3
#define A_FX_MINUS STYLE_ACTION_FX_MINUS
#define A_FX_PLUS STYLE_ACTION_FX_PLUS
#define A_AI_MINUS STYLE_ACTION_AI_MINUS
#define A_AI_PLUS STYLE_ACTION_AI_PLUS
#define A_SAT_MINUS STYLE_ACTION_SAT_MINUS
#define A_SAT_PLUS STYLE_ACTION_SAT_PLUS
#define A_OUT_MINUS STYLE_ACTION_OUT_MINUS
#define A_OUT_PLUS STYLE_ACTION_OUT_PLUS
#define A_KEEP_TOGGLE STYLE_ACTION_KEEP_TOGGLE
#define A_RANGE STYLE_ACTION_RANGE
#define A_RGB_BACK STYLE_ACTION_RGB_BACK
#define A_B0M STYLE_ACTION_B0M
#define A_B0P STYLE_ACTION_B0P
#define A_B1M STYLE_ACTION_B1M
#define A_B1P STYLE_ACTION_B1P
#define A_B2M STYLE_ACTION_B2M
#define A_B2P STYLE_ACTION_B2P
#define A_B3M STYLE_ACTION_B3M
#define A_B3P STYLE_ACTION_B3P
#define A_B4M STYLE_ACTION_B4M
#define A_B4P STYLE_ACTION_B4P
#define A_B5M STYLE_ACTION_B5M
#define A_B5P STYLE_ACTION_B5P
#define A_MODEL_PREV STYLE_ACTION_MODEL_PREV
#define A_MODEL_NEXT STYLE_ACTION_MODEL_NEXT
#define A_CLOSE STYLE_ACTION_CLOSE
#define A_ADJ_BASIC STYLE_ACTION_ADJ_BASIC
#define A_ADJ_KEEP STYLE_ACTION_ADJ_KEEP
#define A_RESET STYLE_ACTION_RESET
#define A_VFLIP STYLE_ACTION_VFLIP
#define A_UI_HIDE_ALL STYLE_ACTION_UI_HIDE_ALL
#define A_UI_RESTORE STYLE_ACTION_UI_RESTORE
#define A_WAVE STYLE_ACTION_WAVE
static const uint8_t presets[3][6]={{128,255,0,145,0,145},
    {0,75,55,255,0,120},{0,160,0,185,100,255}};
static const uint8_t adjustment_offsets[4]={1,0,2,3};
static unsigned clamp(unsigned n,unsigned hi){return n>hi?hi:n;}
static void changed(style_input_state *s){s->dirty=1;s->generation++;}
static void wave_source(style_input_state *s,unsigned source)
{
    if(s->wave!=source){s->wave=(uint8_t)source;s->gesture_ready=0;s->dirty=1;}
}
static void copy_preset(style_ui_config *u,unsigned i){for(unsigned n=0;n<6;n++)u->bounds[n]=presets[i][n];}
static void table_step(style_input_state *s,int direction)
{
    unsigned count=s->table_count;
    if(!count)return;
    s->table=(uint8_t)(direction>0?(s->table+1u)%count:(s->table+count-1u)%count);
    changed(s);
}

unsigned style_input_command(unsigned char key,style_input_state *s)
{
    switch(key){
    case '0':case '1':case '2':case '3':s->mode=key-'0';break;
    case 'e':s->post=(s->post+1u)&3u;changed(s);break;
    case 'a':case 'b':case 'w':case 's':
        s->scene=key=='a'?0u:key=='b'?1u:key=='w'?2u:3u;
        if(key=='w')s->wipe_x=960;
        s->dirty=1;break;
    case 'v':(void)style_input_action(STYLE_ACTION_VIEW,s);break;
    case 'p':(void)style_input_action(STYLE_ACTION_PAUSE,s);break;
    case 't':(void)style_input_action(STYLE_ACTION_TABLE_NEXT,s);break;
    case 'u':if(!s->ui_hidden_all){s->ui_enable^=1u;s->dirty=1;}break;
    case 'c':return STYLE_INPUT_CLEAR;
    case 'd':return STYLE_INPUT_DIAGNOSTICS;
    case 'g':case 'j':case 'k':
        s->ui.page=key=='g'?STYLE_UI_PAGE_COLOR:key=='j'?STYLE_UI_PAGE_ADJUST:STYLE_UI_PAGE_KEEP;
        s->dirty=1;break;
    default:break;
    }
    return STYLE_INPUT_NONE;
}
static int inside(unsigned x,unsigned y,unsigned x0,unsigned y0,unsigned x1,unsigned y1)
{return x>=x0&&x<x1&&y>=y0&&y<y1;}
static unsigned hit(unsigned x,unsigned y,const style_input_state *s)
{
    const style_ui_config *u=&s->ui;
    if(!s->ui_enable)return inside(x,y,1664,984,1864,1056)?A_CLEAN:A_NONE;
    /* These fixed bars remain active while a menu is open. */
    if(y>=16&&y<72&&x>=688&&x<928)return A_WAVE;
    if(y>=16&&y<72&&x>=960&&x<1176)return A_VFLIP;
    if(y>=16&&y<72&&x>=1216&&x<1520)return A_MODE;
    if(y>=970&&y<1058){
        if(x>=24&&x<72)return A_MODEL_PREV;
        if(x>=276&&x<324)return A_MODEL_NEXT;
        if(x>=340&&x<640)return A_COLOR;
        if(x>=656&&x<956)return A_ADJUST;
        if(x>=972&&x<1272)return A_VIEW;
        if(x>=1288&&x<1568)return A_PAUSE;
        if(x>=1584&&x<1896)return A_CLEAN;
    }
    if(u->page==STYLE_UI_PAGE_HOME){
        if(s->scene==2&&inside(x,y,s->wipe_x>48?s->wipe_x-48:0,486,s->wipe_x+48,558))return A_NONE;
        return A_NONE;
    }
    if(inside(x,y,1784,128,1848,184))return A_CLOSE;
    if(u->page==STYLE_UI_PAGE_COLOR){
        if(x>=1352&&x<1848){
            if(y>=228&&y<552){unsigned row=(y-228)/84;if((y-228)%84<72)return A_COLOR0+row;}
            if(y>=614&&y<682){if(x<1416)return A_TABLE_PREV;if(x>=1784)return A_TABLE_NEXT;}
        }
    }else if(u->page==STYLE_UI_PAGE_ADJUST||u->page==STYLE_UI_PAGE_KEEP){
        if(y>=220&&y<284){if(x>=1352&&x<1592)return A_ADJ_BASIC;if(x>=1608&&x<1848)return A_ADJ_KEEP;}
        if(u->page==STYLE_UI_PAGE_ADJUST){
            if(inside(x,y,1352,660,1848,732))return A_RESET;
        }else{
            if(inside(x,y,1352,320,1848,392))return A_KEEP_TOGGLE;
            if(inside(x,y,1352,416,1848,488))return A_RANGE;
        }
    }
    /* Clicking outside a menu closes it, but never begins a picture gesture. */
    return (x<1328||x>=1872||y<112||y>=928)?A_CLOSE:A_NONE;
}
static unsigned do_action(unsigned a,style_input_state *s)
{
    style_ui_config *u=&s->ui;
    unsigned luma_only=(s->post==IPX_GRAY_PALETTE||s->post==IPX_DUOTONE_DOT);
    if(a>=A_FX_MINUS&&a<=A_SAT_PLUS){
        unsigned index=a-A_FX_MINUS,group=index>>1,up=index&1u;
        uint8_t *value=(uint8_t *)&u->ai+adjustment_offsets[group];
        if(group>=2u&&(luma_only||u->preserve!=(group&1u)))return 1;
        *value=(uint8_t)(up?clamp(*value+5u,group<2?100u:200u):(*value>=5u?*value-5u:0u));
        changed(s);return 1;
    }
    switch(a){
    case A_MODE:s->mode=(s->mode+1u)&3u;s->dirty=1;break;
    case A_COLOR:u->page=u->page==STYLE_UI_PAGE_COLOR?STYLE_UI_PAGE_HOME:STYLE_UI_PAGE_COLOR;s->dirty=1;break;
    case A_ADJUST:u->page=u->page==STYLE_UI_PAGE_ADJUST?STYLE_UI_PAGE_HOME:STYLE_UI_PAGE_ADJUST;s->dirty=1;break;
    case A_KEEP:u->page=STYLE_UI_PAGE_KEEP;s->dirty=1;break;
    case A_VIEW:s->scene=(s->scene+1u)&3u;s->dirty=1;break;
    case A_PAUSE:s->paused^=1u;s->dirty=1;break;
    case A_CLEAN:s->ui_enable^=1u;u->page=STYLE_UI_PAGE_HOME;s->dirty=1;break;
    case A_CLOSE:u->page=STYLE_UI_PAGE_HOME;s->dirty=1;break;
    case A_ADJ_BASIC:u->page=STYLE_UI_PAGE_ADJUST;s->dirty=1;break;
    case A_ADJ_KEEP:u->page=STYLE_UI_PAGE_KEEP;s->dirty=1;break;
    case A_TABLE_PREV:case A_TABLE_NEXT:table_step(s,a==A_TABLE_NEXT?1:-1);break;
    case A_COLOR0:case A_COLOR1:case A_COLOR2:case A_COLOR3:s->post=a-A_COLOR0;changed(s);break;
    case A_KEEP_TOGGLE:if(!luma_only){u->preserve^=1u;changed(s);}break;
    case A_RANGE:if(!luma_only){u->range=(uint8_t)((u->range+1u)%3u);copy_preset(u,u->range);changed(s);}break;
    case A_RESET:u->ai=u->fx=u->sat=100;u->preserve=0;u->out_sat=0;u->range=0;copy_preset(u,0);changed(s);break;
    case A_WAVE:wave_source(s,s->wave>=STYLE_WAVE_EXT?STYLE_WAVE_OFF:s->wave+1u);break;
    case A_VFLIP:s->vflip^=1u;s->dirty=1;break;
    case A_UI_HIDE_ALL:
        s->ui_hidden_all=1u;s->ui_enable=0u;u->page=STYLE_UI_PAGE_HOME;
        g_local.kind=g_remote.kind=G_NONE;g_local.cancel=g_remote.cancel=0u;s->dirty=1u;break;
    case A_UI_RESTORE:
        s->ui_hidden_all=0u;s->ui_enable=1u;u->page=STYLE_UI_PAGE_HOME;s->dirty=1u;break;
    case A_MODEL_PREV:case A_MODEL_NEXT:
        if(s->paused){s->hint=1;break;}
        s->model_step=a==A_MODEL_NEXT?1:-1;s->hint=1;s->dirty=1;break;
    default:return 0;
    }
    return 1;
}
unsigned style_input_action(unsigned action,style_input_state *s)
{
    /* A hidden display may still be controlled remotely. Keep legacy CLEAN
       from becoming an alternate restore path; only action 46 restores UI. */
    if(s->ui_hidden_all&&action==A_CLEAN)return 0;
    return do_action(action,s);
}
unsigned style_input_set(unsigned field,unsigned value,style_input_state *s)
{
    uint8_t *target=0;
    unsigned maximum=255u;
    if(field>=STYLE_SET_BOUND0&&field<=STYLE_SET_BOUND5){
        unsigned i=field-STYLE_SET_BOUND0;
        if((i&1u)?value<s->ui.bounds[i-1u]:value>s->ui.bounds[i+1u])return 0;
        target=&s->ui.bounds[i];
    }else if(field==STYLE_SET_PAUSE){target=&s->paused;maximum=1u;s->gesture_ready=0u;}
    else if(field==STYLE_SET_SAT){target=&s->ui.sat;maximum=200u;}
    else if(field==STYLE_SET_KEEP){
        target=&s->ui.preserve;maximum=1u;
    }
    if(target){
        if(value>maximum)return 0;
        if(*target!=value){*target=(uint8_t)value;changed(s);}return 1;
    }
    switch(field){
    case STYLE_SET_KEEP_RANGE:
        if(value>2u)return 0;
        s->ui.range=(uint8_t)value;copy_preset(&s->ui,value);changed(s);return 1;
    case STYLE_SET_WAVE:
        if(value>STYLE_WAVE_EXT)return 0;
        wave_source(s,value);return 1;
    case STYLE_SET_MODEL:
        if(value>=STYLE_MODEL_ASSET_COUNT||s->paused)return 0;
        s->model_step=(int8_t)(value+2u);s->hint=1;s->dirty=1;return 1;
    case STYLE_SET_TABLE:
        if(value>=s->table_count)return 0;
        if(s->table!=value){s->table=(uint8_t)value;changed(s);}return 1;
    case STYLE_SET_AI:case STYLE_SET_FX:{
        if(value>100u)return 0;
        uint8_t *v=field==STYLE_SET_AI?&s->ui.ai:&s->ui.fx;
        if(*v!=value){*v=(uint8_t)value;changed(s);}return 1;
    }
    default:return 0;
    }
}
static unsigned slider_kind(unsigned x,unsigned y,const style_input_state *s)
{
    if(!s->ui_enable||x<1352u||x>=1848u)return G_NONE;
    if(s->ui.page==STYLE_UI_PAGE_ADJUST){
        if(y>=366u&&y<400u)return G_AI;
        if(y>=462u&&y<496u)return G_FX;
        if(y>=558u&&y<592u&&!s->ui.preserve&&s->post!=IPX_GRAY_PALETTE&&s->post!=IPX_DUOTONE_DOT)return G_SAT;
    }
    return G_NONE;
}
static void slider_update(unsigned kind,unsigned x,style_input_state *s)
{
    if(kind==G_SAT){
        unsigned value=x<=STYLE_SLIDER_X0?0u:x>=STYLE_SLIDER_X1?200u:
            (x-STYLE_SLIDER_X0+1u)/2u;
        if(s->ui.sat!=value){s->ui.sat=(uint8_t)value;changed(s);}return;
    }
    unsigned value=x<=STYLE_SLIDER_X0?0u:x>=STYLE_SLIDER_X1?100u:
        (x-STYLE_SLIDER_X0+2u)/4u;
    (void)style_input_set(kind==G_AI?STYLE_SET_AI:STYLE_SET_FX,value,s);
}
void style_input_touch(const ch9350_event *e,style_input_state *s,unsigned cancel_event)
{
    style_ui_config *u=&s->ui;
    input_gesture *g=e->id==STYLE_INPUT_REMOTE_TOUCH_ID?&g_remote:&g_local;
    if(s->ui_hidden_all){g->kind=G_NONE;g->cancel=0u;return;}
    if(e->type==CH9350_DOWN){
        if(g->kind){if(e->id!=g->id)g->cancel=1;return;}
        g->id=e->id;g->x=e->screen_x;g->y=e->screen_y;g->time=e->time_ms;g->cancel=(uint8_t)cancel_event;
        g->kind=(uint8_t)slider_kind(g->x,g->y,s);
        if(g->kind){if(!g->cancel)slider_update(g->kind,g->x,s);return;}
        g->action=(uint8_t)hit(g->x,g->y,s);
        if(g->action!=A_NONE)g->kind=G_BUTTON;
        else if(s->ui_enable&&u->page==STYLE_UI_PAGE_HOME&&s->scene==2&&
                inside(g->x,g->y,s->wipe_x>48?s->wipe_x-48:0,486,s->wipe_x+48,558))g->kind=G_WIPE;
        else if(u->page==STYLE_UI_PAGE_HOME&&!s->paused&&
                inside(g->x,g->y,0,s->ui_enable?88u:0u,1920,s->ui_enable?952u:1080u))g->kind=G_MODEL;
        return;
    }
    if(!g->kind||e->id!=g->id)return;
    if(cancel_event||e->time_ms-g->time>(g->kind>=G_AI?10000u:1800u))g->cancel=1;
    if(g->kind>=G_AI&&slider_kind(g->x,g->y,s)!=g->kind)g->cancel=1;
    if(e->type==CH9350_CANCEL){g->kind=G_NONE;g->cancel=0;return;}
    if(g->kind>=G_AI){
        if(!g->cancel&&(e->type==CH9350_MOVE||e->type==CH9350_UP))slider_update(g->kind,e->screen_x,s);
        if(e->type==CH9350_UP){g->kind=G_NONE;g->cancel=0;}return;
    }
    if(e->type==CH9350_MOVE&&g->kind==G_WIPE&&!g->cancel){s->wipe_x=e->screen_x>1856u?1856u:(e->screen_x<64u?64u:e->screen_x);s->dirty=1;return;}
    if(e->type==CH9350_MOVE&&g->kind==G_BUTTON&&
       hit(e->screen_x,e->screen_y,s)!=g->action)g->cancel=1;
    if(e->type!=CH9350_UP)return;
    unsigned kind=g->kind,action=g->action,dx=(unsigned)(e->screen_x>g->x?e->screen_x-g->x:g->x-e->screen_x);
    unsigned dy=(unsigned)(e->screen_y>g->y?e->screen_y-g->y:g->y-e->screen_y);
    unsigned valid=!g->cancel&&e->time_ms-g->time<=1800u;
    g->kind=G_NONE;g->cancel=0;
    if(!valid)return;
    if(kind==G_BUTTON){if(hit(e->screen_x,e->screen_y,s)==action)do_action(action,s);}
    else if(kind==G_MODEL&&dx>=320u&&dx>dy*2u&&
            inside(e->screen_x,e->screen_y,0,s->ui_enable?88u:0u,1920,s->ui_enable?952u:1080u)){
        s->model_step=e->screen_x<g->x?1:-1;s->hint=1;s->dirty=1;}
}
