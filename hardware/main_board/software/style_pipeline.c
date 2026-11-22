#include "style_pipeline.h"

#ifdef STYLE_CAMERA_HOST_TEST
extern uint32_t style_test_pipeline_read(uintptr_t base,unsigned offset);
extern void style_test_pipeline_write(uintptr_t base,unsigned offset,uint32_t value);
static uint32_t rd(volatile uint32_t *base, unsigned offset)
{ return style_test_pipeline_read((uintptr_t)base,offset); }
static void wr(volatile uint32_t *base, unsigned offset, uint32_t value)
{ style_test_pipeline_write((uintptr_t)base,offset,value); }
#else
static uint32_t rd(volatile uint32_t *base, unsigned offset) { return base[offset/4]; }
static void wr(volatile uint32_t *base, unsigned offset, uint32_t value) { base[offset/4]=value; }
#endif
static void barrier(void)
{
#if defined(__riscv)
    __asm__ volatile("fence iorw, iorw" ::: "memory");
#else
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}
static unsigned process_width(const struct sp_frame *f)
{
    return f->width==SP_480_VISIBLE_WIDTH ? SP_480_PROCESS_WIDTH : f->width;
}
/* 一条带的中心范围与流行接缝：内部接缝各多一个四点组，帧边不扩展。 */
struct sp_strip { uint32_t x; uint16_t width, stream_width; uint8_t lo, hi; };
static struct sp_strip strip_geom(const struct sp_frame *f, uint32_t x)
{
    unsigned full=process_width(f);
    struct sp_strip s;
    s.x=x;
    s.width=(uint16_t)((full-x>SP_STRIP_PIXELS) ? SP_STRIP_PIXELS : (full-x));
    s.lo=(uint8_t)(x ? SP_SEAM_PIXELS : 0u);
    s.hi=(uint8_t)((x+s.width<full) ? SP_SEAM_PIXELS : 0u);
    s.stream_width=(uint16_t)(s.width+s.lo+s.hi);
    return s;
}
static int valid_frame(const struct sp_frame *f)
{
    uint32_t end[4];
    const uint32_t base[4]={f->original,f->npu_rgb,f->final,f->x0};
    if (!((f->width==SP_480_VISIBLE_WIDTH && f->height==480) ||
          (f->width==1280 && f->height==720) ||
          (f->width==1920 && f->height==1080))) return 0;
    if ((f->rgb_stride&15) || f->rgb_stride<2u*process_width(f) ||
        (f->x0_stride&15) || f->x0_stride<8u*process_width(f)) return 0;
    if(f->width==SP_480_VISIBLE_WIDTH && f->rgb_stride<SP_480_RGB_STRIDE)return 0;
    for (unsigned i=0;i<4;i++) {
        if (base[i]&15) return 0;
        /* Accepted height <=1080, uint16_t stride: the span fits uint32_t.
         * Check the addition before doing it; retain exact overflow/overlap
         * rejection without 64-bit arrays, multiply, carry and comparisons. */
        uint32_t span=i==3 ? (uint32_t)f->x0_stride*(f->height/4) : (uint32_t)f->rgb_stride*f->height;
        if(base[i]>UINT32_MAX-span)return 0;
        end[i]=base[i]+span;
        for (unsigned j=0;j<i;j++)
            if (!(end[i]<=base[j] || end[j]<=base[i])) return 0;
    }
    return 1;
}
static void post_start(struct sp_context *ctx)
{
    const struct sp_frame *f=&ctx->frame;
    struct sp_strip s=strip_geom(f,ctx->x);
    unsigned win_width=s.stream_width; /* 颜色管线仍消费完整 halo，由无 RAM crop token 保留中心。 */
    uint32_t original=f->original+2u*(s.x-s.lo);
    wr(ctx->ipx,IPX_DST,f->final+2u*s.x);
    wr(ctx->ipx,IPX_ORIGINAL_SRC,original);
    wr(ctx->ipx,IPX_STREAM_EDGE,IPX_EDGE_HALO(s.lo,s.hi));
    wr(ctx->ipx,IPX_WINDOW_SIZE,IPX_SIZE(win_width,f->height));
    wr(ctx->ipx,IPX_DST_SIZE,IPX_SIZE(s.width,f->height));
    wr(ctx->ipx,IPX_CONTROL,IPX_START|IPX_IRQ_ENABLE);
    barrier();
}
int sp_request_model(struct sp_context *ctx, uint32_t model_base)
{
    if (ctx->state!=SP_IDLE || (rd(ctx->link,SP_L_STATUS)&1)) return SP_BUSY;
    if ((model_base&15) || model_base>UINT32_MAX-SP_MODEL_BYTES) return SP_INVALID;
    wr(ctx->npu,SP_N_IRQ,15);wr(ctx->npu,SP_N_EVENTS,15);
    wr(ctx->npu,SP_N_MODEL,model_base);barrier();wr(ctx->npu,SP_N_COMMAND,2);
    ctx->state=SP_MODEL;
    return SP_PENDING;
}
int sp_submit(struct sp_context *ctx, const struct sp_frame *frame)
{
    if (ctx->state!=SP_IDLE || (rd(ctx->link,SP_L_STATUS)&1)) return SP_BUSY;
    uint32_t options=rd(ctx->ipx,IPX_OPTIONS), tables=rd(ctx->ipx,IPX_TABLE_STATUS);
    if (!valid_frame(frame) || !(rd(ctx->npu,SP_N_STATUS)&8) ||
        (options&UINT32_C(0xfffffdcf))!=0 || !(tables&IPX_TABLE_STATUS_VALID) ||
        (tables&IPX_TABLE_STATUS_LOADING)) return SP_INVALID;
    ctx->frame=*frame;ctx->x=0;ctx->n_finished=0;ctx->p_finished=0;
    wr(ctx->link,SP_L_RGB_BASE,frame->npu_rgb);
    wr(ctx->link,SP_L_RGB_LIMIT,frame->npu_rgb+(uint32_t)frame->rgb_stride*frame->height);
    wr(ctx->link,SP_L_CONTROL,2u); /* Reset only the idle bridge credit. */
    wr(ctx->npu,SP_N_IRQ,15);wr(ctx->npu,SP_N_EVENTS,15);
    wr(ctx->npu,SP_N_SIZE,IPX_SIZE(process_width(frame)/4,frame->height/4));
    wr(ctx->npu,SP_N_INPUT,frame->original);wr(ctx->npu,SP_N_OUTPUT,frame->npu_rgb);wr(ctx->npu,SP_N_X0,frame->x0);
    wr(ctx->npu,SP_N_INPUT_STRIDE,frame->rgb_stride);wr(ctx->npu,SP_N_OUTPUT_STRIDE,frame->rgb_stride);wr(ctx->npu,SP_N_X0_STRIDE,frame->x0_stride);
    wr(ctx->ipx,IPX_DST_STRIDE,frame->rgb_stride);wr(ctx->ipx,IPX_ORIGINAL_STRIDE,frame->rgb_stride);
    wr(ctx->ipx,IPX_CONTROL,IPX_CLEAR_DONE|IPX_IRQ_ENABLE);
    ctx->state=SP_FRAME;
    post_start(ctx); /* Issue post first; hardware grants exact AW credit. */
    barrier();wr(ctx->npu,SP_N_COMMAND,1);
    return SP_PENDING;
}
int sp_poll(struct sp_context *ctx)
{
    uint32_t events=rd(ctx->npu,SP_N_EVENTS), post=rd(ctx->ipx,IPX_STATUS);
    if (ctx->state==SP_IDLE) return SP_DONE;
    if (ctx->state==SP_FAULT) return SP_HW_ERROR;
    if (ctx->state==SP_ABORTING) {
        if (rd(ctx->link,SP_L_STATUS)&1) return SP_PENDING;
        wr(ctx->link,SP_L_CONTROL,2);wr(ctx->npu,SP_N_EVENTS,15); /* 清discard并复位空闲桥信用。 */
        wr(ctx->ipx,IPX_CONTROL,IPX_CLEAR_DONE|IPX_IRQ_ENABLE);
        ctx->state=SP_IDLE;return SP_ABORTED;
    }
    if ((events&8) || (ctx->state==SP_FRAME && ((events&2) || (post&0xf0)))) {
        ctx->state=SP_FAULT;return SP_HW_ERROR;
    }
    if (ctx->state==SP_MODEL) {
        if (!(events&4)) return SP_PENDING;
        wr(ctx->npu,SP_N_EVENTS,4);ctx->state=SP_IDLE;return SP_DONE;
    }
    if (events&1) ctx->n_finished=1;
    if ((post&IPX_DONE) && !ctx->p_finished) {
        struct sp_strip s=strip_geom(&ctx->frame,ctx->x);
        if (ctx->x+s.width<process_width(&ctx->frame)) {
            ctx->x=(uint16_t)(ctx->x+s.width);post_start(ctx);return SP_PENDING;
        }
        ctx->p_finished=1;
    }
    if (!ctx->n_finished || !ctx->p_finished || (rd(ctx->link,SP_L_STATUS)&1)) return SP_PENDING;
    barrier();ctx->state=SP_IDLE;return SP_DONE;
}
int sp_abort(struct sp_context *ctx)
{
    if (ctx->state==SP_IDLE) return SP_DONE;
    if (ctx->state==SP_MODEL) return SP_BUSY; /* A model DMA has no separate cancellation command. */
    wr(ctx->link,SP_L_CONTROL,1u); /* Drain local W, including AW waiting on zero credit. */
    wr(ctx->ipx,IPX_CONTROL,IPX_ABORT|IPX_IRQ_ENABLE);
    if (rd(ctx->link,SP_L_STATUS)&8) { barrier();wr(ctx->npu,SP_N_COMMAND,2); } /* Existing model command cancels a frame. */
    ctx->state=SP_ABORTING;
    return SP_PENDING;
}

