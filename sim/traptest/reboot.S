# syscon reboot check (RTL only: the emulator stops on a reboot request).
# Counts boots in an SDRAM word, which survives the reset, prints "boot N",
# reboots after the first boot and powers off after the second.
    .section .text.start
    .globl _start
_start:
    li t0, 0x80100000
    lw t1, 0(t0)
    addi t1, t1, 1
    sw t1, 0(t0)
    li t2, 0xF0001000
    la t3, msg
1:  lbu t4, 0(t3)
    beqz t4, 3f
2:  lw t5, 20(t2)           # LSR: wait for THRE
    andi t5, t5, 0x20
    beqz t5, 2b
    sw t4, 0(t2)
    addi t3, t3, 1
    j 1b
3:  lw t5, 20(t2)
    andi t5, t5, 0x40
    beqz t5, 3b
    addi t4, t1, '0'
    sw t4, 0(t2)
    li t4, '\n'
4:  lw t5, 20(t2)
    andi t5, t5, 0x40
    beqz t5, 4b
    sw t4, 0(t2)
5:  lw t5, 20(t2)           # let the UART finish before resetting
    andi t5, t5, 0x40
    beqz t5, 5b
    li t2, 0xF0002000
    li t4, 0x7777
    li t5, 2
    blt t1, t5, 6f
    li t4, 0x5555
6:  sw t4, 0(t2)
7:  j 7b
msg: .asciz "boot "
