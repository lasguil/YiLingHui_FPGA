ENTRY(_start)
MEMORY { OCR (rwx) : ORIGIN = 0xf9000000, LENGTH = 16K }
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) } > OCR
    .data : { *(.data*) *(.sdata*) } > OCR
    .bss (NOLOAD) : {
        . = ALIGN(4); __bss_start = .;
        *(.bss*) *(.sbss*) *(COMMON)
        . = ALIGN(4); __bss_end = .;
    } > OCR
    /DISCARD/ : { *(.comment*) *(.eh_frame*) }
}
ASSERT(__bss_end <= ORIGIN(OCR) + LENGTH(OCR) - 2048,
       "Firmware exceeds 16 KiB OCR budget; preserve at least 2 KiB stack")
