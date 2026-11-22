ENTRY(_start)
MEMORY { OCR (rwx) : ORIGIN = 0xf9000000, LENGTH = 24K }
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) } > OCR
    .data : { *(.data*) *(.sdata*) } > OCR
    .bss (NOLOAD) : { . = ALIGN(4); __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > OCR
    /DISCARD/ : { *(.comment*) *(.eh_frame*) }
}
__stack_top = ORIGIN(OCR) + LENGTH(OCR);
ASSERT(SIZEOF(.text) + SIZEOF(.data) + SIZEOF(.bss) <= 0x5800, "Reserve at least 2KB stack")
