/* Single-owner control task. PL owns every pixel and the strip handoffs.
 * This bare-metal task can later run unchanged inside the RTOS scheduler.
 * The CPU asks the IPX read DMA to load DDR color tables; pixels remain PL-owned. */
#include "style_system.h"
#include "style_camera.h"
#include "ch9350_uart.h"
#include "gesture_uart.h"
#include "style_input.h"
#include "style_fps.h"
#include "style_post_state.h"
#include "style_ui_protocol.h"
#include "style_ui_catalog.h"
#include "style_model_directory.h"
#include "style_model_assets_generated.h"
#include <stddef.h>
__attribute__((used,noinline,optimize("no-tree-loop-distribute-patterns")))
void *memset(void *dst,int value,size_t length)
{
    unsigned char *p=dst;
    for(size_t i=0;i<length;i++)p[i]=(unsigned char)value;
    return dst;
}
__attribute__((used,noinline,optimize("no-tree-loop-distribute-patterns")))
void *memcpy(void *dst,const void *src,size_t length)
{
    unsigned char *d=dst;const unsigned char *s=src;
    for(size_t i=0;i<length;i++)d[i]=s[i];
    return dst;
}
#define UART UINT32_C(0xf8010000)
#define GPIO UINT32_C(0xf8015000)
#define PLIC UINT32_C(0xf8c00000)
#define PLIC_SOURCE 16u /* Sapphire BSP userInterruptA. */
#define PLIC_ENABLE 0x2000u
#define PLIC_CLAIM 0x200004u
#define CONTROL_TIMEOUT UINT32_C(500000000) /* 5s at the unchanged CPU 100MHz. */
static volatile uint32_t irq_notifications,trap_cause,trap_pc;
/* The CPU has no DDR AXI master; persistent software state lives in OCR BSS. */
static ch9350_touch touch_ctx;
static style_post_state post_state;
static uint32_t touch_ms,touch_subcycles,touch_last_cycles;
static uint32_t touch_last_service_cycles;
static uint8_t touch_clock_started;
static style_input_state input_state={.mode=VIDEO_480_30,.scene=2,.ui_enable=1,.wipe_x=960,
    .ui={.ai=100,.fx=100,.sat=100,.out_sat=0,.bounds={128,255,0,145,0,145},
         .page=STYLE_UI_PAGE_HOME,.preserve=0,.range=0},.generation=1};
#define desired_mode input_state.mode
#define desired_scene input_state.scene
#define desired_ui_enable input_state.ui_enable
#define processing_paused input_state.paused
#define desired_wipe_x input_state.wipe_x
#define ui_config input_state.ui
#define ui_controls_dirty input_state.dirty
#define ui_param_generation input_state.generation
#define model_step_request input_state.model_step
#define ui_hint_request input_state.hint
static struct sp_context pipeline;
static uint16_t table_generation,loaded_table;
static uint8_t ui_live_state_current;
static style_fps_state fps_state;
static uint16_t ui_param_applied,ui_param_displayed;
enum { MODEL_FORMAT_W8A8=1 };
/* The generated catalog matches the verified Flash bundle order and DDR slots.
 * Boot validates the complete bundle before this software publishes the UI. */
static const style_model_asset model_directory[STYLE_MODEL_ASSET_COUNT]={STYLE_MODEL_ASSET_ROWS};
enum { model_directory_count=STYLE_MODEL_ASSET_COUNT,model_ready_count=STYLE_MODEL_ASSET_COUNT };
static uint8_t current_model_index,displayed_model_index;
enum { TABLE_SOURCE_BUILTIN=0,TABLE_SOURCE_DDR=1 };
typedef struct { const char *name; uint32_t address; uint8_t source,preset,ready; } color_table_asset;
static const color_table_asset table_directory[]={STYLE_TABLE_ASSET_ROWS};
static const uint8_t table_directory_count=(uint8_t)(sizeof(table_directory)/sizeof(table_directory[0]));
static volatile uint8_t display_ui_initialized;

static int load_color_table_asset(const color_table_asset *asset)
{
    if(!asset||!asset->ready)return SP_INVALID;
    if(asset->source==TABLE_SOURCE_BUILTIN)
        return sp_load_color_table_builtin(&pipeline,asset->preset);
    if(asset->source==TABLE_SOURCE_DDR&&asset->address)
        return sp_load_color_table(&pipeline,asset->address);
    return SP_INVALID;
}

static uint32_t processing_fps_bcd;
static uint8_t processing_fps_valid;
static uint8_t applied_scene=2u,applied_ui_enable=1u;
static uint16_t applied_wipe_x=960u;
static uint32_t published_fps_bcd;
static uint8_t published_fps_valid;
static unsigned current_video_mode=VIDEO_480_30;
/* NPU work stays serial; only the display VS mailbox runs asynchronously. */
static uint8_t steady_frames_started,display_commit_waiting;
static uint8_t display_commit_post,display_commit_table,display_commit_model;
static uint8_t display_commit_ui_post,display_commit_ui_table,ui_displayed_post,ui_displayed_table;
static uint16_t display_commit_ui_generation,result_param_displayed;
static uint16_t display_commit_result_generation;
static uint8_t display_commit_updates_result,display_commit_ui_page,ui_displayed_page;
static uint16_t display_commit_hand_marker;
static uint16_t displayed_hand_marker=STYLE_HAND_MARKER_INVALID;

static uint16_t current_hand_marker(void)
{
    return input_state.wave==STYLE_WAVE_EXT&&gesture_uart_state.hand_marker_valid?gesture_uart_state.hand_marker:
        STYLE_HAND_MARKER_INVALID;
}

