/* doomacracy firmware startup. The boot ROM has already copied .text/.rodata/
 * .data into SRAM; we set sp/gp, copy the cold image from flash to SDRAM,
 * zero .bss (in SDRAM) and call main. */
    .section .text.start, "ax"
    .globl _start
_start:
    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop
    la   sp, __stack_top
    li   tp, 0

    /* copy the cold image from flash (it follows the SRAM image, whose
       length is in the flash header at +0x08) to its home in SDRAM */
    li   t2, 0x30000000
    lw   t3, 8(t2)              /* header.length */
    addi t2, t2, 0x100
    add  t2, t2, t3             /* flash source */
    la   t0, __cold_start
    la   t1, __cold_end
0:  bgeu t0, t1, 4f
    lw   t3, 0(t2)
    lw   t4, 4(t2)
    lw   t5, 8(t2)
    lw   t6, 12(t2)
    sw   t3, 0(t0)
    sw   t4, 4(t0)
    sw   t5, 8(t0)
    sw   t6, 12(t0)
    addi t2, t2, 16
    addi t0, t0, 16
    j    0b
4:

    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    sw   zero, 4(t0)
    sw   zero, 8(t0)
    sw   zero, 12(t0)
    addi t0, t0, 16
    j    1b
2:
    call __libc_init_array
    li   a0, 0
    li   a1, 0
    call main
    call exit
3:  j    3b
