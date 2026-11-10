/*
 * doomacracy boot ROM (runs from 0x0, see spec.md "Flash image").
 *
 * Reads the flash header, copies the firmware from flash 0x100 to load_addr
 * and jumps to entry. On a bad header it prints an error on the UART, lights
 * the LEDs and spins.
 *
 * The ROM is only guaranteed to be readable by instruction fetch, so this file
 * must not produce .rodata/.data/.bss: strings are printed with puts_imm(),
 * which the compiler unrolls into "li a0, c" immediates (the Makefile checks
 * that the ELF has no data sections).
 */
#include <stdint.h>
#include "doomacracy_hw.h"

#define NOINLINE __attribute__((noinline))
#define ALWAYS_INLINE static inline __attribute__((always_inline))

static NOINLINE void putc_(uint32_t c)
{
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = c;
}

ALWAYS_INLINE void puts_imm(const char *s)
{
#pragma GCC unroll 128
    for (int i = 0; i < 128 && s[i]; i++)
        putc_((uint8_t)s[i]);
}

static NOINLINE void puthex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) {
        uint32_t d = (v >> i) & 15;
        putc_(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

/* Halt with an error. HEX cycles once a second through Ennn, then the
   upper and lower halves of the offending value, so a board without a
   serial cable still shows what went wrong. */
static NOINLINE __attribute__((noreturn)) void fail(uint32_t code, uint32_t value)
{
    puts_imm("boot: halted, error ");
    puthex(code);
    puts_imm(" value ");
    puthex(value);
    puts_imm("\r\n");
    LEDR = 0x3ff;
    LEDG = 0;
    for (uint32_t step = 0;; step++) {
        uint32_t t;
        switch (step % 3) {
        case 0:  HEX = 0xE000 | (code & 0xfff); break;
        case 1:  HEX = value >> 16; break;
        default: HEX = value & 0xffff; break;
        }
        t = TIMER_US;
        while (TIMER_US - t < 1000000u)
            ;
    }
}

void __attribute__((noreturn)) boot_main(void)
{
    volatile flash_header_t *h = FLASH_HEADER;
    uint32_t magic, load, len, entry;

    LEDR = 0;
    LEDG = 1;
    HEX = 0xB001;
    puts_imm("\r\ndoomacracy boot rom\r\n");

    magic = h->magic;
    if (magic != FLASH_MAGIC) {
        puts_imm("boot: bad flash magic ");
        puthex(magic);
        puts_imm(" (want 4d4f4f44)\r\n");
        fail(1, magic);
    }
    load = h->load_addr;
    len = h->length;
    entry = h->entry;

    puts_imm("boot: fw ");
    puthex(len);
    puts_imm(" bytes -> ");
    puthex(load);
    puts_imm(", entry ");
    puthex(entry);
    puts_imm("\r\n");

    /* firmware must land word aligned inside SRAM below the framebuffers */
    if ((load & 3) || (len & 3) || load < SRAM_BASE ||
        load + len > SRAM_BASE + FB_A_OFFSET || load + len < load ||
        len > FLASH_SIZE - FLASH_FW_OFFSET) {
        puts_imm("boot: bad load_addr/length\r\n");
        fail(2, len);
    }
    if ((entry & 3) || entry < load || entry >= load + len) {
        puts_imm("boot: bad entry\r\n");
        fail(3, entry);
    }

    HEX = 0xB002;
    {
        volatile uint32_t *src = (volatile uint32_t *)(FLASH_BASE + FLASH_FW_OFFSET);
        uint32_t *dst = (uint32_t *)load;
        uint32_t n = len >> 2;
        for (uint32_t i = 0; i < n; i++) {
            dst[i] = src[i];
            if ((i & 0x3fff) == 0)
                LEDR = i >> 14; /* progress, one step per 64 KB */
        }
    }

    puts_imm("boot: jumping\r\n");
    HEX = 0xB003;
    LEDG = 3;
    ((void (*)(void))entry)();
    fail(4, entry);
}