static void poll_controls(void);
static void process_touch_events(void);
static void display_finish_if_acked(void);
static void display_submit_frame(unsigned mode,uint32_t source_base,uint32_t result_base,
                                 unsigned post,unsigned table,unsigned result_generation,
                                 unsigned result_model,unsigned updates_result,unsigned wait_for_ack);
static void process_model_step(void);
__attribute__((noreturn)) static void stop(const char *reason);
// CLINT mtime is the real 100MHz timebase. Read it hi-lo-hi so rollover cannot
// fabricate an early timeout. This core does not implement mcycle.
#ifdef STYLE_CAMERA_HOST_TEST
extern volatile uint32_t style_test_cycles;
static uint32_t cycles(void) { return style_test_cycles; }
#else
static uint32_t cycles(void)
{
    volatile uint32_t *const mtime=(volatile uint32_t *)(uintptr_t)UINT32_C(0xf8b0bff8);
    /* Callers use only wrapping low-word deltas. High-word coherency is
       required for a 64-bit timestamp, not for this single 32-bit read. */
    return mtime[0];
}
#endif
static uint32_t touch_update_clock(void)
{
    uint32_t now=cycles();
    if(!touch_clock_started){touch_clock_started=1;touch_last_cycles=now;touch_last_service_cycles=now;return touch_ms;}
    uint32_t delta=now-touch_last_cycles;
    touch_last_cycles=now;
    uint32_t accumulated=touch_subcycles+delta;
    touch_ms+=accumulated/100000u;
    touch_subcycles=accumulated%100000u;
    return touch_ms;
}
void style_camera_wait_service(void)
{
    if(!touch_clock_started)return;
    uint32_t now=cycles();
    (void)touch_update_clock();
    if((uint32_t)(now-touch_last_service_cycles)>=100000u){
        touch_last_service_cycles=now;
        (void)ch9350_uart_service(&touch_ctx,(uintptr_t)CH9350_UART_CSR_BASE,touch_ms,128u);
        (void)gesture_uart_service(&input_state,now);
        gesture_uart_remote_timeout(&gesture_uart_state,&input_state,now,touch_ms);
        gesture_uart_tx_service(&gesture_uart_state);
        process_touch_events(); /* Drain <=30 generated intents before another bounded RX batch. */
    }
}
static void put(char c)
{
    unsigned timeout=100000;
    while(((style_read(UART,4)>>16)&255)==0 && --timeout)
        if((timeout&1023u)==0)style_camera_wait_service();
    if(timeout)style_write(UART,0,(unsigned char)c);
}
static void text(const char *s) { while(*s)put(*s++); }
static void hex(uint32_t value)
{
    for(int shift=28;shift>=0;shift-=4){unsigned v=(value>>shift)&15;put(v<10?'0'+v:'A'+v-10);}
}
static void display_ui_live_state(unsigned state)
{
    if(!display_ui_initialized)return;
    if(input_state.wave==STYLE_WAVE_EXT && !processing_paused && input_state.gesture_ready && state!=DISPLAY_STATE_ERROR)state=DISPLAY_STATE_GESTURE_READY;
    if(ui_live_state_current==state)return;
    uint32_t began=cycles(),before=style_read(STYLE_DISPLAY_BASE,DISPLAY_UI_LIVE_STATE);
    unsigned req=(before>>3)&1u,ack=(before>>4)&1u;
    if(req!=ack)return;
    unsigned next=req^1u;
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_LIVE_STATE,state&7u);
    for(;;){
        style_camera_wait_service();
        uint32_t status=style_read(STYLE_DISPLAY_BASE,DISPLAY_UI_LIVE_STATE);
        if(((status>>3)&1u)==next&&((status>>4)&1u)==next){ui_live_state_current=state&7u;return;}
        if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT) return;
    }
}
static void display_ui_try_publish_error(void)
{
    if(!display_ui_initialized)return;
    uint32_t status=style_read(STYLE_DISPLAY_BASE,DISPLAY_UI_LIVE_STATE);
    unsigned req=(status>>3)&1u,ack=(status>>4)&1u;
    if(req!=ack)return;
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_LIVE_STATE,(status&~7u)|DISPLAY_STATE_ERROR);
    for(unsigned bounded_poll=0;bounded_poll<100000u;bounded_poll++){
        if((bounded_poll&1023u)==0)style_camera_wait_service();
        status=style_read(STYLE_DISPLAY_BASE,DISPLAY_UI_LIVE_STATE);
        if(((status>>3)&1u)!=req&&((status>>4)&1u)!=req){ui_live_state_current=DISPLAY_STATE_ERROR;return;}
    }
}
static void display_ui_update(unsigned mode,uint32_t fps_bcd,unsigned fps_valid,
                              unsigned result_generation,unsigned result_post,unsigned result_table,
                              unsigned result_model)
{
    uint32_t flags=(fps_valid?1u:0u)<<16;
    unsigned pending=(ui_param_generation!=result_generation)||
        post_state.desired!=result_post||post_state.table_desired!=result_table;
    pending|=(current_model_index!=result_model);
    uint32_t ui_data=style_ui_metadata(ui_config.page,post_state.desired,result_model,
        post_state.table_desired,ui_config.preserve,ui_config.range,pending,
        processing_paused,mode,desired_scene);
    ui_data|=style_ui_wave_metadata(input_state.wave);
    ui_data|=((uint32_t)(input_state.vflip&1u)<<29);
    ui_data|=((uint32_t)(input_state.ui_hidden_all&1u)<<30);
    ui_data|=((uint32_t)((result_model>>4)&1u)<<31);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_CATALOG_INFO,
        style_ui_catalog_info(model_directory_count,table_directory_count));
    uint16_t slots[8]={0};uint32_t words[3];
    slots[6]=style_ui_percent_bcd(ui_config.ai);slots[7]=style_ui_percent_bcd(ui_config.fx);
    if(ui_config.page==STYLE_UI_PAGE_ADJUST){
        slots[0]=style_ui_percent_bcd(ui_config.ai);slots[1]=style_ui_percent_bcd(ui_config.fx);
        slots[2]=style_ui_percent_bcd(ui_config.sat);
    }
    /* Binary slider positions: AI/FX 0..100; SAT 0..200. */
    slots[3]=ui_config.ai;slots[4]=ui_config.fx;slots[5]=ui_config.sat;
    style_ui_pack_values(slots,words);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_DATA,ui_data);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_METRICS,flags|fps_bcd);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_VALUES0,words[0]);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_VALUES1,words[1]);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_VALUES2,words[2]);
}
static void display_catalog_write(unsigned base,const char *name)
{
    /* Boot-only, immutable generated names. Character/length validation runs
       in the firmware build, before these literals become ROM data. */
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_CATALOG_INDEX,base);
    for(unsigned i=0;i<STYLE_UI_CATALOG_SLOT_BYTES;i++){
        unsigned char c=(unsigned char)*name;
        if(c)name++;
        style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_CATALOG_DATA,c?c:' ');
    }
}
static void display_catalog_init(void)
{
    _Static_assert(STYLE_MODEL_ASSET_COUNT==STYLE_UI_CATALOG_MODEL_SLOTS,"Model catalog coverage");
    _Static_assert(sizeof(table_directory)/sizeof(table_directory[0])==STYLE_UI_CATALOG_TABLE_SLOTS,"Table catalog coverage");
    /* Each slot is written and padded exactly once, before the UI appears. */
    for(unsigned i=0;i<model_directory_count;i++)
        display_catalog_write(style_ui_catalog_model_index(i),model_directory[i].name);
    for(unsigned i=0;i<table_directory_count;i++)
        display_catalog_write(style_ui_catalog_table_index(i),table_directory[i].name);
}
static void configure_next_post(void)
{
    if(style_post_configure_next(&post_state)){
        if(post_state.table_configured_next!=loaded_table){
            unsigned table=post_state.table_configured_next;
            if(table>=table_directory_count)stop("T_IDX");
            if(!table_directory[table].ready)stop("T_WAIT");
            const color_table_asset *asset=&table_directory[table];
            int table_result=load_color_table_asset(asset);
            if(table_result!=SP_DONE)stop("T_LOAD");
            loaded_table=post_state.table_configured_next;
            table_generation=(uint16_t)(style_read(STYLE_IPX_BASE,IPX_TABLE_STATUS)>>16);
            text("TABLE ");text(table_directory[loaded_table].name);text(" GEN ");hex(table_generation);text("\r\n");
        }
        style_write(STYLE_IPX_BASE,IPX_OPTIONS,IPX_MODE_COLOR(post_state.configured_next)|
                    (ui_config.preserve?IPX_PRESERVE:0u));
    }
    if(ui_param_generation!=ui_param_applied){
        uint32_t options=IPX_MODE_COLOR(post_state.configured_next)|
                         (ui_config.preserve?IPX_PRESERVE:0u);
        style_write(STYLE_IPX_BASE,IPX_OPTIONS,options);
        style_write(STYLE_IPX_BASE,IPX_SATURATION,
            ((uint32_t)ui_config.sat*256u+50u)/100u);
        style_write(STYLE_IPX_BASE,IPX_COLOR_MIN,IPX_RGB(ui_config.bounds[0],ui_config.bounds[2],ui_config.bounds[4]));
        style_write(STYLE_IPX_BASE,IPX_COLOR_MAX,IPX_RGB(ui_config.bounds[1],ui_config.bounds[3],ui_config.bounds[5]));
        style_write(STYLE_IPX_BASE,IPX_ALPHA,((uint32_t)ui_config.fx*256u+50u)/100u);
        style_write(STYLE_IPX_BASE,IPX_AI_ALPHA,((uint32_t)ui_config.ai*256u+50u)/100u);
        ui_param_applied=ui_param_generation;
    }
}
static void claim_camera(void)
{
    /* A display/UI ACK says nothing about IPX configuration. Every new
       claim checks desired versus actually configured state, even if the
       UI commit already cleared its dirty flag. Both claim paths use this. */
    configure_next_post();
    style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_CLAIM_CAMERA);
}
static void display_finish_if_acked(void)
{
    if(!display_commit_waiting)return;
    if(!(style_read(STYLE_DISPLAY_BASE,0x38)&2u))return;
    post_state.displayed=display_commit_post;
    post_state.table_displayed=display_commit_table;
    ui_displayed_post=display_commit_ui_post;
    ui_displayed_table=display_commit_ui_table;
    ui_displayed_page=display_commit_ui_page;
    display_ui_initialized=1;
    ui_param_displayed=display_commit_ui_generation;
    if(display_commit_updates_result)result_param_displayed=(uint16_t)display_commit_result_generation;
    if(display_commit_updates_result){
        unsigned model=display_commit_model;
        if(model<model_directory_count&&model!=displayed_model_index){
            displayed_model_index=(uint8_t)model;
            text("MODEL ");text(model_directory[model].name);text(" ACTIVE\r\n");
        }
    }
    displayed_hand_marker=display_commit_hand_marker;
    display_commit_waiting=0;
    ui_controls_dirty=0; /* poll_controls recomputes every desired/applied delta below. */
}
static void update_processing_fps(void)
{
    uint32_t now=cycles();
    uint16_t frames=(uint16_t)style_read(STYLE_CONTROL_BASE,SYS_FRAMES);
    if(style_fps_sample(&fps_state,now,frames,processing_paused)){
        processing_fps_bcd=style_fps_to_bcd(fps_state.tenths);
        processing_fps_valid=fps_state.valid;
    }
    if(display_ui_initialized&&
       (processing_fps_bcd!=published_fps_bcd||processing_fps_valid!=published_fps_valid))
        ui_controls_dirty=1;
}
/* Input handlers own desired selections; this is the sole bridge into the
 * frame-boundary post state. Configured/active/displayed remain acknowledgments
 * of later pipeline and display stages. */
