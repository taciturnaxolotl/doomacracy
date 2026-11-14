/* CoreMark firmware linker script. Everything is in the SRAM firmware area
 * (spec.md "SRAM layout"), below the framebuffers: code, data, .bss, a small
 * heap for printf, and the stack at the top. sw/doom/crt0.S is the startup
 * code; there is no cold image, so __cold_start = __cold_end. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

STACK_SIZE = 0x4000;

MEMORY
{
    SRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 0x60000
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > SRAM

    .init_array : {
        PROVIDE_HIDDEN(__init_array_start = .);
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE_HIDDEN(__init_array_end = .);
        PROVIDE_HIDDEN(__preinit_array_start = .);
        KEEP(*(.preinit_array))
        PROVIDE_HIDDEN(__preinit_array_end = .);
        PROVIDE_HIDDEN(__fini_array_start = .);
        KEEP(*(.fini_array))
        PROVIDE_HIDDEN(__fini_array_end = .);
    } > SRAM

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > SRAM

    .data : ALIGN(4) {
        *(.data .data.*)
        . = ALIGN(4);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(16);
    } > SRAM

    __cold_start = .;
    __cold_end = .;

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > SRAM

    __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    __heap_start = ALIGN(__bss_end, 16);
    __heap_end = __stack_top - STACK_SIZE;
    ASSERT(__heap_start + 0x2000 <= __heap_end, "CoreMark firmware too large: no room for the heap")

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
