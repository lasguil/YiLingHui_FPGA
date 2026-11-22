#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../software/style_pipeline.h"
#include "../../software/style_input.h"
int reference_check_frame(const struct sp_frame *);
int current_check_frame(const struct sp_frame *);
int reference_sp_request_model(struct sp_context *,uint32_t);
unsigned reference_input_action(unsigned,style_input_state *);
uint32_t style_test_pipeline_read(uintptr_t base,unsigned offset){(void)base;(void)offset;return 0;}
void style_test_pipeline_write(uintptr_t base,unsigned offset,uint32_t value){(void)base;(void)offset;(void)value;}
static uint32_t seed=0x20261112;
static uint32_t random32(void){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
#define CHECK(c) do{if(!(c)){printf("FAIL line %d\n",__LINE__);exit(2);}}while(0)
int main(void){
    unsigned frame_tests=0,model_tests=0,action_tests=0;
    for(unsigned i=0;i<100000;i++){
        const unsigned widths[]={854,1280,1920},heights[]={480,720,1080};
        unsigned mode=i%3,process=mode?widths[mode]:856;
        struct sp_frame f={.width=widths[mode],.height=heights[mode],
            .rgb_stride=(uint16_t)(((2*process+15)&~15u)+16*(random32()%64)),
            .x0_stride=(uint16_t)(((8*process+15)&~15u)+16*(random32()%64)),
            .original=random32()&~15u,.npu_rgb=random32()&~15u,.final=random32()&~15u,.x0=random32()&~15u};
        switch(i%11){
            case 0:f.final=f.original;break;
            case 1:f.original=0xfffffff0u;break;
            case 2:f.rgb_stride=65520;f.x0_stride=65520;break;
            case 3:f.x0_stride=0;break;
            case 4:f.width=640;break;
            case 5:f.npu_rgb=f.original+(uint32_t)f.rgb_stride*f.height;break;
            case 6:f.original|=1;break;
            default:break;
        }
        CHECK(reference_check_frame(&f)==current_check_frame(&f));frame_tests++;
        uint32_t base=i<4096?0xffff0000u+i*16u:random32();
        struct sp_context a={.state=SP_IDLE},b=a;
        CHECK(reference_sp_request_model(&a,base)==sp_request_model(&b,base));
        CHECK(a.state==b.state);model_tests++;
    }
    for(unsigned mode=0;mode<48;mode++)for(unsigned action=0;action<257;action++){
        style_input_state a={0},b;
        a.ui_enable=1;a.table_count=13;a.mode=mode&3;a.post=(mode>>2)&3;
        a.paused=(mode>>1)&1;a.ui_hidden_all=(mode>>3)&1;a.wave=mode%3;
        a.ui.ai=mode%2?0:100;a.ui.fx=50;a.ui.sat=195;a.ui.out_sat=100;
        a.ui.preserve=mode&1;a.ui.range=mode%3;a.gesture_ready=1;b=a;
        unsigned id=action==256?~0u:action;
        CHECK(reference_input_action(id,&a)==style_input_action(id,&b));
        CHECK(!memcmp(&a,&b,sizeof a));action_tests++;
    }
    printf("PASS equivalence: %u frame ranges, %u model ranges, %u action/state comparisons\n",frame_tests,model_tests,action_tests);
    return 0;
}
