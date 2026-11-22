.section .text.start,"ax",@progbits
.globl _start
_start:
    la sp, __stack_top
    csrw mie, zero
    la t0, trap
    csrw mtvec, t0
    call main
trap:
    j trap
