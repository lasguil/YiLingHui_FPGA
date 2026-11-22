#ifndef STYLE_UI_CATALOG_H
#define STYLE_UI_CATALOG_H
#include <stdint.h>
#include "style_model_assets_generated.h"

/* One catalog RAM shared by UI text. CPU writes through index/data;
 * each data write stores one ASCII byte then increments the 10-bit index. */
enum {
    DISPLAY_UI_CATALOG_INDEX = 0x70,
    DISPLAY_UI_CATALOG_DATA = 0x74,
    DISPLAY_UI_CATALOG_INFO = 0x78,
    STYLE_UI_CATALOG_MODEL_MAX_CHARS = 10,
    STYLE_UI_CATALOG_TABLE_MAX_CHARS = 16
};

static inline unsigned style_ui_catalog_model_index(unsigned slot)
{ return STYLE_UI_CATALOG_MODEL_BASE + slot * STYLE_UI_CATALOG_SLOT_BYTES; }

static inline unsigned style_ui_catalog_table_index(unsigned slot)
{ return STYLE_UI_CATALOG_TABLE_BASE + slot * STYLE_UI_CATALOG_SLOT_BYTES; }

static inline uint32_t style_ui_catalog_info(unsigned model_count,unsigned table_count)
{ return (model_count&STYLE_UI_COUNT_MODEL_MASK)|((table_count&STYLE_UI_COUNT_TABLE_MASK)<<STYLE_UI_COUNT_TABLE_SHIFT); }

/* The UI glyph ROM implements exactly these 40 low-six-bit codes. Normalize
 * lowercase ASCII to uppercase before the low-six-bit address is consumed. */
static inline int style_ui_catalog_normalize_char(unsigned char input,unsigned char *out)
{
    if(!out)return 0;
    unsigned char c=input;
    if(c>='a'&&c<='z')c=(unsigned char)(c-'a'+'A');
    if(!((c>='A'&&c<='Z')||(c>='0'&&c<='9')||c==' '||c=='-'||c=='/'||c=='.'))return 0;
    *out=c;
    return 1;
}

/* Names are left-justified and space padded. name must point to name_length
 * readable bytes (it need not be NUL terminated); empty names clear a slot. */
static inline int style_ui_catalog_format(char out[STYLE_UI_CATALOG_SLOT_BYTES],
    const char *name,unsigned name_length,unsigned max_chars)
{
    if(!out||!name||max_chars>STYLE_UI_CATALOG_SLOT_BYTES||name_length>max_chars)return 0;
    for(unsigned i=0;i<STYLE_UI_CATALOG_SLOT_BYTES;i++)
        out[i]=' ';
    for(unsigned i=0;i<name_length;i++){
        unsigned char c;
        if(!style_ui_catalog_normalize_char((unsigned char)name[i],&c))return 0;
        out[i]=(char)c;
    }
    return 1;
}

#endif
