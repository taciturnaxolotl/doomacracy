/* boot ROM: 4 KB at 0x0, code only (no .data/.bss/.rodata allowed) */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = 4K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM

    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ROM
    .data : { *(.data .data.* .sdata .sdata.*) } > ROM
    .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } > ROM

    ASSERT(SIZEOF(.rodata) == 0, "boot ROM must not have .rodata")
    ASSERT(SIZEOF(.data) == 0, "boot ROM must not have .data")
    ASSERT(SIZEOF(.bss) == 0, "boot ROM must not have .bss")

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