static void sync_frame_event_selection(void)
{
    if(input_state.post<=IPX_RGB_DOT)
        post_state.desired=input_state.post;
    if(input_state.table<table_directory_count)
        post_state.table_desired=input_state.table;
}
/* Reuse the existing VS mailbox for metrics and user controls.  Shadow source
 * addresses and geometry are untouched, so a paused NPU still updates at the
 * independent HDMI frame boundary without claiming or publishing a camera frame. */
static void display_apply_ui_controls(void)
{
    if(!display_ui_initialized||!ui_controls_dirty)return;
    display_submit_frame(current_video_mode,
        style_read(STYLE_DISPLAY_BASE,0x04),style_read(STYLE_DISPLAY_BASE,0x08),
        post_state.displayed,post_state.table_displayed,result_param_displayed,displayed_model_index,0u,1u);
}
static int display_diag_toggle(uint32_t reg)
{
    uint32_t before=style_read(STYLE_DISPLAY_BASE,reg);
    unsigned req=before&1u,ack=(before>>1)&1u;
    if(req!=ack)return 0;
    style_write(STYLE_DISPLAY_BASE,reg,1u);
    unsigned next=req^1u;
    uint32_t began=cycles();unsigned service_divider=0;
    for(;;){
        uint32_t state=style_read(STYLE_DISPLAY_BASE,reg);
        if((state&1u)==next&&((state>>1)&1u)==next)return 1;
        if((uint32_t)(cycles()-began)>UINT32_C(10000000))return 0;
        if((++service_divider&1023u)==0)style_camera_wait_service();
    }
}
static void print_diagnostics(void)
{
    uint32_t s=style_read(STYLE_CONTROL_BASE,SYS_STATUS);
    text("D");hex(style_read(STYLE_DISPLAY_BASE,0x3c));
    text(" S");hex(s);text(" F");hex(style_read(STYLE_CONTROL_BASE,SYS_FRAMES));
    text(" M");hex(style_read(STYLE_CONTROL_BASE,SYS_MODE_ACTIVE));
    text(" FPS");hex(processing_fps_valid?processing_fps_bcd:0u);
    if(display_diag_toggle(DISPLAY_DIAG_SNAPSHOT)){
        text(" U");hex(style_read(STYLE_DISPLAY_BASE,DISPLAY_DIAG_STATUS));
        text(" A");hex(style_read(STYLE_DISPLAY_BASE,DISPLAY_DIAG_A));
        text(" B");hex(style_read(STYLE_DISPLAY_BASE,DISPLAY_DIAG_B));
    }else text(" TO");
    text(" CH");hex(touch_ctx.stats.good_frames);put('/');hex(touch_ctx.stats.bad_checksum);
    put('/');hex(touch_ctx.stats.bad_addr);put('/');hex(touch_ctx.stats.event_overflow);
    text(" RX");hex(style_read(CH9350_UART_CSR_BASE,CH9350_UART_STATUS));
    put('/');hex(style_read(CH9350_UART_CSR_BASE,CH9350_UART_OVERRUN_COUNT));
    put('/');hex(style_read(CH9350_UART_CSR_BASE,CH9350_UART_FRAMING_COUNT));
    text(" GU");hex(gesture_uart_state.good_frames);put('/');hex(gesture_uart_state.bad_frames);
    put('/');hex(gesture_uart_state.unsupported);
    put('/');hex(style_read(GESTURE_UART_CSR_BASE,GESTURE_UART_OVERRUN_COUNT));
    put('/');hex(style_read(GESTURE_UART_CSR_BASE,GESTURE_UART_FRAMING_COUNT));text("\r\n");
}
static void process_touch_events(void)
{
    ch9350_event event;
    static uint32_t timeout_seen;
    while(ch9350_touch_event_pop(&touch_ctx,&event)){
        unsigned cancelled=touch_ctx.stats.timeout_releases!=timeout_seen;
        timeout_seen=touch_ctx.stats.timeout_releases;
        style_input_touch(&event,&input_state,cancelled);
    }
    sync_frame_event_selection();
}
__attribute__((noreturn)) static void stop(const char *reason)
{
    display_ui_try_publish_error();
#ifndef STYLE_CAMERA_HOST_TEST
    __asm__ volatile("csrw mie,zero" ::: "memory");
#endif
    style_write(PLIC,PLIC_ENABLE,0);
    // Preserve input/output ownership on errors, including in-flight DMA.
    text("STOP ");text(reason);text(" c=");hex(trap_cause);text(" p=");hex(trap_pc);text("\r\n");
    uint32_t mark=cycles(),beat=0;
    for(;;)if((uint32_t)(cycles()-mark)>=50000000u){mark=cycles();style_write(GPIO,4,beat^=1);}
}
__attribute__((noreturn)) void style_trap_stop(void) { stop("CPU_TRAP"); }
#ifdef STYLE_CAMERA_HOST_TEST
void style_machine_trap(void) { style_trap_stop(); }
#else
__attribute__((interrupt("machine"),aligned(4))) void style_machine_trap(void)
{
    uint32_t cause,pc;
    __asm__ volatile("csrr %0,mcause":"=r"(cause));
    // Bring-up: record the very first trap of any kind, and count every entry.
    // trap_pc stays 0 until the first trap, so later (nested) entries cannot
    // overwrite the original cause and PC.
    if(trap_pc==0){__asm__ volatile("csrr %0,mepc":"=r"(pc));trap_cause=cause;trap_pc=pc;}
    irq_notifications++;
    if(cause==UINT32_C(0x8000000b)){
        uint32_t source=style_read(PLIC,PLIC_CLAIM);
        // Notify only. MMIO scheduling and buffer publication stay in main.
        style_write(PLIC,PLIC_ENABLE,0);
        if(source){irq_notifications++;style_write(PLIC,PLIC_CLAIM,source);}
        // Nothing to claim means the line is stuck high for another reason.
        // Mask it instead of re-entering this handler forever.
        else __asm__ volatile("csrc mie,%0"::"r"(1u<<11):"memory");
    }else{
        // Record the first fatal trap only: a re-entry must not overwrite the
        // original cause and PC with the handler's own fault address.
        // mepc is readable on this core but NOT writable - writing it raises
        // another illegal instruction and traps forever - so never csrw it.
        __asm__ volatile("csrr %0,mepc":"=r"(pc));
        if(trap_pc==0){trap_cause=cause;trap_pc=pc;}
        style_trap_stop();
    }
}
#endif
static void arm_irq(void)
{
    // Order matters: a PLIC source can already be pending at power-up, so the
    // mie external bit must not be set until a source is enabled and can be
    // claimed. Enabling mie early traps into a handler with nothing to claim,
    // and the level-triggered line re-traps forever.
    style_write(PLIC,PLIC_ENABLE,1u<<PLIC_SOURCE);
#ifndef STYLE_CAMERA_HOST_TEST
    __asm__ volatile("csrs mie,%0"::"r"(1u<<11):"memory");
#endif
}
/* Commands are queued while PL is busy and applied between complete frames. */
static void poll_controls(void)
{
    display_finish_if_acked();
    static uint32_t key_since;
    static unsigned key_sample,key_stable;
    uint32_t now=cycles();
    unsigned gpio_inputs=style_read(GPIO,0);
    unsigned key=gpio_inputs&1u;
    static uint8_t wave_seen=255u;
    unsigned wave=((gpio_inputs>>3)&1u)|((style_read(CAMERA_CSR_BASE,CAM_CSR_STATUS)>>7)&2u);
    unsigned wave_change=wave^wave_seen;
    if(wave_seen<4u && !processing_paused && !model_step_request)
        model_step_request=style_input_core_wave_step(input_state.wave,wave_change);
    wave_seen=(uint8_t)wave;
    if(key!=key_sample){key_sample=key;key_since=now;}
    else if(key!=key_stable && (uint32_t)(now-key_since)>=2000000u){
        key_stable=key;
        if(key)desired_mode=(desired_mode+1u)&3u;
    }
    camera_service(input_state.vflip);
    style_camera_wait_service();
    process_touch_events();
    // Sapphire UART RX occupancy is STATUS[31:24]. Bound the drain time.
    for(unsigned i=0;i<16 && (style_read(UART,4)>>24);i++){
        unsigned c=style_read(UART,0)&255u;
        unsigned action=style_input_command((unsigned char)c,&input_state);
        if(action==STYLE_INPUT_CLEAR){
            text(display_diag_toggle(DISPLAY_DIAG_CLEAR)?"UF CLEAR\r\n":"UF BUSY/TO\r\n");
        }
        else if(action==STYLE_INPUT_DIAGNOSTICS)print_diagnostics();
    }
    sync_frame_event_selection();
    update_processing_fps();
    if(display_ui_initialized&&(desired_scene!=applied_scene||
       post_state.desired!=ui_displayed_post||post_state.table_desired!=ui_displayed_table||
       ui_config.page!=ui_displayed_page||
       desired_ui_enable!=applied_ui_enable||desired_wipe_x!=applied_wipe_x||
       ui_param_generation!=ui_param_displayed||
       processing_fps_bcd!=published_fps_bcd||processing_fps_valid!=published_fps_valid))
        ui_controls_dirty=1;
    if(display_ui_initialized&&current_hand_marker()!=displayed_hand_marker)
        ui_controls_dirty=1;
}
static uint32_t checked_status(void)
{
    uint32_t s=style_read(STYLE_CONTROL_BASE,SYS_STATUS);
    if(s&(SYS_BOOT_FAULT|SYS_ERROR|SYS_FRAME_ERROR))stop("PL_ERR");
    return s;
}
static void wait_status(uint32_t set,uint32_t clear)
{
    uint32_t began=cycles();
    for(;;){uint32_t s=checked_status();if((s&set)==set && !(s&clear))return;
        poll_controls();
        if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT)stop("PL_TO");}
}
static void wait_video_mode(unsigned mode)
{
    uint32_t began=cycles();
    for(;;){
        checked_status();poll_controls();
        uint32_t status=style_read(STYLE_CONTROL_BASE,SYS_MODE_STATUS);
        if(status&SYS_SENSOR_FAULT)stop("SENSOR");
        if(!(status&(SYS_MODE_BUSY|SYS_SENSOR_SWITCHING)) &&
           style_read(STYLE_CONTROL_BASE,SYS_MODE_ACTIVE)==mode &&
           style_read(STYLE_CONTROL_BASE,SYS_CAMERA_MODE)==mode)return;
        if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT)stop("MODE_TO");
    }
}
static void report_mode(unsigned mode)
{
    text("MODE ");put('0'+mode);text(" ");
    text("\r\n");
}
/* Map both endpoints of an input axis onto the complete HDMI axis.  Ceil is
 * required here: truncation can leave the final output coordinate one source
 * pixel short.  A one-pixel source or destination has no interval to scale. */
