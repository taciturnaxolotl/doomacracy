# Entry, trap entry, the vector table and the U-mode trampoline for
# traptest.c. Booted like a kernel: at 0x80000000 in M-mode.
    .section .text.start
    .globl _start
_start:
    li sp, 0x80400000
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call main
3:  j 3b

# Direct mode handler: save the caller-saved registers, call trap_c(frame).
    .text
    .balign 64
    .globl trap_entry
trap_entry:
    addi sp, sp, -64
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw a0, 16(sp)
    sw a1, 20(sp)
    sw a2, 24(sp)
    sw a3, 28(sp)
    sw a4, 32(sp)
    sw a5, 36(sp)
    sw a6, 40(sp)
    sw a7, 44(sp)
    sw t3, 48(sp)
    sw t4, 52(sp)
    sw t5, 56(sp)
    sw t6, 60(sp)
    mv a0, sp
    call trap_c
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw a0, 16(sp)
    lw a1, 20(sp)
    lw a2, 24(sp)
    lw a3, 28(sp)
    lw a4, 32(sp)
    lw a5, 36(sp)
    lw a6, 40(sp)
    lw a7, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 64
    mret

# Vectored mode: entry k leaves k in mscratch for the C handler to see.
    .balign 64
    .globl vec_table
vec_table:
    j vec0
    j vec1
    j vec2
    j vec3
    j vec4
    j vec5
    j vec6
    j vec7
vec0: csrwi mscratch, 16
    j trap_entry
vec1: csrwi mscratch, 1
    j trap_entry
vec2: csrwi mscratch, 2
    j trap_entry
vec3: csrwi mscratch, 3
    j trap_entry
vec4: csrwi mscratch, 4
    j trap_entry
vec5: csrwi mscratch, 5
    j trap_entry
vec6: csrwi mscratch, 6
    j trap_entry
vec7: csrwi mscratch, 7
    j trap_entry

# run_user(fn): mret into fn in U-mode; fn ends with an ecall, whose
# handler sends us back to user_return in M-mode.
    .globl run_user
run_user:
    la t0, saved_sp
    sw sp, 0(t0)
    sw ra, 4(t0)
    csrw mepc, a0
    li t0, 0x1880               # MPP = U, MPIE = 0: U runs with MIE clear
    csrc mstatus, t0
    mret
    .globl user_return
user_return:
    la t0, saved_sp
    lw sp, 0(t0)
    lw ra, 4(t0)
    ret

# code run in U-mode: count a little, then ecall
    .globl user_fn
user_fn:
    li a0, 5
    li a1, 0
1:  add a1, a1, a0
    addi a0, a0, -1
    bnez a0, 1b
    la t0, user_result
    sw a1, 0(t0)
    ecall
2:  j 2b

    .data
    .balign 4
saved_sp: .word 0, 0
