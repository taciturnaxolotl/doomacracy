// Self-describing CPU check: prints a hash of many operations. Built for the
// host and for rv32im; the two outputs must match exactly.
#include <stdint.h>
#ifdef HOST
#include <stdio.h>
static void out(char c) { putchar(c); }
#else
static void out(char c) { *(volatile uint32_t *)0xF0000000u = (uint8_t)c; }
#endif
static void puts_(const char *s) { while (*s) out(*s++); }
static void hex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) out("0123456789abcdef"[(v >> i) & 15]); }

static uint32_t h = 2166136261u;
static void mix(uint32_t v) { for (int i = 0; i < 4; i++) { h ^= (v >> (8 * i)) & 0xff; h *= 16777619u; } }

static volatile uint32_t seed = 12345;
static uint32_t rnd(void) { uint32_t s = seed; s ^= s << 13; s ^= s >> 17; s ^= s << 5; seed = s; return s; }

static const int32_t edge[] = { 0, 1, -1, 2, -2, 0x7fffffff, (int32_t)0x80000000, 3, -3, 7, 0x10000, -0x10000, 0x55555555, (int32_t)0xaaaaaaaa };
#define NE (sizeof edge / sizeof edge[0])

__attribute__((noinline)) static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static volatile uint8_t bytes[64];

static void run(void) {
    for (unsigned i = 0; i < NE + 200; i++) {
        for (unsigned j = 0; j < NE + 20; j++) {
            int32_t a = i < NE ? edge[i] : (int32_t)rnd();
            int32_t b = j < NE ? edge[j] : (int32_t)rnd();
            uint32_t ua = a, ub = b;
            mix(a + b); mix(a - b); mix(a ^ b); mix(a | b); mix(a & b);
            mix(ua << (ub & 31)); mix(ua >> (ub & 31)); mix((uint32_t)(a >> (ub & 31)));
            mix(a < b); mix(ua < ub);
            mix(ua * ub);
            mix((uint32_t)(((int64_t)a * b) >> 32));
            mix((uint32_t)(((uint64_t)ua * ub) >> 32));
            mix((uint32_t)(((int64_t)a * (int64_t)(uint64_t)ub) >> 32));
            if (b != 0 && !(a == (int32_t)0x80000000 && b == -1)) { mix(a / b); mix(a % b); }
            if (ub != 0) { mix(ua / ub); mix(ua % ub); }
            int64_t wide = (int64_t)a * 1000003 + b;
            mix((uint32_t)(wide / 7)); mix((uint32_t)(wide >> 32));
        }
    }
    puts_("alu "); hex(h); out('\n');

    for (int i = 0; i < 64; i++) bytes[i] = (uint8_t)(i * 37 + 11);
    for (int i = 0; i < 61; i++) {
        mix(*(volatile int8_t *)&bytes[i]);
        mix(*(volatile uint8_t *)&bytes[i]);
        if (!(i & 1)) { mix(*(volatile int16_t *)&bytes[i]); mix(*(volatile uint16_t *)&bytes[i]); }
        if (!(i & 3)) mix(*(volatile uint32_t *)&bytes[i]);
    }
    for (int i = 0; i < 60; i += 2) *(volatile uint16_t *)&bytes[i] = (uint16_t)(i * 4099);
    for (int i = 0; i < 60; i += 4) mix(*(volatile uint32_t *)&bytes[i]);
    puts_("mem "); hex(h); out('\n');

    mix(fib(15));
    puts_("fib "); hex(fib(15)); out('\n');
    puts_("all "); hex(h); out('\n');
}

#ifdef HOST
int main(void) { run(); return 0; }
#else
void _start(void) __attribute__((naked, section(".text.start")));
void _start(void) { __asm__ volatile("li sp, 0x10000\n call main_\n ebreak\n"); }
int main_(void) { run(); return 0; }
#endif
