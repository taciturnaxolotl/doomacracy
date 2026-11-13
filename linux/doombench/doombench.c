/*
 * doombench: measure the CPU and memory system from inside Linux.
 *
 * Each test runs a fixed amount of work and reports wall time (from the
 * CLINT timer through clock_gettime), cycles and instructions retired (the
 * cycle and instret CSRs, readable from user mode here), so it shows the
 * real CPI on hardware. In the emulator the counters come from its cycle
 * model (--timing) or the fixed --cpi, so the same table compares the two.
 *
 * Buffers stay at 128 KB or less: on this no-MMU system the largest free
 * contiguous block is a few hundred KB.
 *
 *   doombench        all tests
 *   doombench -q     shorter runs
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

static uint32_t rd_cycle(void)   { uint32_t v; __asm__ volatile("csrr %0, cycle" : "=r"(v)); return v; }
static uint32_t rd_instret(void) { uint32_t v; __asm__ volatile("csrr %0, instret" : "=r"(v)); return v; }

static uint64_t now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

static int scale = 4;           /* -q divides the work */
static volatile uint32_t sink;  /* keeps results alive */

struct mark { uint64_t us; uint32_t cyc, ins; };
static struct mark start;

static void begin(void)
{
    start.us  = now_us();
    start.ins = rd_instret();
    start.cyc = rd_cycle();
}

/* Print one row. work/unit say what to divide by for the rate column. */
static void end(const char *name, double work, const char *unit)
{
    uint32_t cyc = rd_cycle() - start.cyc;
    uint32_t ins = rd_instret() - start.ins;
    uint64_t us  = now_us() - start.us;
    double secs = us / 1e6;
    if (secs <= 0)
        secs = 1e-6;
    printf("%-16s %7.1f ms  %8.2f %-6s CPI %5.2f  %4.1f MHz\n", name, us / 1000.0,
           work / secs, unit, ins ? (double)cyc / ins : 0.0, cyc / secs / 1e6);
}

/* ---------------------------------------------------------------- tests */

static void t_alu(void)
{
    uint32_t a = 1, b = 2, c = 3, i, n = 2000000u / 4 * scale;
    begin();
    for (i = 0; i < n; i++) {
        a += b ^ c;
        b = (b << 3) | (b >> 29);
        c -= a & 0x5555;
    }
    sink = a + b + c;
    end("alu", n * 6.0 / 1e6, "Mop/s");
}

static void t_mul(void)
{
    uint32_t a = 12345, i, n = 500000u / 4 * scale;
    begin();
    for (i = 0; i < n; i++)
        a = a * 1103515245u + i;
    sink = a;
    end("mul", n / 1e6, "M/s");
}

static void t_div(void)
{
    uint32_t a = 0xdeadbeef, s = 0, i, n = 100000u / 4 * scale;
    begin();
    for (i = 1; i <= n; i++)
        s += a / i + a % (i | 1);
    sink = s;
    end("div", n * 2.0 / 1e6, "M/s");
}

static int cmp_u32(const void *x, const void *y)
{
    uint32_t a = *(const uint32_t *)x, b = *(const uint32_t *)y;
    return a < b ? -1 : a > b;
}

/* branchy, call-heavy code that fits in the caches */
static void t_qsort(void)
{
    static uint32_t v[1024];
    uint32_t seed = 1, r, rounds = 6u / 2 * scale, i;
    begin();
    for (r = 0; r < rounds; r++) {
        for (i = 0; i < 1024; i++) {
            seed = seed * 1664525u + 1013904223u;
            v[i] = seed;
        }
        qsort(v, 1024, sizeof v[0], cmp_u32);
    }
    sink = v[0];
    end("qsort 1K", rounds * 1024.0 / 1e3, "Kel/s");
}

/* sequential word reads over a buffer of the given size, many passes */
static void t_read(uint32_t *buf, uint32_t bytes, const char *name)
{
    uint32_t words = bytes / 4, pass, passes = (1u << 21) / bytes * scale, i, s = 0;
    for (i = 0; i < words; i++)
        buf[i] = i;
    begin();
    for (pass = 0; pass < passes; pass++)
        for (i = 0; i < words; i += 4)
            s += buf[i] + buf[i + 1] + buf[i + 2] + buf[i + 3];
    sink = s;
    end(name, (double)bytes * passes / 1048576.0, "MB/s");
}