static uint32_t sp_cycles(void)
{
#if defined(__riscv)
    /* The Efinity soft core does not implement mcycle. Keep DMA timeout
     * polling on the same CLINT mtime source used by style_control.c. */
    volatile uint32_t *const mtime=(volatile uint32_t *)(uintptr_t)UINT32_C(0xf8b0bff8);
    uint32_t hi0,lo,hi1;
    do { hi0=mtime[1];lo=mtime[0];hi1=mtime[1]; } while(hi0!=hi1);
    return lo;
#else
    static uint32_t value;return ++value;
#endif
}

/* Start the IPX's existing read DMA. CPU AXI has no DDR route, so the CPU
 * never dereferences this source address. The caller owns a stable 768-byte
 * DDR buffer until loading clears. */
int sp_load_color_table(struct sp_context *ctx, uint32_t ddr_address)
{
    const uint32_t ddr_begin=UINT32_C(0x01000000);
    const uint32_t ddr_end=UINT32_C(0x02000000);
    if(!ctx || !ctx->ipx || ddr_address<ddr_begin ||
       (ddr_address&15u)||ddr_address>ddr_end-IPX_TABLE_BYTES) return SP_INVALID;
    if(ctx->state!=SP_IDLE || (ctx->link&&(rd(ctx->link,SP_L_STATUS)&1u)) ||
       (rd(ctx->ipx,IPX_STATUS)&IPX_BUSY)) return SP_BUSY;
    uint32_t status=rd(ctx->ipx,IPX_TABLE_STATUS);
    if(status&IPX_TABLE_STATUS_LOADING) return SP_BUSY;
    uint16_t generation=IPX_TABLE_GENERATION(status);
    wr(ctx->ipx,IPX_ORIGINAL_SRC,ddr_address);
    barrier();wr(ctx->ipx,IPX_TABLE_COMMAND,IPX_TABLE_LOAD_DDR);barrier();
    uint32_t began=sp_cycles();
    for(;;){
        status=rd(ctx->ipx,IPX_TABLE_STATUS);
        if(!(status&IPX_TABLE_STATUS_LOADING))
            return ((status&IPX_TABLE_STATUS_VALID)&&
                    IPX_TABLE_GENERATION(status)==(uint16_t)(generation+1u))?SP_DONE:SP_HW_ERROR;
        if((uint32_t)(sp_cycles()-began)>UINT32_C(500000000)){
            wr(ctx->ipx,IPX_CONTROL,IPX_ABORT);barrier();
            return SP_HW_ERROR;
        }
    }
}

