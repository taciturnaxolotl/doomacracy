// Runs from the boot ROM and pokes every part of the SoC. Prints results on
// the UART and leaves a test pattern on screen, then ebreak.
#include <stdint.h>
#define IO(off) (*(volatile uint32_t *)(0xF0000000u + (off)))

static void out(char c) { while (!(IO(0x04) & 1)) ; IO(0x00) = (uint8_t)c; }
static void puts_(const char *s) { while (*s) out(*s++); }
static void hex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) out("0123456789abcdef"[(v >> i) & 15]); }

static uint32_t h = 2166136261u;
static void mix(uint32_t v) { for (int i = 0; i < 4; i++) { h ^= (v >> (8 * i)) & 0xff; h *= 16777619u; } }
static volatile uint32_t seed = 12345;
static uint32_t rnd(void) { uint32_t s = seed; s ^= s << 13; s ^= s >> 17; s ^= s << 5; seed = s; return s; }

static int check_region(const char *name, uint32_t base, uint32_t span) {
    // words at scattered addresses, then bytes and halves into a cached line
    volatile uint32_t *w = (volatile uint32_t *)base;
    int bad = 0;
    seed = 777;
    for (int i = 0; i < 256; i++) { uint32_t off = (rnd() % (span / 4)); w[off] = off * 2654435761u; }
    seed = 777;
    for (int i = 0; i < 256; i++) { uint32_t off = (rnd() % (span / 4)); if (w[off] != off * 2654435761u) bad++; }
    volatile uint8_t *b = (volatile uint8_t *)(base + 64);
    volatile uint16_t *s = (volatile uint16_t *)(base + 128);
    for (int i = 0; i < 32; i++) { b[i] = (uint8_t)(i * 7 + 1); s[i] = (uint16_t)(i * 1031 + 5); }
    for (int i = 0; i < 32; i++) { if (b[i] != (uint8_t)(i * 7 + 1)) bad++; if (s[i] != (uint16_t)(i * 1031 + 5)) bad++; }
    // sequential sweep crossing many lines (exercises fills after write-through)
    for (int i = 0; i < 2048; i++) w[1024 + i] = i ^ 0x5a5a0000u;
    for (int i = 0; i < 2048; i++) if (w[1024 + i] != (i ^ 0x5a5a0000u)) bad++;
    puts_(name); puts_(bad ? " FAIL " : " ok "); hex(bad); out('\n');
    return bad;
}

int main(void) {
    puts_("soctest\n");
    IO(0x20) = 0xD00D;
    int bad = 0;
    bad += check_region("sram ", 0x10010000u, 0x40000u);
    bad += check_region("sdram", 0x20000000u, 0x800000u);

    // flash: first 16 bytes, as bytes and as a word
    puts_("flash ");
    for (int i = 0; i < 8; i++) { out(' '); hex(*(volatile uint8_t *)(0x30000000u + i) & 0xff); }
    out(' '); hex(*(volatile uint32_t *)0x30000000u); out('\n');

    for (int i = 0; i < 500; i++) { int32_t a = rnd(), b = rnd() | 1; mix(a * b); mix(a / b); mix((uint32_t)a % (uint32_t)b); }
    puts_("alu "); hex(h); out('\n');

    // video: grey ramp palette plus a few pure colours, then x^y into buffer A
    for (int i = 0; i < 256; i++) IO(0x38) = (uint32_t)i << 24 | (uint32_t)i << 16 | (uint32_t)i << 8 | i;
    IO(0x38) = 1u << 24 | 0xff0000; IO(0x38) = 2u << 24 | 0x00ff00; IO(0x38) = 3u << 24 | 0x0000ff;
    volatile uint8_t *fb = (volatile uint8_t *)0x10060000u;
    for (int y = 0; y < 200; y++)
        for (int x = 0; x < 320; x++)
            fb[y * 320 + x] = (x < 8 || x >= 312 || y < 8 || y >= 192) ? (uint8_t)(1 + (x / 8 + y / 8) % 3) : (uint8_t)((x ^ y) & 0xff);
    IO(0x30) = 0x60000;
    uint32_t f = IO(0x34);
    while (IO(0x34) == f) ;
    puts_("frames "); hex(IO(0x34)); puts_(" us "); hex(IO(0x08)); out('\n');
    // echo PS/2 bytes for a while (the testbench types some)
    puts_("kbd");
    for (uint32_t end = IO(0x34) + 2; IO(0x34) != end; ) {
        uint32_t k = IO(0x10);
        if (k & 0x100) { out(' '); hex(k & 0xff); }
    }
    out('\n');
    puts_(bad ? "FAIL\n" : "PASS\n");
    IO(0x18) = bad ? 0x3ff : 1;
    return bad;
}
