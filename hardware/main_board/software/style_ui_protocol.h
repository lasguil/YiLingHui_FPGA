#ifndef STYLE_UI_PROTOCOL_H
#define STYLE_UI_PROTOCOL_H
#include <stdint.h>
#include "style_model_assets_generated.h"

/* UI protocol v1. It requires the matching candidate display RTL. */
enum {
    STYLE_UI_PAGE_HOME=0, STYLE_UI_PAGE_COLOR=1, STYLE_UI_PAGE_ADJUST=2,
    STYLE_UI_PAGE_KEEP=3, STYLE_UI_PAGE_RGB=4
};
enum { STYLE_UI_DATA=0x40, STYLE_UI_HINT=0x44, STYLE_UI_METRICS=0x48,
       STYLE_UI_VALUE0=0x64, STYLE_UI_VALUE1=0x68, STYLE_UI_VALUE2=0x6c };

/* UI_HINT is carried by the existing VS-atomic display mailbox. Hand marker
 * wire/CSR value: x_cell[6:0], y_cell[6:0]; x=127 hides the marker. */
#define STYLE_HAND_MARKER_INVALID 127u
static inline uint16_t style_hand_marker_pack(unsigned x_cell,unsigned y_cell)
{
    if(x_cell>=120u||y_cell>=68u)x_cell=STYLE_HAND_MARKER_INVALID,y_cell=0u;
    return (uint16_t)((x_cell&0x7fu)|((y_cell&0x7fu)<<7));
}

/* UI_DATA: page[2:0], color[4:3], model index[7:5] + high bits 27 and 31,
 * table index[13:11] + high bit 28, wave source {bit15,bit16},
 * preserve[17], range[20:18], pending[21],
 * paused[22], mode[24:23], view[26:25], camera flip[29], full hide[30].
 * Dynamic model/table counts travel in catalog-info CSR 0x078. */
static inline uint32_t style_ui_metadata(unsigned page,unsigned color,
    unsigned model_index,unsigned table_index,
    unsigned preserve,unsigned range,unsigned pending,unsigned paused,
    unsigned mode,unsigned view)
{
    return (page&7u)|((color&3u)<<3)|((model_index&7u)<<STYLE_UI_METADATA_MODEL_INDEX_LOW_SHIFT)|
           ((table_index&7u)<<11)|((preserve&1u)<<17)|
           ((range&7u)<<18)|((pending&1u)<<21)|((paused&1u)<<22)|
           ((mode&3u)<<23)|((view&3u)<<25)|((model_index&8u)<<24)|
           ((model_index&16u)<<27)|((table_index&8u)<<25);
}

/* Preserve the existing CORE=1 bit16; use free bit15 for EXT=2.
 * Do not shift a two-bit mode into bit16: bit17 belongs to Keep Color. */
static inline uint32_t style_ui_wave_metadata(unsigned source)
{
    return ((source&1u)<<16)|((source&2u)<<14);
}

/* Eight packed 12-bit BCD values, little-endian by slot, without 64-bit math. */
static inline void style_ui_pack_values(const uint16_t v[8],uint32_t words[3])
{
    words[0]=(uint32_t)(v[0]&0xfffu)|((uint32_t)(v[1]&0xfffu)<<12)|
             ((uint32_t)(v[2]&0xffu)<<24);
    words[1]=((uint32_t)(v[2]>>8)&0xfu)|((uint32_t)(v[3]&0xfffu)<<4)|
             ((uint32_t)(v[4]&0xfffu)<<16)|((uint32_t)(v[5]&0xfu)<<28);
    words[2]=((uint32_t)(v[5]>>4)&0xffu)|((uint32_t)(v[6]&0xfffu)<<8)|
             ((uint32_t)(v[7]&0xfffu)<<20);
}

static inline uint16_t style_ui_percent_bcd(unsigned percent)
{
    unsigned n=percent;
    if(n>999u)n=999u;
    return (uint16_t)(((n/100u)<<8)|(((n/10u)%10u)<<4)|(n%10u));
}

#endif