static void t_write(uint32_t *buf, uint32_t bytes, const char *name)
{
    uint32_t words = bytes / 4, pass, passes = (1u << 21) / bytes * scale, i;
    begin();
    for (pass = 0; pass < passes; pass++)
        for (i = 0; i < words; i += 4) {
            buf[i] = pass; buf[i + 1] = pass; buf[i + 2] = pass; buf[i + 3] = pass;
        }
    end(name, (double)bytes * passes / 1048576.0, "MB/s");
}

static void t_memcpy(uint8_t *a, uint8_t *b, uint32_t bytes)
{
    uint32_t pass, passes = (1u << 20) / bytes * scale;
    begin();
    for (pass = 0; pass < passes; pass++)
        memcpy(pass & 1 ? a : b, pass & 1 ? b : a, bytes);
    end("memcpy 64K", (double)bytes * passes / 1048576.0, "MB/s");
}

/* dependent loads in a random cycle, one per cache line: load latency */
static void t_chase(uint32_t *buf, uint32_t bytes, const char *name)
{
    uint32_t lines = bytes / 16, i, j, t, p = 0, n = 200000u / 4 * scale;
    uint32_t *perm = buf;      /* line index permutation, stored in the buffer itself */
    uint32_t seed = 7;
    for (i = 0; i < lines; i++)
        perm[i * 4] = i;
    for (i = lines - 1; i > 0; i--) {   /* Sattolo: one big cycle */
        seed = seed * 1664525u + 1013904223u;
        j = seed % i;
        t = perm[i * 4]; perm[i * 4] = perm[j * 4]; perm[j * 4] = t;
    }
    begin();
    for (i = 0; i < n; i++)
        p = buf[p * 4];
    sink = p;
    {
        uint32_t cyc = rd_cycle() - start.cyc;
        uint64_t us = now_us() - start.us;
        printf("%-16s %7.1f ms  %8.1f ns    %5.1f cycles per load\n", name, us / 1000.0,
               us * 1000.0 / n, (double)cyc / n);
    }
}

static void t_syscall(void)
{
    uint32_t i, n = 20000u / 4 * scale;
    begin();
    for (i = 0; i < n; i++)
        sink += getppid();
    end("syscall", n / 1e3, "K/s");
}

/* vfork + exec of a small program: the cost of starting a process here */
static void t_spawn(const char *self)
{
    uint32_t i, n = 8, ok = 0;
    begin();
    for (i = 0; i < n; i++) {
        pid_t p = vfork();
        if (p == 0) {
            execl(self, self, "--noop", (char *)0);
            _exit(127);
        }
        if (p > 0) {
            int st;
            waitpid(p, &st, 0);
            ok += WIFEXITED(st) && WEXITSTATUS(st) == 0;
        }
    }
    end("spawn", ok, "/s");
    if (ok != n)
        printf("  (%u of %u spawns failed: not enough contiguous memory)\n", n - ok, n);
}

int main(int argc, char **argv)
{
    uint32_t *a, *b;
    uint64_t t0;

    if (argc > 1 && !strcmp(argv[1], "--noop"))
        return 0;
    if (argc > 1 && !strcmp(argv[1], "-q"))
        scale = 1;

    a = malloc(128 * 1024);
    b = malloc(64 * 1024);
    if (!a || !b) {
        puts("doombench: not enough memory for the buffers");
        return 1;
    }

    printf("doombench  (work x%d)\n", scale);
    printf("test                time      rate           CPI    cycle clock\n");
    t0 = now_us();
    t_alu();
    t_mul();
    t_div();
    t_qsort();
    t_read(a, 4 * 1024, "read 4K");
    t_read(a, 128 * 1024, "read 128K");
    t_write(a, 4 * 1024, "write 4K");
    t_write(a, 128 * 1024, "write 128K");
    t_memcpy((uint8_t *)a, (uint8_t *)b, 64 * 1024);
    t_chase(a, 4 * 1024, "latency 4K");
    t_chase(a, 128 * 1024, "latency 128K");
    t_syscall();
    t_spawn(argv[0][0] == '/' ? argv[0] : "/usr/bin/doombench");
    printf("total %.1f s\n", (now_us() - t0) / 1e6);
    return 0;
}
