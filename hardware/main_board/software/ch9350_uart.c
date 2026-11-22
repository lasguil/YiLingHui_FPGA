#include "ch9350_uart.h"

#ifndef CH9350_UART_READ_REG
#define CH9350_UART_READ_REG(regs,offset) ((regs)[(offset)/4u])
#endif
unsigned ch9350_uart_service(ch9350_touch *ctx,uintptr_t base,uint32_t now_ms,unsigned budget){
    volatile uint32_t *regs=(volatile uint32_t *)base;
    unsigned done=0;
    while(done<budget){
        if(CH9350_UART_READ_REG(regs,CH9350_UART_LEVEL)==0)break;
        ch9350_touch_feed(ctx,(uint8_t)CH9350_UART_READ_REG(regs,CH9350_UART_DATA),now_ms);
        done++;
    }
    ch9350_touch_tick(ctx,now_ms);
    return done;
}
