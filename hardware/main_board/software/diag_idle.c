/* Bring-up firmware: GPIO heartbeat and read-only APB diagnostics.
 * CPU never accesses the DDR AXI master. No heap, interrupts, or libc. */
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define UART 0xf8010000u
#define GPIO 0xf8015000u
#define DIAG 0xf8100000u
static void put(char c) {
    unsigned timeout=1000000;
    while (((REG(UART+4)>>16)&255)==0 && --timeout) {}
    if(timeout) REG(UART)=(unsigned char)c;
}
static void hex(uint32_t x) {
    for(int i=28;i>=0;i-=4) {
        unsigned v=(x>>i)&15;
        put(v<10 ? '0'+v : 'A'+v-10);
    }
}
int main(void) {
    REG(GPIO+8)=15;
    REG(UART+8)=100000000u/(115200u*8u)-1;
    REG(UART+12)=7; /* 8N1 */
    unsigned beat=0;
    for(;;) {
        REG(GPIO+4)=(beat^=1);
        put('D');put(' ');
        for(unsigned i=0;i<8;i++) {hex(REG(DIAG+4*i));put(' ');}
        put('\r');put('\n');
        for(volatile unsigned delay=0;delay<3000000;delay++) {}
    }
}
