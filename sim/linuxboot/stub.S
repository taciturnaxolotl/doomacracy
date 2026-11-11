# Boot ROM stand-in for simulation: start a kernel (or any image) already
# preloaded at the start of SDRAM the way the emulator's --kernel does:
# M-mode at 0x80000000, a0 = 0, a1 = the DTB in the top 16 KB of 8 MB.
    .section .text
    .globl _start
_start:
    li a0, 0
    li a1, 0x807FC000
    li t0, 0x80000000
    jr t0