static uint32_t display_axis_step(unsigned source_extent,unsigned display_extent)
{
    if(source_extent<=1u || display_extent<=1u)return 0;
    uint32_t span=(uint32_t)(source_extent-1u)<<16;
    return (span+(display_extent-2u))/(display_extent-1u);
}
static void display_submit_frame(unsigned mode,uint32_t source_base,uint32_t result_base,
                                 unsigned post,unsigned table,unsigned result_generation,
                                 unsigned result_model,unsigned updates_result,unsigned wait_for_ack)
{
    unsigned w=mode==VIDEO_1080_30?1920u:mode==VIDEO_720_30?1280u:854u;
    unsigned h=mode==VIDEO_1080_30?1080u:mode==VIDEO_720_30?720u:480u;
    unsigned stride=w==854u?1728u:w*2u;
    unsigned scene=desired_scene,ui_enable=desired_ui_enable,wipe_x=desired_wipe_x;
    unsigned split=scene==3u;
    unsigned dest_y=split?270u:0u;
    unsigned dest_h=split?540u:1080u;
    unsigned dest_scale_w=split?960u:1920u;
    uint16_t hand_marker=current_hand_marker();
    if(ui_hint_request)ui_hint_request=0;
    uint32_t began;
    uint32_t mailbox=style_read(STYLE_DISPLAY_BASE,0x38);
    if(!(mailbox&2u))stop("DISP_BUSY");
    uint32_t fps_bcd=processing_fps_bcd;unsigned fps_valid=processing_fps_valid;
    style_write(STYLE_DISPLAY_BASE,0x00,scene);
    style_write(STYLE_DISPLAY_BASE,0x04,source_base);
    style_write(STYLE_DISPLAY_BASE,0x08,result_base);
    style_write(STYLE_DISPLAY_BASE,0x0c,(h<<16)|w);
    style_write(STYLE_DISPLAY_BASE,0x10,0); /* source origin: full frame starts at (0,0) */
    style_write(STYLE_DISPLAY_BASE,0x14,dest_y<<16); /* destination origin: centered vertically */
    style_write(STYLE_DISPLAY_BASE,0x18,(dest_h<<16)|1920u);
    style_write(STYLE_DISPLAY_BASE,0x1c,stride);
    style_write(STYLE_DISPLAY_BASE,0x20,stride);
    style_write(STYLE_DISPLAY_BASE,0x24,display_axis_step(w,dest_scale_w));
    style_write(STYLE_DISPLAY_BASE,0x28,display_axis_step(h,dest_h));
    style_write(STYLE_DISPLAY_BASE,0x30,ui_enable?1u:0u);
    style_write(STYLE_DISPLAY_BASE,0x34,wipe_x);
    display_commit_ui_generation=ui_param_generation;
    display_commit_result_generation=result_generation;
    display_commit_updates_result=updates_result;
    display_ui_update(mode,fps_bcd,fps_valid,result_generation,post,table,result_model);
    style_write(STYLE_DISPLAY_BASE,DISPLAY_UI_HINT,hand_marker);
    display_commit_post=post;display_commit_table=table;
    display_commit_model=result_model;
    display_commit_ui_post=post_state.desired;display_commit_ui_table=post_state.table_desired;
    display_commit_ui_page=ui_config.page;
    display_commit_hand_marker=hand_marker;
    current_video_mode=mode;applied_scene=scene;applied_ui_enable=ui_enable;applied_wipe_x=wipe_x;
    published_fps_bcd=fps_bcd;published_fps_valid=fps_valid;
    display_commit_waiting=1;
    style_write(STYLE_DISPLAY_BASE,0x38,1);
    if(wait_for_ack){
        began=cycles();
        while(display_commit_waiting){poll_controls();
            if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT)stop("DISP_TO");}
    }
}
__attribute__((used,noinline)) static int model_load_asset(const style_model_asset *asset)
{
    if(!style_model_asset_valid(asset,SP_MODEL_BYTES,MODEL_FORMAT_W8A8))return 0;
    arm_irq();
    if(sp_request_model(&pipeline,asset->address)!=SP_PENDING)return 0;
    uint32_t began=cycles();
    for(;;){
        int r=sp_poll(&pipeline);
        if(r==SP_DONE)return 1;
        if(r<0)break;
        poll_controls();
        if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT)break;
    }
    /* A failed/timeout model transfer may still own the shared DDR reader.
       Wait for it to drain before resetting only the software state. */
    began=cycles();
    while((style_read(STYLE_LINK_BASE,SP_L_STATUS)&1u)||
          (style_read(STYLE_NPU_BASE,SP_N_STATUS)&1u)){
        poll_controls();
        if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT)return -1;
    }
    pipeline.state=SP_IDLE;
    return 0;
}
static int model_loader_callback(void *context,const style_model_asset *asset)
{
    (void)context;
    return model_load_asset(asset);
}
static void process_model_step(void)
{
    int direction=model_step_request;
    if(!direction)return;
    model_step_request=0;
    if(processing_paused){ui_hint_request=1;return;}
    unsigned next=current_model_index;
    int switched;
    if(direction>=2){
        unsigned target=(unsigned)direction-2u;
        if(target==current_model_index)return;
        switched=style_model_try_select(model_directory,model_directory_count,
            current_model_index,target,model_loader_callback,NULL,&next);
    }else switched=style_model_try_switch(model_directory,model_directory_count,
        current_model_index,direction,model_loader_callback,NULL,&next);
    if(switched<0)stop("MODEL_RESTORE");
    if(switched>0)current_model_index=(uint8_t)next;
    ui_hint_request=1; /* No other verified model package is installed. */
}
static void run_claimed_frames(unsigned mode,uint32_t *seen_sequence,uint32_t *beat)
{
    for(;;){
        process_model_step();
        /* Bind the original image to the same locked input whose result is
           about to be produced. Hardware retains this bank across PUBLISH
           until the display reader has drained the old descriptor and VS has
           atomically switched to the new source. */
        uint32_t frame_source=style_read(STYLE_CONTROL_BASE,SYS_CLAIM_BASE);
        unsigned frame_generation=ui_param_applied;
        unsigned frame_post=style_post_begin_frame(&post_state);
        unsigned frame_table=post_state.table_active_frame;
        uint32_t result=style_read(STYLE_CONTROL_BASE,SYS_TARGET_BASE);
        arm_irq();
        style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_START_FRAME);
        display_ui_live_state(DISPLAY_STATE_PROCESSING);
        wait_status(SYS_FRAME_DONE,SYS_FRAME_BUSY);
        display_ui_live_state(DISPLAY_STATE_PUBLISHING);

        if(!steady_frames_started){
            /* Establish the initial source/result geometry synchronously. */
            frame_source=style_read(STYLE_CONTROL_BASE,SYS_CLAIM_BASE);
            display_submit_frame(mode,frame_source,result,frame_post,frame_table,frame_generation,current_model_index,1u,1u);
            style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_PUBLISH_FRAME);
            wait_status(0,SYS_DISPLAY_PENDING);
            display_finish_if_acked();
            steady_frames_started=1;
            *beat^=1u;style_write(GPIO,4,*beat);
            return;
        }

        /* This claim supplied the source shown with the prior result.  Its
           descriptor must be acknowledged before the camera may reuse it. */
        wait_status(0,SYS_DISPLAY_PENDING);
        display_finish_if_acked();
        style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_PUBLISH_FRAME);
        unsigned claimed=0;
        uint32_t s=checked_status();
        uint32_t oldseq=style_read(STYLE_CONTROL_BASE,SYS_CAMERA_SEQUENCE);
        if(!processing_paused&&desired_mode==mode&&
           (s&SYS_CAMERA_VALID)&&oldseq!=*seen_sequence){
            claim_camera();
            s=checked_status();
            if(s&SYS_CAMERA_HELD){
                *seen_sequence=style_read(STYLE_CONTROL_BASE,SYS_CLAIM_SEQUENCE);
                claimed=1;
            }
        }

        /* Commit result and original from the same completed claim. A newer
           claim, if available, remains CPU-locked for the next NPU frame. */
        display_submit_frame(mode,frame_source,result,frame_post,frame_table,frame_generation,current_model_index,1u,0u);
        *beat^=1u;style_write(GPIO,4,*beat);
        if(!claimed){
            display_ui_live_state(processing_paused?DISPLAY_STATE_PAUSED:DISPLAY_STATE_READY);
            return;
        }
    }
}
int main(void)
{
    input_state.table_count=table_directory_count;
    // Bring-up progress marks land in the NPU CSR scratch register, which the
    // stub holds and echoes, so they stay readable over JTAG even when the
    // UART never comes up. The last value read back names the last good step.
    style_write(GPIO,4,style_read(GPIO,4)&~6u); /* Bus output latches stay zero. */
    style_write(GPIO,8,1); /* Only LED0 is driven; camera pins start released. */
    style_write(GPIO,4,1); /* Keep the original LED0 startup indication. */
    style_write(UART,8,100000000u/(115200u*8u)-1);
    style_write(UART,12,7);
    text("[A]\r\n");
    style_write(PLIC,PLIC_ENABLE,0);
    style_write(PLIC,PLIC_SOURCE*4,1);
    style_write(PLIC,0x200000,0);
#ifndef STYLE_CAMERA_HOST_TEST
    __asm__ volatile("csrs mstatus,%0"::"r"(8u):"memory");
#endif
    text("[E]\r\n");
    // Diagnostic reads remain available while the processing domain resets.
    uint32_t began=cycles();
    while((style_read(STYLE_APB_BASE,4)&0x880u)!=0x880u){
        (void)gesture_uart_service(&input_state,cycles());
    if((uint32_t)(cycles()-began)>CONTROL_TIMEOUT)stop("DDR_TO");
    }
    post_state=(style_post_state){.desired=IPX_RGB_CURVE,.configured_next=IPX_RGB_CURVE,
        .active_frame=IPX_RGB_CURVE,.displayed=IPX_RGB_CURVE,.table_desired=0,.table_configured_next=0,
        .table_active_frame=0,.table_displayed=0};
    ch9350_touch_init(&touch_ctx,NULL);
    touch_ms=0;touch_subcycles=0;
    touch_last_cycles=cycles();touch_last_service_cycles=touch_last_cycles;
    touch_clock_started=1;
    if(style_read(STYLE_CONTROL_BASE,SYS_VERSION)!=UINT32_C(0x53594302))stop("CTRL_VER");
    if(checked_status()&(SYS_CAMERA_HELD|SYS_FRAME_BUSY))stop("CPU_OWNED");
    camera_init();
    if(camera_faulted())stop("CAM_INIT");
    desired_mode=style_read(STYLE_CONTROL_BASE,SYS_MODE_REQUEST);
    style_write(STYLE_CONTROL_BASE,SYS_COMMAND,SYS_LOAD_FLASH);wait_status(SYS_BOOT_DONE,0);
    ui_live_state_current=DISPLAY_STATE_STARTING;
    fps_state=(style_fps_state){0};
    pipeline.npu=(volatile uint32_t *)(uintptr_t)STYLE_NPU_BASE;
    pipeline.ipx=(volatile uint32_t *)(uintptr_t)STYLE_IPX_BASE;
    pipeline.link=(volatile uint32_t *)(uintptr_t)STYLE_LINK_BASE;
    pipeline.state=SP_IDLE;
    if(model_load_asset(&model_directory[0])!=1)stop("MODEL_LOAD");
    if(style_read(STYLE_LINK_BASE,SP_L_VERSION)!=UINT32_C(0x53545002) ||
       style_read(STYLE_IPX_BASE,IPX_VERSION)!=IPX_INTERFACE_V21 ||
       style_read(STYLE_IPX_BASE,IPX_CAPABILITIES)!=IPX_CAPS_V21)stop("ENG_VER");
    if(load_color_table_asset(&table_directory[0])!=SP_DONE)stop("T_INIT");
    loaded_table=0;table_generation=(uint16_t)(style_read(STYLE_IPX_BASE,IPX_TABLE_STATUS)>>16);
    display_catalog_init();
    style_write(STYLE_IPX_BASE,IPX_OPTIONS,IPX_MODE_COLOR(IPX_RGB_CURVE));
    style_write(STYLE_IPX_BASE,IPX_SATURATION,256);style_write(STYLE_IPX_BASE,IPX_ALPHA,256);
    style_write(STYLE_IPX_BASE,IPX_AI_ALPHA,256);style_write(STYLE_IPX_BASE,IPX_AI_CONTROL,IPX_ENABLE_AI_MIX);
    ui_controls_dirty=1; /* Apply the complete UI shadow before its first frame. */
    // PL derives fixed geometry/strides from the claimed two-bit mode.
    unsigned current_mode=style_read(STYLE_CONTROL_BASE,SYS_MODE_REQUEST);
    wait_video_mode(current_mode);report_mode(current_mode);
    text("READY L=post L2=table R=input\r\n");
    uint32_t seen=0,beat=0;
    display_ui_live_state(DISPLAY_STATE_READY);
    for(;;){
        poll_controls();
        // Poll fallback is deliberately kept; a lost notification cannot stall
        // a complete frame. No UART or delay loop runs in the frame hot path.
        uint32_t s=checked_status(),seq=style_read(STYLE_CONTROL_BASE,SYS_CAMERA_SEQUENCE);
        if(!(s&(SYS_DISPLAY_PENDING|SYS_FRAME_BUSY))&&display_ui_initialized){
            unsigned state=processing_paused?DISPLAY_STATE_PAUSED:DISPLAY_STATE_READY;
            if(ui_live_state_current!=state)display_ui_live_state(state);
        }
        if(!(s&(SYS_DISPLAY_PENDING|SYS_FRAME_BUSY|SYS_CAMERA_HELD)) && desired_mode!=current_mode){
            unsigned selected=desired_mode;
            display_ui_live_state(DISPLAY_STATE_MODE_SWITCH);
            style_write(STYLE_CONTROL_BASE,SYS_MODE_REQUEST,selected);
            wait_video_mode(selected);current_mode=selected;current_video_mode=selected;report_mode(selected);
            steady_frames_started=0; /* Re-establish a paired source and new geometry once. */
            display_ui_live_state(DISPLAY_STATE_READY);
            // Process the first new-mode frame even when its sequence wrapped.
            seen=style_read(STYLE_CONTROL_BASE,SYS_CAMERA_SEQUENCE)-1u;
            continue;
        }
        if(current_hand_marker()!=displayed_hand_marker&&
           !(s&(SYS_DISPLAY_PENDING|SYS_FRAME_BUSY|SYS_CAMERA_HELD))&&ui_controls_dirty){
            /* Reuse the acknowledged display shadow/VS commit to move or hide
               the marker even if camera/NPU processing is paused or stalled. */
            display_apply_ui_controls();
            s=checked_status();
        }
        if(processing_paused&&!(s&(SYS_DISPLAY_PENDING|SYS_FRAME_BUSY|SYS_CAMERA_HELD))&&ui_controls_dirty){
            display_apply_ui_controls();
            s=checked_status();
        }
        if(processing_paused||desired_mode!=current_mode||(s&SYS_FRAME_BUSY))continue;
        if(s&SYS_CAMERA_HELD){
            run_claimed_frames(current_mode,&seen,&beat);
            continue;
        }
        if(!(s&SYS_CAMERA_VALID)||seq==seen)continue;
        claim_camera();
        s=checked_status();
        if(!(s&SYS_CAMERA_HELD))continue;
        seen=style_read(STYLE_CONTROL_BASE,SYS_CLAIM_SEQUENCE);
        run_claimed_frames(current_mode,&seen,&beat);
    }
}