/* The two demo presets are generated byte-by-byte, avoiding a CPU-side
 * 768-byte array and avoiding any claim that CPU can write DDR. */
int sp_load_color_table_builtin(struct sp_context *ctx, unsigned preset)
{
    if(!ctx||!ctx->ipx||preset>1u)return SP_INVALID;
    if(ctx->state!=SP_IDLE||(ctx->link&&(rd(ctx->link,SP_L_STATUS)&1u))||
       (rd(ctx->ipx,IPX_STATUS)&IPX_BUSY))return SP_BUSY;
    uint32_t before=rd(ctx->ipx,IPX_TABLE_STATUS);
    if(before&IPX_TABLE_STATUS_LOADING)return SP_BUSY;
    uint16_t generation=IPX_TABLE_GENERATION(before);
    wr(ctx->ipx,IPX_TABLE_COMMAND,IPX_TABLE_BEGIN);barrier();
    for(unsigned channel=0;channel<3;channel++)for(unsigned i=0;i<256;i++){
        unsigned value=preset==0u?i:(channel==0?(i*5u+255u)/6u:
                                            channel==1?(i*4u+255u)/5u:(i*2u)/3u);
        wr(ctx->ipx,IPX_TABLE_DATA,(uint32_t)(uint8_t)value);
    }
    if(rd(ctx->ipx,IPX_TABLE_INDEX)!=IPX_TABLE_BYTES||
       !(rd(ctx->ipx,IPX_TABLE_STATUS)&IPX_TABLE_STATUS_LOADING))return SP_HW_ERROR;
    barrier();wr(ctx->ipx,IPX_TABLE_COMMAND,IPX_TABLE_COMMIT);barrier();
    uint32_t status=rd(ctx->ipx,IPX_TABLE_STATUS);
    if(!(status&IPX_TABLE_STATUS_VALID)||(status&IPX_TABLE_STATUS_LOADING)||
       IPX_TABLE_GENERATION(status)!=(uint16_t)(generation+1u))return SP_HW_ERROR;
    return SP_DONE;
}
