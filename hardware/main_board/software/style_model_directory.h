#ifndef STYLE_MODEL_DIRECTORY_H
#define STYLE_MODEL_DIRECTORY_H
#include <stdint.h>

typedef struct {
    const char *name;
    uint32_t address;
    uint16_t bytes;
    uint8_t format,ready;
} style_model_asset;
typedef int (*style_model_loader)(void *context,const style_model_asset *asset);
static inline int style_model_asset_valid(const style_model_asset *asset,
    uint32_t required_bytes,uint8_t required_format)
{
    return asset&&asset->ready&&asset->address&&asset->bytes==required_bytes&&
        asset->format==required_format;
}

/* Exact selection never falls through to a different style on failure. */
static inline int style_model_try_select(const style_model_asset *directory,
    unsigned count,unsigned active,unsigned target,style_model_loader load,
    void *context,unsigned *next)
{
    if(!directory||active>=count||target>=count||!load||!next||
       target==active||!directory[target].ready)return 0;
    if(load(context,&directory[target])==1){*next=target;return 1;}
    return load(context,&directory[active])==1?0:-1;
}

/* Returns 1 after loading a different ready package, 0 if none/failure with
 * successful old-package restoration, and -1 if restoration also fails. */
static inline int style_model_try_switch(const style_model_asset *directory,
    unsigned count,unsigned active,int direction,style_model_loader load,
    void *context,unsigned *next)
{
    if(!directory||!count||active>=count||!load||!next)return 0;
    for(unsigned offset=1;offset<count;offset++){
        unsigned index=direction>0?(active+offset)%count:
            (active+count-(offset%count))%count;
        if(index==active||!directory[index].ready)continue;
        if(load(context,&directory[index])==1){*next=index;return 1;}
        if(load(context,&directory[active])!=1)return -1;
        return 0;
    }
    return 0;
}
#endif
