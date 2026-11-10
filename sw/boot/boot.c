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


/* ------------------------------------------------------------ JTAG loader
 * With SW9 up at reset the ROM takes a new flash image over the USB-Blaster
 * (tools/jtag_flash.tcl) and programs it, then boots as usual.
 *
 * Stream: JTAG_MAGIC, word count n, n image words, sum of the image words.
 * The image is buffered in SDRAM first, because flash programs far slower
 * than JTAG delivers.
 *
 * HEX shows the phase: 1xxx receiving (xxx = KB / 4), 2000 erasing,
 * 3xxx programming (xxx = KB / 4), 4xxx verifying, 600d done.
 * Errors: E010 too big, E011 checksum, E012 overflow, E013 erase timeout,
 * E014 program failed, E015 verify mismatch. The value after the code is the
 * count, the sum, or the flash address.
 */
#define FL8(off) (*(volatile uint8_t *)(FLASH_BASE + (off)))

static NOINLINE uint32_t jtag_word(void)
{
    while (!(JTAG_STATUS & 1))
        ;
    return JTAG_DATA;
}

static NOINLINE void flash_cmd(uint32_t c)
{
    FL8(0xAAA) = 0xAA;
    FL8(0x555) = 0x55;
    FL8(0xAAA) = c;
}

/* data polling: while the chip is busy DQ7 reads as the complement of the
   byte being programmed (0 during an erase); it reads true when done. DQ5
   set means the chip gave up. Returns 0 on success. */
static NOINLINE uint32_t flash_wait(uint32_t off, uint32_t want)
{
    for (;;) {
        uint32_t v = FL8(off);
        if (!((v ^ want) & 0x80))
            return 0;
        if (v & 0x20) {
            v = FL8(off);
            if (!((v ^ want) & 0x80))
                return 0;
            FL8(0) = 0xF0;   /* back to read mode */
            return 1;
        }
    }
}

/* For E013/E014: two status reads, then the chip's manufacturer and device
   ID bytes. HEX shows them as ssss then mmdd. */
static NOINLINE uint32_t flash_diag(void)
{
    uint32_t s1 = FL8(0), s2 = FL8(0), mf, dev;
    FL8(0) = 0xF0;
    flash_cmd(0x90);         /* autoselect */
    mf  = FL8(0x00);
    dev = FL8(0x02);
    FL8(0) = 0xF0;
    return s1 << 24 | s2 << 16 | mf << 8 | dev;
}

static NOINLINE void jtag_load(void)
{
    uint32_t *buf = (uint32_t *)SDRAM_BASE;
    uint32_t n, sum = 0, i;

    puts_imm("jtag: wait\r\n");
    LEDG = 0x80;
    HEX = 0x1000;
    while (jtag_word() != JTAG_MAGIC)
        ;
    n = jtag_word();
    if (n > FLASH_SIZE / 4)
        fail(0x10, n);
    for (i = 0; i < n; i++) {
        uint32_t w = jtag_word();
        buf[i] = w;
        sum += w;
        if ((i & 0x3ff) == 0)
            HEX = 0x1000 | (i >> 10);
    }
    if (jtag_word() != sum)
        fail(0x11, sum);
    if (JTAG_STATUS & 2)
        fail(0x12, n);
    puts_imm("jtag: erase\r\n");

    HEX = 0x2000;
    FL8(0) = 0xF0;           /* reset, in case the chip was left mid-command */
    flash_cmd(0x80);
    flash_cmd(0x10);
    if (flash_wait(0, 0xff))
        fail(0x13, flash_diag());

    puts_imm("jtag: write\r\n");
    {
        const uint8_t *src = (const uint8_t *)SDRAM_BASE;
        for (i = 0; i < n * 4; i++) {
            if ((i & 0xfff) == 0) {
                HEX = 0x3000 | (i >> 12);
                LEDR = i >> 12;
            }
            if (src[i] == 0xff)
                continue;
            flash_cmd(0xA0);
            FL8(i) = src[i];
            if (flash_wait(i, src[i])) {
                puts_imm("jtag: program failed at ");
                puthex(i);
                puts_imm("\r\n");
                fail(0x14, flash_diag());
            }
        }
        HEX = 0x4000;
        for (i = 0; i < n * 4; i++)
            if (FL8(i) != src[i])
                fail(0x15, i);
    }
    puts_imm("jtag: ok\r\n");
    HEX = 0x600D;
    LEDR = 0;
}

void __attribute__((noreturn)) boot_main(void)
{
    volatile flash_header_t *h = FLASH_HEADER;
    uint32_t magic, load, len, entry;

    LEDR = 0;
    LEDG = 1;
    HEX = 0xB001;
    puts_imm("\r\ndoomacracy boot rom\r\n");
    if (SWITCHES & SW_JTAG_LOAD)
        jtag_load();

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
