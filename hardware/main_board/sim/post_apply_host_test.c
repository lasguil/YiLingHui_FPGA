/* Exercise the real UI ACK and real camera-claim/configuration functions.
 * MMIO and table DMA only are replaced. A UI ACK must not discard IPX work. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef STYLE_CONTROL_SOURCE
#define STYLE_CONTROL_SOURCE "../software/style_control.c"
#endif
#define main firmware_main
#include STYLE_CONTROL_SOURCE
#undef main

volatile uint32_t style_test_cycles;
static uint32_t ipx_registers[64],claims,table_loads;
#define CHECK(c) do{if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);exit(2);}}while(0)
static unsigned catalog_index,catalog_writes;
static unsigned char catalog_bytes[STYLE_UI_CATALOG_TOTAL_BYTES],catalog_seen[STYLE_UI_CATALOG_TOTAL_BYTES];
static int catalog_recording;
uint32_t style_read(uint32_t base,unsigned reg)
{
    if(base==STYLE_IPX_BASE)return ipx_registers[reg/4];
    if(base==STYLE_DISPLAY_BASE&&reg==0x38)return 2; /* VS commit acknowledged */
    if(base==UART&&reg==4)return 1u<<16; /* TX space; never invoke wait service */
    return 0;
}
void style_write(uint32_t base,unsigned reg,uint32_t value)
{
    if(catalog_recording&&base==STYLE_DISPLAY_BASE){
        if(reg==DISPLAY_UI_CATALOG_INDEX){catalog_index=value;CHECK(catalog_index<sizeof catalog_bytes);}
        if(reg==DISPLAY_UI_CATALOG_DATA){
            CHECK(catalog_index<sizeof catalog_bytes&&!catalog_seen[catalog_index]);
            catalog_bytes[catalog_index]=(unsigned char)value;catalog_seen[catalog_index++]=1;catalog_writes++;
        }
    }
    if(base==STYLE_IPX_BASE)ipx_registers[reg/4]=value;
    if(base==STYLE_CONTROL_BASE&&reg==SYS_COMMAND&&value==SYS_CLAIM_CAMERA)claims++;
}
int sp_load_color_table(struct sp_context *ctx,uint32_t address)
{(void)ctx;(void)address;table_loads++;ipx_registers[IPX_TABLE_STATUS/4]+=1u<<16;return SP_DONE;}
int sp_load_color_table_builtin(struct sp_context *ctx,unsigned preset)
{return sp_load_color_table(ctx,preset);}
void camera_service(unsigned flip){(void)flip;}
int sp_request_model(struct sp_context *ctx,uint32_t address){(void)ctx;(void)address;return SP_PENDING;}
int sp_poll(struct sp_context *ctx){(void)ctx;return SP_DONE;}

static void acknowledge_ui_before_claim(void)
{
    display_commit_waiting=1;
    display_commit_updates_result=0;
    display_commit_ui_generation=ui_param_generation;
    display_commit_ui_post=post_state.desired;
    display_commit_ui_table=post_state.table_desired;
    display_finish_if_acked();
    CHECK(!ui_controls_dirty);
    claim_camera(); /* Actual product boundary: does not depend on UI dirty. */
    CHECK(ui_param_applied==ui_param_generation);
}
int main(void)
{
    catalog_recording=1;display_catalog_init();catalog_recording=0;
    CHECK(catalog_writes==STYLE_UI_CATALOG_TOTAL_BYTES);
    char expected[STYLE_UI_CATALOG_SLOT_BYTES];
    for(unsigned i=0;i<model_directory_count+table_directory_count;i++){
        unsigned is_model=i<model_directory_count,index=is_model?i:i-model_directory_count;
        const char *name=is_model?model_directory[index].name:table_directory[index].name;
        unsigned len=0;while(name[len])len++;
        CHECK(style_ui_catalog_format(expected,name,len,is_model?STYLE_UI_CATALOG_MODEL_MAX_CHARS:STYLE_UI_CATALOG_TABLE_MAX_CHARS));
        CHECK(!memcmp(catalog_bytes+(is_model?style_ui_catalog_model_index(index):style_ui_catalog_table_index(index)),expected,sizeof expected));
    }
    printf("PASS boot catalog: %u bytes, every slot written once, exact names and padding\n",catalog_writes);
    input_state.table_count=table_directory_count;
    post_state=(style_post_state){0};
    loaded_table=0;ui_param_applied=0;
    input_state.ui.preserve=1;
    for(unsigned i=0;i<6;i++){
        CHECK(style_input_action(STYLE_ACTION_RANGE,&input_state));
        acknowledge_ui_before_claim();
        CHECK(ipx_registers[IPX_COLOR_MIN/4]==IPX_RGB(ui_config.bounds[0],ui_config.bounds[2],ui_config.bounds[4]));
        CHECK(ipx_registers[IPX_COLOR_MAX/4]==IPX_RGB(ui_config.bounds[1],ui_config.bounds[3],ui_config.bounds[5]));
        CHECK(ipx_registers[IPX_OPTIONS/4]&IPX_PRESERVE);
    }
    for(unsigned table=0;table<table_directory_count;table++)for(unsigned color=0;color<4;color++){
        CHECK(style_input_set(STYLE_SET_TABLE,table,&input_state));
        CHECK(style_input_action(STYLE_ACTION_COLOR0+color,&input_state));
        sync_frame_event_selection();
        acknowledge_ui_before_claim();
        CHECK(loaded_table==table);
        CHECK(post_state.configured_next==color&&post_state.table_configured_next==table);
        CHECK(ipx_registers[IPX_OPTIONS/4]==(IPX_MODE_COLOR(color)|IPX_PRESERVE));
    }
    CHECK(table_loads==table_directory_count-1);
    printf("PASS real UI-ACK-before-IPX regression: %u claims, %u table loads, all RGB ranges and 4 modes\n",claims,table_loads);
    return 0;
}
