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
    puts_imm("boot: error ");
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

#define FL32(off) (*(volatile uint32_t *)(FLASH_BASE + (off)))
#define SECTOR    0x10000u          /* 64 KB main sectors */
#define SUBSECTOR 0x2000u           /* 8 KB boot sectors, if the part has them */

/* Receive a JTAG stream into buf, return its length in words. */
static NOINLINE uint32_t jtag_receive(uint32_t *buf, uint32_t max_words)
{
    uint32_t n, sum = 0, i;

    puts_imm("jtag: wait\r\n");
    LEDG = 0x80;
    HEX = 0x1000;
    while (jtag_word() != JTAG_MAGIC)
        ;
    n = jtag_word();
    if (n > max_words)
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
    /* read the buffer back from SDRAM (it is far bigger than the D-cache):
       a memory fault must stop here, not end up in the flash */
    {
        uint32_t back = 0;
        for (i = 0; i < n; i++)
            back += buf[i];
        if (back != sum)
            fail(0x17, back);
    }
    return n;
}

static NOINLINE void sector_erase(uint32_t off)
{
    flash_cmd(0x80);
    FL8(0xAAA) = 0xAA;
    FL8(0x555) = 0x55;
    FL8(off) = 0x30;
    if (flash_wait(off, 0xff))
        fail(0x13, flash_diag());
}

/* Write len bytes from src, touching only the 64 KB regions that differ.
   Within a region every 8 KB chunk that isn't blank gets a sector erase at
   its start: with a 64 KB sector the first erase blanks the rest, with
   8 KB boot sectors each one is erased in turn. */
static NOINLINE void flash_update(const uint8_t *src, uint32_t len)
{
    const uint32_t *s32 = (const uint32_t *)src;
    uint32_t r, a, end, changed = 0;

    FL8(0) = 0xF0;           /* reset, in case the chip was left mid-command */
    for (r = 0; r < len; r += SECTOR) {
        end = r + SECTOR < len ? r + SECTOR : len;
        for (a = r; a < end; a += 4)
            if (FL32(a) != s32[a >> 2])
                break;
        if (a >= end)
            continue;            /* region already holds the image */
        changed++;
        HEX = 0x2000 | (r >> 16);
        LEDR = r >> 16;
        for (a = r; a < r + SECTOR; a += 4) {
            if (FL32(a) != 0xffffffffu) {
                sector_erase(a & ~(SUBSECTOR - 1));
                a = (a & ~(SUBSECTOR - 1)) + SUBSECTOR - 4;
            }
        }
        HEX = 0x3000 | (r >> 16);
        for (a = r; a < end; a++) {
            if (src[a] == 0xff)
                continue;
            flash_cmd(0xA0);
            FL8(a) = src[a];
            if (flash_wait(a, src[a]))
                fail(0x14, flash_diag());
        }
        for (a = r; a < end; a += 4)
            if (FL32(a) != s32[a >> 2])
                fail(0x15, a);
    }
    puts_imm("jtag: ok, sectors rewritten ");
    puthex(changed);
    puts_imm("\r\n");
    HEX = 0x600D;
    LEDR = changed;
}

/* Copy kernel and device tree out of a Linux image (flash or a RAM buffer)
   and enter the kernel. */
static NOINLINE __attribute__((noreturn)) void boot_linux(const uint32_t *img)
{
    uint32_t klen = img[1], doff = img[2], dlen = img[3], i;
    uint32_t *dst = (uint32_t *)SDRAM_BASE, *dtb = (uint32_t *)LINUX_DTB_AT;

    if (klen > JTAG_RAM_BUF - SDRAM_BASE - FLASH_FW_OFFSET || dlen > 0x4000 ||
        doff + dlen > LINUX_DTB_AT - JTAG_RAM_BUF)
        fail(5, klen);
    puts_imm("boot: linux\r\n");
    HEX = 0xB104;
    for (i = 0; i < (klen + 3) >> 2; i++)
        dst[i] = img[(FLASH_FW_OFFSET >> 2) + i];
    for (i = 0; i < (dlen + 3) >> 2; i++)
        dtb[i] = img[(doff >> 2) + i];
    FB_BASE = LINUX_FB_OFFSET;
    VIDEO_MODE = 1;              /* RGB565 for Linux's simplefb console */
    HEX = 0xB105;
    {
        register uint32_t a0 __asm__("a0") = 0;
        register uint32_t a1 __asm__("a1") = LINUX_DTB_AT - SDRAM_BASE + LINUX_ENTRY;
        __asm__ volatile("jr %2" :: "r"(a0), "r"(a1), "r"(LINUX_ENTRY));
    }
    __builtin_unreachable();
}

void __attribute__((noreturn)) boot_main(void)
{
    volatile flash_header_t *h = FLASH_HEADER;
    uint32_t magic, load, len, entry;

    LEDR = 0;
    LEDG = 1;
    HEX = 0xB001;
    puts_imm("\r\ndoomacracy boot rom\r\n");
    if (SWITCHES & SW_JTAG_LOAD) {
        uint32_t *buf = (uint32_t *)JTAG_RAM_BUF;
        uint32_t n = jtag_receive(buf, FLASH_SIZE / 4);
        if (SWITCHES & SW_JTAG_RAM) {
            /* SW8 too: boot a Linux image straight from RAM, flash untouched */
            if (buf[0] != LINUX_MAGIC)
                fail(0x16, buf[0]);
            boot_linux(buf);
        }
        flash_update((const uint8_t *)buf, n * 4);
    }

    magic = h->magic;
    if (magic == LINUX_MAGIC)
        boot_linux((const uint32_t *)FLASH_BASE);
    if (magic != FLASH_MAGIC) {
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
        fail(2, len);
    }
    if ((entry & 3) || entry < load || entry >= load + len) {
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
