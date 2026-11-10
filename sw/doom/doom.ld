/* doomacracy firmware linker script (spec.md "SRAM layout")
 *
 *   SRAM  0x10000000..0x10060000 : hot .text/.rodata/.data, render buffer,
 *                                  stack (16 KB) at the top
 *   SDRAM 0x20000000..           : .cold (cold code/data, see below), .bss, heap
 *
 * The whole program does not fit in the 384 KB SRAM firmware area, so code
 * and data that only run at startup, in menus, on level load or per game tic
 * (libc stdio/printf, savegames, menus, config, intermission, automap...)
 * go into a ".cold" section that lives in SDRAM. The boot ROM copies only
 * the SRAM image (header.length bytes); the cold image is stored in flash
 * right after it (flash 0x100 + header.length) and crt0 copies it to SDRAM
 * before anything else runs.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

STACK_SIZE = 0x4000;

MEMORY
{
    SRAM  (rwx) : ORIGIN = 0x10000000, LENGTH = 0x60000
    SDRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 8M
}

SECTIONS
{
    /* hot pieces of the C libraries, listed first so .cold cannot take them */
    .text.boot : {
        KEEP(*(.text.start))
        *libc.a:libc_a-mem*.o(.text .text.*)
        *libc.a:libc_a-str*.o(.text .text.*)
        *libgcc.a:*(.text .text.*)
    } > SRAM

    .cold : ALIGN(16) {
        __cold_start = .;
        *libc.a:*(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *libm.a:*(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *libgloss.a:*(.text .text.* .rodata .rodata.* .data .data.* .sdata .sdata.*)
        *libnosys.a:*(.text .text.* .rodata .rodata.* .data .data.* .sdata .sdata.*)
        *syscalls.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *am_map.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *d_iwad.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *d_main.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *d_mode.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *dstrings.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *dummy.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *f_finale.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *g_game.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *hu_lib.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *hu_stuff.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *i_cdmus.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *i_endoom.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *i_joystick.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *i_scale.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *i_sound.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *i_system.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *m_argv.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *m_config.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *m_controls.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *m_menu.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *m_misc.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *memio.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *p_saveg.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *p_setup.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *s_sound.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *sha1.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *sounds.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *statdump.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *w_checksum.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *w_file.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *w_file_flash.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *w_main.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        *wi_stuff.o(.text .text.* .rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
        . = ALIGN(16);
        __cold_end = .;
    } > SDRAM

    .text : {
        *(.text.hot .text.hot.*)
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
    __fw_end = .;

    /* uninitialised SRAM data (not part of the image, not zeroed by crt0):
       Doom's 320x200 render buffer lives here so the renderer's byte
       stores go to SRAM instead of SDRAM */
    .sram_bss (NOLOAD) : ALIGN(16) {
        *(.sram_bss .sram_bss.*)
        . = ALIGN(16);
    } > SRAM
    __sram_bss_end = .;

    /* stack: top of the firmware area, must not collide with the image */
    __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    __stack_limit = __stack_top - STACK_SIZE;
    ASSERT(__sram_bss_end <= __stack_limit, "firmware too large: collides with the stack")

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > SDRAM

    __heap_start = ALIGN(__bss_end, 16);
    __heap_end = ORIGIN(SDRAM) + LENGTH(SDRAM);

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
