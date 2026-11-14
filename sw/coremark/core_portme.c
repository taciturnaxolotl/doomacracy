/*
 * doomacracy port of EEMBC CoreMark: timing, seeds and main.
 *
 * Runs the benchmark twice, as EEMBC's run rules ask: once with the
 * performance seeds (0, 0, 0x66) and once with the validation seeds
 * (0x3415, 0x3415, 0x66). Both reports must say "Correct operation
 * validated"; the score is the performance run's "CoreMark 1.0" line.
 *
 * Time comes from TIMER_US. The cycle and instret counters are read at the
 * same two moments, so each run also prints the cycles per instruction of
 * the timed part alone.
 */
#include <stdio.h>
#include "coremark.h"
#include "doomacracy_hw.h"
#undef main

#define CLK_HZ 50000000u

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

/* the benchmark is built as plain rv32im; only these reads need Zicsr */
#define CSR_READ(name, csr)                                                    \
    static uint32_t name(void)                                                 \
    {                                                                          \
        uint32_t v;                                                            \
        __asm__ volatile(".option push\n.option arch, +zicsr\n"                \
                         "csrr %0, " #csr "\n.option pop" : "=r"(v));          \
        return v;                                                              \
    }
CSR_READ(cyc_lo, mcycle)
CSR_READ(cyc_hi, mcycleh)
CSR_READ(ins_lo, minstret)
CSR_READ(ins_hi, minstreth)

static uint64_t rd64(uint32_t (*lo)(void), uint32_t (*hi)(void))
{
    uint32_t h, l;
    do {
        h = hi();
        l = lo();
    } while (h != hi());
    return (uint64_t)h << 32 | l;
}
static uint32_t t_start, t_stop;
static uint64_t cyc_start, cyc_stop, ins_start, ins_stop;

void start_time(void)
{
    ins_start = rd64(ins_lo, ins_hi);
    cyc_start = rd64(cyc_lo, cyc_hi);
    t_start = TIMER_US;
}

void stop_time(void)
{
    t_stop = TIMER_US;
    cyc_stop = rd64(cyc_lo, cyc_hi);
    ins_stop = rd64(ins_lo, ins_hi);
}

CORE_TICKS get_time(void) { return t_stop - t_start; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks / 1e6; }

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    uint64_t cyc = cyc_stop - cyc_start, ins = ins_stop - ins_start;
    p->portable_id = 0;
    /* the last timed run is the measured one */
    printf("Cycles           : %llu\n", (unsigned long long)cyc);
    printf("Instructions     : %llu\n", (unsigned long long)ins);
    printf("Cycles/instr     : %.3f\n", ins ? (double)cyc / (double)ins : 0.0);
}

int main(void)
{
    LEDG = 0x01;
    HEX = 0xC001;
    printf("\nEEMBC CoreMark 1.0 on doomacracy, RV32IM at %u MHz\n", CLK_HZ / 1000000u);
    puts("CoreMark/MHz is the \"CoreMark 1.0\" score of the performance run / 50.");

    puts("\n--- performance run: seeds 0, 0, 0x66 ---");
    coremark_main();

    seed1_volatile = seed2_volatile = 0x3415;
    seed4_volatile = ITERATIONS;
    LEDG = 0x03;
    HEX = 0xC002;
    puts("\n--- validation run: seeds 0x3415, 0x3415, 0x66 ---");
    coremark_main();

    /* upstream returns 0 even when a CRC is wrong: read both reports */
    puts("\ncoremark: done");
    LEDG = 0xFF;
    return 0;
}
