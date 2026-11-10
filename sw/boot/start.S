/* boot ROM entry: reset vector at 0x0 */
    .section .text.start, "ax"
    .globl _start
_start:
    li   sp, 0x10060000      /* top of the firmware area of SRAM */
    li   gp, 0
    li   tp, 0
    call boot_main
1:  j    1b
