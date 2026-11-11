/*
 * doomacracy_emu: functional model of the doomacracy SoC (see spec.md).
 *
 * RV32IM interpreter plus the exact memory map:
 *   0x00000000  4 KB  boot ROM   (read only)
 *   0x10000000 512 KB SRAM
 *   0x20000000  8 MB  SDRAM
 *   0x30000000  4 MB  flash      (read only)
 *   0xF0000000        I/O        (word access only)
 *
 * Misaligned accesses, writes to ROM/flash, unmapped accesses, non word I/O
 * accesses and illegal instructions are fatal and report the pc.
 *
 * Time is derived from the retired instruction count: cycles = instret * cpi.
 * TIMER_US = cycles / 50, TIMER_CYCLES = cycles, FRAME_COUNT = cycles / 833333.
 *
 * Build: cc -O2 -o emu doomacracy_emu.c
 * Run "emu --help" for options.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>
#include <setjmp.h>
#include <poll.h>
#include <unistd.h>

#define ROM_SIZE   (4u * 1024)
#define SRAM_SIZE  (512u * 1024)
static uint32_t sdram_size_v = 8u * 1024 * 1024;  /* --sdram-mb */
#define SDRAM_SIZE sdram_size_v
#define FLASH_SIZE (4u * 1024 * 1024)

#define CLK_HZ          50000000ull
#define CYCLES_PER_VGA  833333ull
#define PS2_BYTE_CYCLES 50000ull /* about 1 ms per PS/2 byte */

#define FB_W 320
#define FB_H 200

static uint8_t *rom, *sram, *sdram, *flash;
static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static uint32_t x[32];
static uint32_t pc;

/* ---- machine mode (Linux support, spec.md "Linux platform") ----
 * Traps only happen once software installs a handler (mtvec != 0); until
 * then every fault is fatal, exactly as before, so firmware bugs stay loud. */
static uint32_t mstatus, mie_r, mip_r, mtvec, mscratch, mepc, mcause, mtval;
static int priv = 3;                      /* 3 machine, 0 user */
static uint64_t mtimecmp = ~0ull;
static uint64_t idle_cycles;              /* time skipped by WFI */
static uint32_t lr_addr = 1;              /* LR/SC reservation (1 = none) */
static jmp_buf trap_jb;
static uint32_t trap_cause, trap_tval;
static uint8_t uart_ier, uart_lcr, uart_mcr, uart_scr, uart_dll, uart_dlm;
static uint64_t instret;
static double cpi = 3.0;

/* stats */
enum { R_ROM, R_SRAM, R_SDRAM, R_FLASH, R_IO, R_N };
static const char *rname[R_N] = { "rom", "sram", "sdram", "flash", "io" };
static uint64_t nload[R_N], nstore[R_N];

/* io state */
static uint32_t fb_base, ledr, ledg, hex, switches, video_mode;
static uint64_t dump_vga, next_vga_dump;  /* --dump-vga: dump every N VGA frames */
static uint32_t palette[256]; /* 0x00RRGGBB as written (8 bits each) */
static uint64_t flips;

/* keyboard */
typedef struct { uint64_t when; int flip; uint8_t byte; } kev_t;
static kev_t *kq; static size_t kq_n, kq_cap, kq_head;
static uint8_t kfifo[16]; static int kf_head, kf_n;

/* JTAG loader feed: a stream file standing in for the USB-Blaster */
static uint8_t *jtag_buf; static size_t jtag_len, jtag_pos;

/* AMD-style flash command interpreter (byte mode, as on the DE1). Erase and
   program finish instantly, so status polling sees them done at once. */
static int fl_cycle;            /* position in the unlock sequence */
static int fl_mode;             /* 0 read, 1 program next write, 2 erase setup */
static uint64_t fl_programs, fl_erases;
static void flash_write(uint32_t off, uint8_t v)
{
    if (fl_mode == 1) {                                          /* program */
        flash[off] &= v;
        fl_programs++;
        fl_mode = 0; fl_cycle = 0;
        return;
    }
    if (v == 0xF0) { fl_cycle = 0; fl_mode = 0; return; }        /* reset */
    switch (fl_cycle) {
    case 0: if (off == 0xAAA && v == 0xAA) { fl_cycle = 1; return; } break;
    case 1: if (off == 0x555 && v == 0x55) { fl_cycle = 2; return; } break;
    case 2:
        if (off == 0xAAA && v == 0xA0) { fl_mode = 1; fl_cycle = 0; return; }
        if (off == 0xAAA && v == 0x80) { fl_mode = 2; fl_cycle = 0; return; }
        if (off == 0xAAA && v == 0x90) { fl_cycle = 0; return; }  /* autoselect: ignored */
        if (off == 0xAAA && v == 0x10 && fl_mode == 2) {          /* chip erase */
            memset(flash, 0xff, FLASH_SIZE);
            fl_erases++;
            fl_mode = 0; fl_cycle = 0;
            return;
        }
        break;
    }
    die("flash: unexpected write %02x to %06x (command cycle %d)", v, off, fl_cycle);
}
static uint64_t kbd_dropped;
static uint64_t last_arrival;

/* options */
static const char *boot_path = "build/boot.bin";
static const char *flash_path = "build/flash.bin";
static const char *jtag_path, *flash_out, *kernel_path, *dtb_path;
static const char *dump_dir;
static const char *dump_prefix = "frame";
static uint32_t min_sp = 0xffffffff;
static int dump_every = 1, dump_scale = 1, dump_full = 0;
static uint64_t max_flips, max_instr, dump_count;
static FILE *trace_f; static uint64_t trace_n;
static int quiet;

static void stats(void);

static void die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));
#include <stdarg.h>
static void die(const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "\nemu: FATAL at pc=%08x (instret %llu): ", pc, (unsigned long long)instret);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    stats();
    exit(2);
}

/* A fault: trap to mtvec if software has a handler, otherwise fatal. */
static void fault(uint32_t cause, uint32_t tval, const char *fmt, ...)
    __attribute__((noreturn, format(printf, 3, 4)));
static void fault(uint32_t cause, uint32_t tval, const char *fmt, ...)
{
    char msg[256];
    va_list ap;
    if (mtvec) {
        trap_cause = cause;
        trap_tval = tval;
        longjmp(trap_jb, 1);
    }
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    die("%s", msg);
}

/* ---------------------------------------------------------------- timing
 * Optional cycle model of the RTL (--timing): direct-mapped I and D caches
 * with 16-byte lines, write-through with a one-entry write buffer, and the
 * miss/burst costs of the VHDL controllers. Approximate, but it tracks the
 * things that dominate: hit rates and memory latency. */
static int timing = 0;
static int ic_bits = 8, dc_bits = 8;
static uint32_t *ic_tag, *dc_tag;
static uint64_t tcycles, ic_miss, dc_miss, dc_rd;
static uint64_t wb_free_at;          /* cycle the write buffer is empty */

static int fill_cost(uint32_t a)     /* cycles for a 16-byte line fill */
{
    switch (a >> 28) {
    case 0x0: return 6;
    case 0x1: return 12;             /* 8 halfwords + issue + bus */
    case 0x2: return 18;             /* act, 8 reads, CL, precharge */
    default:  return 30;
    }
}
static int write_cost(uint32_t a)
{
    return (a >> 28) == 0x1 ? 5 : 10;
}
static void timing_init(void)
{
    ic_tag = calloc(1u << ic_bits, 4);
    dc_tag = calloc(1u << dc_bits, 4);
    for (uint32_t i = 0; i < (1u << ic_bits); i++) ic_tag[i] = 1;   /* invalid */
    for (uint32_t i = 0; i < (1u << dc_bits); i++) dc_tag[i] = 1;
}
static inline void t_fetch(uint32_t a)
{
    uint32_t line = a >> 4, idx = line & ((1u << ic_bits) - 1);
    if (ic_tag[idx] != line << 1) {
        ic_miss++;
        if (tcycles < wb_free_at) tcycles = wb_free_at;
        tcycles += 2 + fill_cost(a);
        ic_tag[idx] = line << 1;
    }
}
static inline void t_load(uint32_t a)
{
    if ((a >> 28) != 1 && (a >> 28) != 2) {        /* uncached */
        if (tcycles < wb_free_at) tcycles = wb_free_at;
        tcycles += (a >> 28) == 3 ? 28 : 3;
        return;
    }
    uint32_t line = a >> 4, idx = line & ((1u << dc_bits) - 1);
    dc_rd++;
    if (dc_tag[idx] != line << 1) {
        dc_miss++;
        if (tcycles < wb_free_at) tcycles = wb_free_at;
        tcycles += 2 + fill_cost(a);
        dc_tag[idx] = line << 1;
    }
}
static inline void t_store(uint32_t a)
{
    if ((a >> 28) != 1 && (a >> 28) != 2) {
        if (tcycles < wb_free_at) tcycles = wb_free_at;
        tcycles += 3;
        return;
    }
    if (tcycles < wb_free_at) tcycles = wb_free_at;  /* buffer full: stall */
    wb_free_at = tcycles + 1 + write_cost(a);
}


static inline uint64_t cycles(void) { return idle_cycles + (timing ? tcycles : (uint64_t)((double)instret * cpi)); }
static inline uint64_t frame_count(void) { return cycles() / CYCLES_PER_VGA; }

/* ---------------------------------------------------------------- PS/2 */

typedef struct { const char *name; int ext; uint8_t code; } keyname_t;
static const keyname_t keynames[] = {
    {"a",0,0x1c},{"b",0,0x32},{"c",0,0x21},{"d",0,0x23},{"e",0,0x24},{"f",0,0x2b},
    {"g",0,0x34},{"h",0,0x33},{"i",0,0x43},{"j",0,0x3b},{"k",0,0x42},{"l",0,0x4b},
    {"m",0,0x3a},{"n",0,0x31},{"o",0,0x44},{"p",0,0x4d},{"q",0,0x15},{"r",0,0x2d},
    {"s",0,0x1b},{"t",0,0x2c},{"u",0,0x3c},{"v",0,0x2a},{"w",0,0x1d},{"x",0,0x22},
    {"y",0,0x35},{"z",0,0x1a},
    {"0",0,0x45},{"1",0,0x16},{"2",0,0x1e},{"3",0,0x26},{"4",0,0x25},{"5",0,0x2e},
    {"6",0,0x36},{"7",0,0x3d},{"8",0,0x3e},{"9",0,0x46},
    {"minus",0,0x4e},{"equals",0,0x55},{"comma",0,0x41},{"period",0,0x49},
    {"slash",0,0x4a},{"backspace",0,0x66},{"space",0,0x29},{"tab",0,0x0d},
    {"capslock",0,0x58},{"lshift",0,0x12},{"rshift",0,0x59},{"shift",0,0x12},
    {"lctrl",0,0x14},{"ctrl",0,0x14},{"lalt",0,0x11},{"alt",0,0x11},
    {"enter",0,0x5a},{"esc",0,0x76},{"escape",0,0x76},
    {"f1",0,0x05},{"f2",0,0x06},{"f3",0,0x04},{"f4",0,0x0c},{"f5",0,0x03},
    {"f6",0,0x0b},{"f7",0,0x83},{"f8",0,0x0a},{"f9",0,0x01},{"f10",0,0x09},
    {"f11",0,0x78},{"f12",0,0x07},
    {"rctrl",1,0x14},{"ralt",1,0x11},{"up",1,0x75},{"down",1,0x72},
    {"left",1,0x6b},{"right",1,0x74},{"home",1,0x6c},{"end",1,0x69},
    {"pgup",1,0x7d},{"pgdn",1,0x7a},{"insert",1,0x70},{"delete",1,0x71},
    {"kpenter",1,0x5a},
    {NULL,0,0}
};

static void kq_push(uint64_t when, int flip, uint8_t b)
{
    if (kq_n == kq_cap) {
        kq_cap = kq_cap ? kq_cap * 2 : 256;
        kq = realloc(kq, kq_cap * sizeof *kq);
    }
    kq[kq_n].when = when;
    kq[kq_n].flip = flip;
    kq[kq_n].byte = b;
    kq_n++;
}

/* Bytes are queued with a "not before" time; actual arrival is spaced by
 * PS2_BYTE_CYCLES and assigned in order when they become due. */
static int parse_key_token(const char *tok, uint8_t *out)
{
    int n = 0;
    char mode = 0;
    const keyname_t *k;
    size_t len = strlen(tok);
    if (len == 2 && isxdigit((unsigned char)tok[0]) && isxdigit((unsigned char)tok[1])) {
        out[0] = (uint8_t)strtoul(tok, NULL, 16);
        return 1;
    }
    if (tok[0] == '+' || tok[0] == '-' || tok[0] == '*') { mode = tok[0]; tok++; }
    else return -1;
    for (k = keynames; k->name; k++)
        if (!strcmp(k->name, tok)) break;
    if (!k->name) return -1;
    if (mode == '+' || mode == '*') {
        if (k->ext) out[n++] = 0xe0;
        out[n++] = k->code;
    }
    if (mode == '-' || mode == '*') {
        if (k->ext) out[n++] = 0xe0;
        out[n++] = 0xf0;
        out[n++] = k->code;
    }
    return n;
}

static void load_keys(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[1024];
    int lineno = 0;
    if (!f) { fprintf(stderr, "emu: cannot open key script %s\n", path); exit(1); }
    while (fgets(line, sizeof line, f)) {
        char *p = line, *tok;
        int flip = -1;
        uint64_t when = 0;
        lineno++;
        if ((tok = strchr(p, '#'))) *tok = 0;
        tok = strtok(p, " \t\r\n");
        if (!tok) continue;
        if (tok[0] == 'f' || tok[0] == 'F') flip = atoi(tok + 1);
        else when = strtoull(tok, NULL, 0) * CYCLES_PER_VGA;
        while ((tok = strtok(NULL, " \t\r\n"))) {
            uint8_t b[8];
            int n = parse_key_token(tok, b), i;
            if (n < 0) { fprintf(stderr, "emu: %s:%d: bad key token '%s'\n", path, lineno, tok); exit(1); }
            for (i = 0; i < n; i++) kq_push(when, flip, b[i]);
        }
    }
    fclose(f);
}

static void kbd_flip_event(void)
{
    size_t i;
    for (i = kq_head; i < kq_n; i++)
        if (kq[i].flip >= 0 && (uint64_t)kq[i].flip <= flips) {
            kq[i].when = cycles();
            kq[i].flip = -1;
        }
}

static void kbd_update(void)
{
    uint64_t now = cycles();
    while (kq_head < kq_n) {
        kev_t *e = &kq[kq_head];
        uint64_t t;
        if (e->flip >= 0) break; /* waiting on a page flip */
        t = e->when;
        if (t < last_arrival + PS2_BYTE_CYCLES && last_arrival) t = last_arrival + PS2_BYTE_CYCLES;
        if (t > now) break;
        last_arrival = t;
        if (kf_n < 16) {
            kfifo[(kf_head + kf_n) & 15] = e->byte;
            kf_n++;
        } else {
            kbd_dropped++;
        }
        kq_head++;
    }
}

/* ---------------------------------------------------------------- video */

static void dump_frame(void)
{
    char path[1024];
    FILE *f;
    int xx, yy, sx, sy, s = dump_scale;
    static uint8_t row[FB_W * 2 * 3];
    uint32_t bpp = (video_mode & 1) ? 2 : 1;
    if (fb_base + FB_W * FB_H * bpp > SRAM_SIZE) {
        fprintf(stderr, "emu: FB_BASE %08x out of SRAM, frame not dumped\n", fb_base);
        return;
    }
    snprintf(path, sizeof path, "%s/%s%05llu.ppm", dump_dir, dump_prefix, (unsigned long long)dump_count++);
    f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "emu: cannot write %s\n", path); return; }
    fprintf(f, "P6\n%d %d\n255\n", FB_W * s, FB_H * s);
    for (yy = 0; yy < FB_H; yy++) {
        const uint8_t *src = sram + fb_base + yy * FB_W * bpp;
        for (xx = 0; xx < FB_W; xx++) {
            uint32_t c;
            if (bpp == 2) {   /* RGB565, expanded to 8 bits per channel */
                uint32_t p = src[2 * xx] | src[2 * xx + 1] << 8;
                c = ((p >> 11) & 31) * 255 / 31 << 16 | ((p >> 5) & 63) * 255 / 63 << 8 | (p & 31) * 255 / 31;
            } else
                c = palette[src[xx]];
            uint8_t r = c >> 16, g = c >> 8, b = c;
            if (!dump_full) { r = (r >> 4) * 17; g = (g >> 4) * 17; b = (b >> 4) * 17; }
            for (sx = 0; sx < s; sx++) {
                row[(xx * s + sx) * 3 + 0] = r;
                row[(xx * s + sx) * 3 + 1] = g;
                row[(xx * s + sx) * 3 + 2] = b;
            }
        }
        for (sy = 0; sy < s; sy++) fwrite(row, 3, FB_W * s, f);
    }
    fclose(f);
}

static int stop_requested;
static int log_flips;
static uint64_t last_flip_instret, flip_dt_min = UINT64_MAX, flip_dt_max, flip_dt_sum, flip_dt_n;

static void on_flip(void)
{
    flips++;
    if (flips > 1) {
        uint64_t dt = instret - last_flip_instret;
        if (dt < flip_dt_min) flip_dt_min = dt;
        if (dt > flip_dt_max) flip_dt_max = dt;
        flip_dt_sum += dt;
        flip_dt_n++;
    }
    if (log_flips)
        fprintf(stderr, "emu: flip %llu at instret %llu (vga frame %llu, %llu instrs since last flip)\n",
                (unsigned long long)flips, (unsigned long long)instret,
                (unsigned long long)frame_count(),
                (unsigned long long)(flips > 1 ? instret - last_flip_instret : instret));
    last_flip_instret = instret;
    if (dump_dir && (flips - 1) % dump_every == 0) dump_frame();
    kbd_flip_event();
    if (max_flips && flips >= max_flips) stop_requested = 1;
}

/* ---------------------------------------------------------------- I/O */

/* console UART: a 16550 with 4-byte register spacing (Linux 8250,
   reg-shift 2), polled, backed by stdin/stdout */
static int console_rx = -1;
static int console_poll(void)
{
    if (console_rx < 0) {
        struct pollfd p = { 0, POLLIN, 0 };
        unsigned char c;
        if (poll(&p, 1, 0) > 0 && (p.revents & POLLIN) && read(0, &c, 1) == 1)
            console_rx = c == '\n' ? '\r' : c;
    }
    return console_rx >= 0;
}
static uint32_t uart16550_read(uint32_t r)
{
    if (uart_lcr & 0x80) {
        if (r == 0) return uart_dll;
        if (r == 1) return uart_dlm;
    }
    switch (r) {
    case 0: { int c = console_poll() ? console_rx : 0; console_rx = -1; return c; }
    case 1: return uart_ier;
    case 2:                                    /* IIR: FIFOs on, highest pending source */
        if ((uart_ier & 1) && console_poll()) return 0xc4;
        if (uart_ier & 2) return 0xc2;         /* transmitter always empty */
        return 0xc1;
    case 3: return uart_lcr;
    case 4: return uart_mcr;
    case 5: return 0x60 | console_poll();      /* THR empty, TEMT, DR */
    case 6: return 0xb0;                       /* DCD, DSR, CTS */
    default: return uart_scr;
    }
}
static void uart16550_write(uint32_t r, uint32_t v)
{
    v &= 0xff;
    if (uart_lcr & 0x80 && r <= 1) { if (r) uart_dlm = v; else uart_dll = v; return; }
    switch (r) {
    case 0: putchar(v); if (v == '\n') fflush(stdout); return;
    case 1: uart_ier = v & 0x0f; return;
    case 3: uart_lcr = v; return;
    case 4: uart_mcr = v; return;
    case 7: uart_scr = v; return;
    }
}
static int poweroff_requested;
static int ps2_ie;   /* altera_ps2 control RE */
/* one-source PLIC at 0xF400_0000 (source 1 = PS/2), as in rtl/io.vhd */
static uint32_t plic_prio, plic_thr, plic_en, plic_claimed;
static int plic_irq(void)
{
    int pend = ps2_ie && kf_n && !plic_claimed;
    return pend && plic_en && plic_prio > plic_thr;
}
static uint32_t io_read_regs(uint32_t off);
static uint32_t io_read(uint32_t off)
{
    if (off >= 0x1000 && off < 0x1020) return uart16550_read((off - 0x1000) >> 2);
    if (off == 0x2000) return 0;
    if (off == 0x3000) {                                 /* altera_ps2 data */
        kbd_update();
        if (kf_n) {
            uint8_t b = kfifo[kf_head];
            uint32_t n = kf_n;
            kf_head = (kf_head + 1) & 15;
            kf_n--;
            return n << 16 | 0x8000 | b;
        }
        return 0;
    }
    if (off == 0x3004) { kbd_update(); return (kf_n ? 0x100 : 0) | ps2_ie; }
    if (off >= 0x4000000 && off < 0x4400000) {
        kbd_update();
        switch (off - 0x4000000) {
        case 0x000004: return plic_prio;
        case 0x001000: return (ps2_ie && kf_n && !plic_claimed) << 1;
        case 0x002000: return plic_en << 1;
        case 0x200000: return plic_thr;
        case 0x200004: if (plic_irq()) { plic_claimed = 1; return 1; } return 0;
        }
        return 0;
    }
    if (off >= 0x1000000 && off < 0x1010000) {          /* CLINT */
        uint64_t mtime = cycles() / (CLK_HZ / 1000000);
        switch (off - 0x1000000) {
        case 0x0000: return (mip_r >> 3) & 1;
        case 0x4000: return (uint32_t)mtimecmp;
        case 0x4004: return (uint32_t)(mtimecmp >> 32);
        case 0xbff8: return (uint32_t)mtime;
        case 0xbffc: return (uint32_t)(mtime >> 32);
        }
        return 0;
    }
    if (off > 0xff) fault(5, 0xF0000000u | off, "load from unmapped I/O address %08x", 0xF0000000u | off);
    return io_read_regs(off);
}
static uint32_t io_read_regs(uint32_t off)
{
    switch (off) {
    case 0x00: return 0; /* no UART receive in the emulator */
    case 0x04: return 1;
    case 0x08: return (uint32_t)(cycles() / (CLK_HZ / 1000000));
    case 0x0C: return (uint32_t)cycles();
    case 0x10:
        kbd_update();
        if (kf_n) {
            uint8_t b = kfifo[kf_head];
            kf_head = (kf_head + 1) & 15;
            kf_n--;
            return 0x100 | b;
        }
        return 0;
    case 0x14: return (switches & 0x3ff) | (0xfu << 16);
    case 0x30: return fb_base;
    case 0x3C: return video_mode;
    case 0x34: return (uint32_t)frame_count();
    case 0x40: {
        uint32_t w = 0;
        if (jtag_pos + 4 <= jtag_len) { memcpy(&w, jtag_buf + jtag_pos, 4); jtag_pos += 4; }
        return w;
    }
    case 0x44: return jtag_pos + 4 <= jtag_len;
    }
    die("read from undefined/write-only I/O register offset 0x%02x", off);
}

static void io_write_regs(uint32_t off, uint32_t v);
static void io_write(uint32_t off, uint32_t v)
{
    if (off >= 0x1000 && off < 0x1020) { uart16550_write((off - 0x1000) >> 2, v); return; }
    if (off == 0x3000) return;                           /* no PS/2 transmitter */
    if (off == 0x3004) { ps2_ie = v & 1; return; }
    if (off >= 0x4000000 && off < 0x4400000) {
        switch (off - 0x4000000) {
        case 0x000004: plic_prio = v & 7; return;
        case 0x002000: plic_en = (v >> 1) & 1; return;
        case 0x200000: plic_thr = v & 7; return;
        case 0x200004: if ((v & 31) == 1) plic_claimed = 0; return;
        }
        return;
    }
    if (off == 0x2000) {                                 /* syscon */
        if (v == 0x5555 || v == 0x7777) { poweroff_requested = v; stop_requested = 1; }
        return;
    }
    if (off >= 0x1000000 && off < 0x1010000) {
        switch (off - 0x1000000) {
        case 0x0000: mip_r = (mip_r & ~8u) | ((v & 1) << 3); return;
        case 0x4000: mtimecmp = (mtimecmp & ~0xffffffffull) | v; return;
        case 0x4004: mtimecmp = (mtimecmp & 0xffffffffull) | (uint64_t)v << 32; return;
        }
        return;
    }
    if (off > 0xff) fault(7, 0xF0000000u | off, "store to unmapped I/O address %08x", 0xF0000000u | off);
    io_write_regs(off, v);
}
static void io_write_regs(uint32_t off, uint32_t v)
{
    switch (off) {
    case 0x00:
        if ((v & 0xff) != '\r') putchar(v & 0xff); /* firmware sends CRLF */
        if ((v & 0xff) == '\n') fflush(stdout);
        return;
    case 0x18: ledr = v & 0x3ff; return;
    case 0x1C: ledg = v & 0xff; return;
    case 0x20: hex = v & 0xffff; return;
    case 0x30:
        fb_base = v & 0x7ffff;
        on_flip();
        return;
    case 0x3C: video_mode = v & 1; return;
    case 0x38:
        palette[v >> 24] = v & 0xffffff;
        return;
    }
    die("write 0x%08x to undefined/read-only I/O register offset 0x%02x", v, off);
}

/* ---------------------------------------------------------------- memory */

static inline uint8_t *mem_ptr(uint32_t a, int size, int write, int *region)
{
    uint32_t off = a & 0x0fffffff;
    switch (a >> 28) {
    case 0x0:
        *region = R_ROM;
        if (a + size > ROM_SIZE) break;
        if (write) fault(7, a, "store to boot ROM address %08x", a);
        return rom + a;
    case 0x1:
        *region = R_SRAM;
        if (off + size > SRAM_SIZE) break;
        return sram + off;
    case 0x2:
    case 0x8:   /* SDRAM alias for kernels linked at 0x80000000 */
        *region = R_SDRAM;
        if (off + size > SDRAM_SIZE) break;
        return sdram + off;
    case 0x3:
        *region = R_FLASH;
        if (off + size > FLASH_SIZE) break;
        if (write) {
            if (size != 1) fault(7, a, "%d-byte store to flash address %08x (bytes only)", size, a);
            return NULL;
        }
        return flash + off;
    case 0xF:
        *region = R_IO;
        return NULL;
    }
    fault(write ? 7 : 5, a, "%s of %d bytes to unmapped address %08x", write ? "store" : "load", size, a);
}

static inline uint32_t load(uint32_t a, int size)
{
    int region;
    uint8_t *p;
    if (a & (size - 1)) fault(4, a, "misaligned %d-byte load from %08x", size, a);
    p = mem_ptr(a, size, 0, &region);
    nload[region]++;
    if (timing) t_load(a);
    if (!p) {
        if (size != 4) fault(5, a, "%d-byte load from I/O address %08x (word only)", size, a);
        return io_read(a & 0x0fffffff);
    }
    if (size == 4) { uint32_t v; memcpy(&v, p, 4); return v; }
    if (size == 2) { uint16_t v; memcpy(&v, p, 2); return v; }
    return *p;
}

static inline void store(uint32_t a, int size, uint32_t v)
{
    int region;
    uint8_t *p;
    if (a & (size - 1)) fault(6, a, "misaligned %d-byte store to %08x", size, a);
    p = mem_ptr(a, size, 1, &region);
    nstore[region]++;
    if (timing) t_store(a);
    if (!p && region == R_FLASH) {
        flash_write(a & 0x0fffffff, v & 0xff);
        return;
    }
    if (!p) {
        if (size != 4) fault(7, a, "%d-byte store to I/O address %08x (word only)", size, a);
        io_write(a & 0x0fffffff, v);
        return;
    }
    if (size == 4) memcpy(p, &v, 4);
    else if (size == 2) { uint16_t h = v; memcpy(p, &h, 2); }
    else *p = v;
}

static inline uint32_t fetch(uint32_t a)
{
    uint32_t v;
    if (a & 3) fault(0, a, "misaligned instruction fetch from %08x", a);
    switch (a >> 28) {
    case 0x0: if (a < ROM_SIZE) { memcpy(&v, rom + a, 4); return v; } break;
    case 0x1: if ((a & 0x0fffffff) < SRAM_SIZE) { memcpy(&v, sram + (a & 0x0fffffff), 4); return v; } break;
    case 0x2: case 0x8: if ((a & 0x0fffffff) < SDRAM_SIZE) { memcpy(&v, sdram + (a & 0x0fffffff), 4); return v; } break;
    }
    fault(1, a, "instruction fetch from non-executable/unmapped address %08x", a);
}


/* ---------------------------------------------------------------- CPU */

static void take_trap(uint32_t cause, uint32_t tval)
{
    mepc = pc;
    mcause = cause;
    mtval = tval;
    mstatus = (mstatus & ~0x1888u) | ((mstatus & 8) << 4) | ((uint32_t)priv << 11);
    priv = 3;
    lr_addr = 1;
    pc = (mtvec & 1) && (cause >> 31) ? (mtvec & ~3u) + 4 * (cause & 0x1f) : mtvec & ~3u;
}

static uint64_t mtime_now(void) { return cycles() / (CLK_HZ / 1000000); }

static uint32_t csr_read(uint32_t n, uint32_t ins)
{
    switch (n) {
    case 0x300: return mstatus;
    case 0x301: return 0x40101101;               /* RV32 I M A U */
    case 0x304: return mie_r;
    case 0x305: return mtvec;
    case 0x340: return mscratch;
    case 0x341: return mepc;
    case 0x342: return mcause;
    case 0x343: return mtval;
    case 0x344: return mip_r;
    case 0xf11: case 0xf12: case 0xf13: case 0xf14: return 0;
    case 0xc00: case 0xb00: return (uint32_t)cycles();
    case 0xc80: case 0xb80: return (uint32_t)(cycles() >> 32);
    case 0xc01: return (uint32_t)mtime_now();
    case 0xc81: return (uint32_t)(mtime_now() >> 32);
    case 0xc02: case 0xb02: return (uint32_t)instret;
    case 0xc82: case 0xb82: return (uint32_t)(instret >> 32);
    }
    {
        static uint8_t warned[4096];
        if (!quiet && !warned[n & 0xfff]++)
            fprintf(stderr, "emu: unimplemented CSR %03x (reads 0) at pc=%08x, insn %08x\n", n, pc, ins);
    }
    return 0;
}

static void csr_write(uint32_t n, uint32_t v)
{
    switch (n) {
    case 0x300: mstatus = v & 0x1888u; return;   /* MIE, MPIE, MPP */
    case 0x304: mie_r = v & 0x888u; return;
    case 0x305: mtvec = v; return;
    case 0x340: mscratch = v; return;
    case 0x341: mepc = v & ~3u; return;
    case 0x342: mcause = v; return;
    case 0x343: mtval = v; return;
    case 0x344: return;                          /* MTIP/MSIP come from the CLINT */
    }
}

static int run_inner(void);
static int run(void)
{
    if (setjmp(trap_jb))
        take_trap(trap_cause, trap_tval);
    return run_inner();
}

static int run_inner(void)
{
    for (;;) {
        if (mtimecmp != ~0ull && (instret & 63) == 0) {
            if (mtime_now() >= mtimecmp) mip_r |= 0x80; else mip_r &= ~0x80u;
        }
        if (dump_vga && dump_dir && (instret & 4095) == 0 && frame_count() >= next_vga_dump) {
            next_vga_dump = frame_count() + dump_vga;
            dump_frame();
        }
        if ((instret & 1023) == 0 || !plic_irq()) {
            if (ps2_ie && (instret & 1023) == 0) kbd_update();
            if (plic_irq()) mip_r |= 0x800; else mip_r &= ~0x800u;
        }
        if ((mip_r & mie_r & 0x888) && ((mstatus & 8) || priv < 3)) {
            uint32_t p = mip_r & mie_r;
            take_trap(p & 0x800 ? 0x8000000bu : p & 0x8 ? 0x80000003u : 0x80000007u, 0);
            continue;
        }
        uint32_t ins = fetch(pc);
        uint32_t op = ins & 0x7f;
        if (timing) {
            /* base cost: 2 per instruction (exec + fetch); loads/stores 3;
               mul 4 extra; div 33 extra; taken jumps the same as others */
            t_fetch(pc);
            tcycles += 2;
            if (op == 0x03 || op == 0x23) tcycles += 1;
            else if (op == 0x33 && (ins >> 25) == 1) tcycles += (ins & 0x4000) ? 34 : 3;
        }
        uint32_t rd = (ins >> 7) & 31, rs1 = (ins >> 15) & 31, rs2 = (ins >> 20) & 31;
        uint32_t f3 = (ins >> 12) & 7, f7 = ins >> 25;
        uint32_t a = x[rs1], b = x[rs2];
        uint32_t npc = pc + 4, val = 0;
        int wr = 0;
        int32_t imm_i = (int32_t)ins >> 20;

        switch (op) {
        case 0x37: val = ins & 0xfffff000; wr = 1; break; /* LUI */
        case 0x17: val = pc + (ins & 0xfffff000); wr = 1; break; /* AUIPC */
        case 0x6f: { /* JAL */
            int32_t imm = ((int32_t)(ins & 0x80000000) >> 11) | (ins & 0xff000) |
                          ((ins >> 9) & 0x800) | ((ins >> 20) & 0x7fe);
            if (imm == 0) { /* jump to self: program halted */
                instret++;
                if (!quiet) fprintf(stderr, "emu: halted (jump to self) at pc=%08x\n", pc);
                return 0;
            }
            val = npc; wr = 1; npc = pc + imm;
            break;
        }
        case 0x67: /* JALR */
            if (f3) goto illegal;
            val = npc; wr = 1; npc = (a + imm_i) & ~1u;
            break;
        case 0x63: { /* branches */
            int32_t imm = ((int32_t)(ins & 0x80000000) >> 19) | ((ins << 4) & 0x800) |
                          ((ins >> 20) & 0x7e0) | ((ins >> 7) & 0x1e);
            int t;
            switch (f3) {
            case 0: t = a == b; break;
            case 1: t = a != b; break;
            case 4: t = (int32_t)a < (int32_t)b; break;
            case 5: t = (int32_t)a >= (int32_t)b; break;
            case 6: t = a < b; break;
            case 7: t = a >= b; break;
            default: goto illegal;
            }
            if (t) npc = pc + imm;
            break;
        }
        case 0x03: { /* loads */
            uint32_t ea = a + imm_i;
            switch (f3) {
            case 0: val = (int32_t)(int8_t)load(ea, 1); break;
            case 1: val = (int32_t)(int16_t)load(ea, 2); break;
            case 2: val = load(ea, 4); break;
            case 4: val = load(ea, 1); break;
            case 5: val = load(ea, 2); break;
            default: goto illegal;
            }
            wr = 1;
            break;
        }
        case 0x23: { /* stores */
            uint32_t ea = a + (((int32_t)ins >> 20 & ~31) | rd);
            switch (f3) {
            case 0: store(ea, 1, b); break;
            case 1: store(ea, 2, b); break;
            case 2: store(ea, 4, b); break;
            default: goto illegal;
            }
            break;
        }
        case 0x13: /* OP-IMM */
            wr = 1;
            switch (f3) {
            case 0: val = a + imm_i; break;
            case 2: val = (int32_t)a < imm_i; break;
            case 3: val = a < (uint32_t)imm_i; break;
            case 4: val = a ^ imm_i; break;
            case 6: val = a | imm_i; break;
            case 7: val = a & imm_i; break;
            case 1: if (f7) goto illegal; val = a << rs2; break;
            case 5:
                if (f7 == 0) val = a >> rs2;
                else if (f7 == 0x20) val = (uint32_t)((int32_t)a >> rs2);
                else goto illegal;
                break;
            }
            break;
        case 0x33: /* OP */
            wr = 1;
            if (f7 == 1) {
                switch (f3) {
                case 0: val = a * b; break;
                case 1: val = (uint32_t)(((int64_t)(int32_t)a * (int64_t)(int32_t)b) >> 32); break;
                case 2: val = (uint32_t)(((int64_t)(int32_t)a * (int64_t)(uint64_t)b) >> 32); break;
                case 3: val = (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32); break;
                case 4:
                    if (b == 0) val = 0xffffffff;
                    else if (a == 0x80000000 && b == 0xffffffff) val = a;
                    else val = (uint32_t)((int32_t)a / (int32_t)b);
                    break;
                case 5: val = b ? a / b : 0xffffffff; break;
                case 6:
                    if (b == 0) val = a;
                    else if (a == 0x80000000 && b == 0xffffffff) val = 0;
                    else val = (uint32_t)((int32_t)a % (int32_t)b);
                    break;
                case 7: val = b ? a % b : a; break;
                }
            } else if (f7 == 0) {
                switch (f3) {
                case 0: val = a + b; break;
                case 1: val = a << (b & 31); break;
                case 2: val = (int32_t)a < (int32_t)b; break;
                case 3: val = a < b; break;
                case 4: val = a ^ b; break;
                case 5: val = a >> (b & 31); break;
                case 6: val = a | b; break;
                case 7: val = a & b; break;
                }
            } else if (f7 == 0x20) {
                if (f3 == 0) val = a - b;
                else if (f3 == 5) val = (uint32_t)((int32_t)a >> (b & 31));
                else goto illegal;
            } else goto illegal;
            break;
        case 0x0f: /* FENCE / FENCE.I: no-op */
            break;
        case 0x2f: { /* A extension */
            uint32_t f5 = ins >> 27, ea = a;
            if (f3 != 2) goto illegal;
            if (ea & 3) fault(6, ea, "misaligned AMO at %08x", ea);
            if (f5 == 2) { val = load(ea, 4); lr_addr = ea; wr = 1; break; }       /* LR.W */
            if (f5 == 3) {                                                          /* SC.W */
                if (lr_addr == ea) { store(ea, 4, b); val = 0; } else val = 1;
                lr_addr = 1; wr = 1; break;
            }
            val = load(ea, 4);
            {
                uint32_t nv;
                switch (f5) {
                case 0x01: nv = b; break;
                case 0x00: nv = val + b; break;
                case 0x04: nv = val ^ b; break;
                case 0x0c: nv = val & b; break;
                case 0x08: nv = val | b; break;
                case 0x10: nv = (int32_t)val < (int32_t)b ? val : b; break;
                case 0x14: nv = (int32_t)val > (int32_t)b ? val : b; break;
                case 0x18: nv = val < b ? val : b; break;
                case 0x1c: nv = val > b ? val : b; break;
                default: goto illegal;
                }
                store(ea, 4, nv);
            }
            wr = 1;
            break;
        }
        case 0x73:
            if (f3 == 0) {
                if (ins == 0x00100073) { /* EBREAK */
                    if (mtvec) fault(3, pc, "ebreak");
                    instret++;
                    fprintf(stderr, "emu: ebreak at pc=%08x\n", pc);
                    return 1;
                }
                if (ins == 0x00000073) { /* ECALL */
                    if (mtvec) fault(priv == 3 ? 11 : 8, 0, "ecall");
                    instret++;
                    fprintf(stderr, "emu: ecall at pc=%08x (a7=%u a0=%u)\n", pc, x[17], x[10]);
                    return 1;
                }
                if (ins == 0x30200073) { /* MRET */
                    priv = (mstatus >> 11) & 3;
                    if (priv != 3) priv = 0;
                    mstatus = (mstatus & ~0x1888u) | ((mstatus >> 4) & 8) | 0x80;
                    npc = mepc;
                    break;
                }
                if (ins == 0x10500073) { /* WFI: skip ahead to the timer */
                    if (!(mip_r & mie_r & 0x88) && (mie_r & 0x80) && mtimecmp != ~0ull) {
                        uint64_t now = mtime_now();
                        if (mtimecmp > now) idle_cycles += (mtimecmp - now) * (CLK_HZ / 1000000);
                    }
                    break;
                }
                goto illegal;
            }
            if (f3 == 4) goto illegal;
            {
                uint32_t csr = ins >> 20, src = (f3 & 4) ? rs1 : a, old = csr_read(csr, ins), nv;
                switch (f3 & 3) {
                case 1: nv = src; break;
                case 2: nv = old | src; break;
                default: nv = old & ~src; break;
                }
                if ((f3 & 3) == 1 || rs1 != 0) csr_write(csr, nv);
                val = old;
                wr = 1;
            }
            break;
        default:
        illegal:
            fault(2, ins, "illegal or unsupported instruction %08x", ins);
        }

        if (wr && rd) {
            x[rd] = val;
            if (rd == 2 && val < min_sp && (val >> 28) == 1) min_sp = val;
        }
        if (trace_f) {
            if (trace_n) {
                fprintf(trace_f, "%08x %08x %02x %08x\n", pc, ins,
                        (wr && rd) ? rd : 0, (wr && rd) ? val : 0);
                if (--trace_n == 0) { fclose(trace_f); trace_f = NULL; }
            }
        }
        pc = npc;
        instret++;
        if (stop_requested) return 0;
        if (max_instr && instret >= max_instr) {
            if (!quiet) fprintf(stderr, "emu: instruction limit reached\n");
            return 0;
        }
    }
}

/* ---------------------------------------------------------------- main */

static void stats(void)
{
    int i;
    double secs = (double)cycles() / CLK_HZ;
    fflush(stdout);
    fprintf(stderr, "\n--- emu stats ---\n");
    fprintf(stderr, "instructions retired: %llu\n", (unsigned long long)instret);
    if (kernel_path || mtvec)
        fprintf(stderr, "pc %08x priv %d mstatus %08x mcause %08x mepc %08x mtval %08x mie %03x mip %03x\n",
                pc, priv, mstatus, mcause, mepc, mtval, mie_r, mip_r);
    fprintf(stderr, "cycles (cpi %.2f):    %llu (%.3f s at 50 MHz)\n", cpi,
            (unsigned long long)cycles(), secs);
    fprintf(stderr, "vga frames:           %llu\n", (unsigned long long)frame_count());
    if (timing)
        fprintf(stderr, "timing: CPI %.2f, icache %u B miss %.3f%%, dcache %u B read miss %.3f%%\n",
                (double)tcycles / instret, 16u << ic_bits, 100.0 * ic_miss / instret,
                16u << dc_bits, dc_rd ? 100.0 * dc_miss / dc_rd : 0.0);
    fprintf(stderr, "region   loads        stores\n");
    for (i = 0; i < R_N; i++)
        fprintf(stderr, "%-6s %12llu %12llu\n", rname[i],
                (unsigned long long)nload[i], (unsigned long long)nstore[i]);
    fprintf(stderr, "page flips:           %llu\n", (unsigned long long)flips);
    if (secs > 0)
        fprintf(stderr, "estimated fps:        %.2f (flips / emulated time)\n", flips / secs);
    if (flip_dt_n)
        fprintf(stderr, "instructions between flips: min %llu avg %llu max %llu\n",
                (unsigned long long)flip_dt_min, (unsigned long long)(flip_dt_sum / flip_dt_n),
                (unsigned long long)flip_dt_max);
    if (min_sp != 0xffffffff)
        fprintf(stderr, "lowest sp in SRAM:    %08x\n", min_sp);
    if (kbd_dropped)
        fprintf(stderr, "kbd bytes dropped (FIFO full): %llu\n", (unsigned long long)kbd_dropped);
    fprintf(stderr, "LEDR=%03x LEDG=%02x HEX=%04x FB_BASE=%05x\n", ledr, ledg, hex, fb_base);
    if (dump_dir) fprintf(stderr, "frames dumped:        %llu to %s\n", (unsigned long long)dump_count, dump_dir);
}

static void load_file(const char *path, uint8_t *dst, size_t max, const char *what)
{
    FILE *f = fopen(path, "rb");
    size_t n;
    if (!f) { fprintf(stderr, "emu: cannot open %s %s: %s\n", what, path, strerror(errno)); exit(1); }
    n = fread(dst, 1, max, f);
    if (fgetc(f) != EOF) { fprintf(stderr, "emu: %s %s larger than %zu bytes\n", what, path, max); exit(1); }
    fclose(f);
    (void)n;
}

static void usage(void)
{
    fprintf(stderr,
"usage: emu [options]\n"
"  --boot FILE        boot ROM image (default build/boot.bin, <= 4 KB)\n"
"  --flash FILE       flash image (default build/flash.bin, <= 4 MB)\n"
"  --cpi N            cycles per instruction for timers (default 3.0)\n"
"  --timing           cycle model of the RTL caches and memories instead of --cpi\n"
"  --icache-bits N    log2 of I-cache lines for --timing (default 8 = 4 KB; the RTL uses 9)\n"
"  --dcache-bits N    log2 of D-cache lines for --timing (default 8 = 4 KB; the RTL uses 9)\n"
"  --keys FILE        keyboard script: '<vga_frame> tokens...' or 'f<flip> tokens...'\n"
"                     tokens: 2-digit hex raw PS/2 bytes, or +name (make),\n"
"                     -name (break), *name (make then break), e.g. *enter +up -up\n"
"  --dump DIR         write a PPM of the displayed frame on page flips\n"
"  --dump-every N     only dump every Nth flip (default 1)\n"
"  --dump-prefix S    frame file name prefix (default 'frame': DIR/frame00000.ppm)\n"
"  --scale N          1 = 320x200, 2 = 640x400 (default 1)\n"
"  --full-color       use 8-bit palette values (default: 4 bits like hardware)\n"
"  --max-flips N      stop after N page flips\n"
"  --max-instr N      stop after N instructions\n"
"  --trace FILE       write retirement trace of the first --trace-count instrs\n"
"  --trace-count K    default 1000000\n"
"  --switches N       value of SW[9:0] (0x200 = SW9, JTAG flash loader)\n"
"  --jtag FILE        JTAG loader stream (tools/jtag_stream.py) for SW9 mode\n"
"  --flash none       start with an erased flash\n"
"  --dump-vga N       with --dump: also dump the screen every N VGA frames (no page flips needed)\n"
"  --kernel FILE      boot a Linux Image at 0x80000000 (SDRAM alias) instead of the boot ROM\n"
"  --dtb FILE         device tree for --kernel, placed in the top 16 KB of SDRAM\n"
"  --sdram-mb N       SDRAM size (default 8, the DE1's; larger is emulator only)\n"
"  --flash-out FILE   write the flash contents here on exit\n"
"  --log-flips        print instret and VGA frame number on every page flip\n"
"  --quiet            fewer messages\n");
    exit(1);
}

int main(int argc, char **argv)
{
    int i;
    const char *trace_path = NULL;
    uint64_t trace_count = 1000000;
    int rc;

    for (i = 1; i < argc; i++) {
        const char *o = argv[i];
#define ARG (i + 1 < argc ? argv[++i] : (usage(), ""))
        if (!strcmp(o, "--boot")) boot_path = ARG;
        else if (!strcmp(o, "--flash")) flash_path = ARG;
        else if (!strcmp(o, "--cpi")) cpi = atof(ARG);
        else if (!strcmp(o, "--timing")) timing = 1;
        else if (!strcmp(o, "--icache-bits")) ic_bits = atoi(ARG);
        else if (!strcmp(o, "--dcache-bits")) dc_bits = atoi(ARG);
        else if (!strcmp(o, "--keys")) load_keys(ARG);
        else if (!strcmp(o, "--dump")) dump_dir = ARG;
        else if (!strcmp(o, "--dump-every")) dump_every = atoi(ARG);
        else if (!strcmp(o, "--dump-prefix")) dump_prefix = ARG;
        else if (!strcmp(o, "--scale")) dump_scale = atoi(ARG);
        else if (!strcmp(o, "--full-color")) dump_full = 1;
        else if (!strcmp(o, "--max-flips")) max_flips = strtoull(ARG, NULL, 0);
        else if (!strcmp(o, "--max-instr")) max_instr = strtoull(ARG, NULL, 0);
        else if (!strcmp(o, "--trace")) trace_path = ARG;
        else if (!strcmp(o, "--trace-count")) trace_count = strtoull(ARG, NULL, 0);
        else if (!strcmp(o, "--switches")) switches = strtoul(ARG, NULL, 0);
        else if (!strcmp(o, "--jtag")) jtag_path = ARG;
        else if (!strcmp(o, "--kernel")) kernel_path = ARG;
        else if (!strcmp(o, "--dump-vga")) dump_vga = strtoull(ARG, NULL, 0);
        else if (!strcmp(o, "--dtb")) dtb_path = ARG;
        else if (!strcmp(o, "--sdram-mb")) sdram_size_v = (uint32_t)atoi(ARG) << 20;
        else if (!strcmp(o, "--flash-out")) flash_out = ARG;
        else if (!strcmp(o, "--quiet")) quiet = 1;
        else if (!strcmp(o, "--log-flips")) log_flips = 1;
        else usage();
    }
    if (dump_every < 1) dump_every = 1;
    if (dump_scale != 1 && dump_scale != 2) usage();

    rom = calloc(1, ROM_SIZE);
    sram = calloc(1, SRAM_SIZE);
    sdram = calloc(1, SDRAM_SIZE);
    flash = malloc(FLASH_SIZE);
    memset(flash, 0xff, FLASH_SIZE);
    if (timing) timing_init();
    load_file(boot_path, rom, ROM_SIZE, "boot ROM");
    if (strcmp(flash_path, "none")) load_file(flash_path, flash, FLASH_SIZE, "flash image");
    if (jtag_path) {
        FILE *f = fopen(jtag_path, "rb");
        if (!f) { fprintf(stderr, "emu: cannot read %s\n", jtag_path); exit(1); }
        fseek(f, 0, SEEK_END); jtag_len = ftell(f); fseek(f, 0, SEEK_SET);
        jtag_buf = malloc(jtag_len);
        if (fread(jtag_buf, 1, jtag_len, f) != jtag_len) { fprintf(stderr, "emu: short read %s\n", jtag_path); exit(1); }
        fclose(f);
    }
    if (dump_dir) mkdir(dump_dir, 0777);
    if (trace_path) {
        trace_f = fopen(trace_path, "w");
        if (!trace_f) { fprintf(stderr, "emu: cannot write %s\n", trace_path); exit(1); }
        trace_n = trace_count;
    }

    pc = 0;
    if (kernel_path) {
        /* Linux: kernel at the start of SDRAM (seen at 0x80000000), the
           device tree in the top 16 KB, which it leaves out of its memory */
        load_file(kernel_path, sdram, SDRAM_SIZE - 0x4000, "kernel");
        if (!dtb_path) { fprintf(stderr, "emu: --kernel needs --dtb\n"); exit(1); }
        load_file(dtb_path, sdram + SDRAM_SIZE - 0x4000, 0x4000, "device tree");
        pc = 0x80000000u;
        x[10] = 0;
        x[11] = 0x80000000u + SDRAM_SIZE - 0x4000;
    }
    rc = run();
    if (poweroff_requested && !quiet)
        fprintf(stderr, "emu: %s requested\n", poweroff_requested == 0x5555 ? "poweroff" : "reboot");
    if (trace_f) fclose(trace_f);
    if (flash_out) {
        FILE *f = fopen(flash_out, "wb");
        if (!f || fwrite(flash, 1, FLASH_SIZE, f) != FLASH_SIZE) { fprintf(stderr, "emu: cannot write %s\n", flash_out); exit(1); }
        fclose(f);
    }
    if (fl_erases || fl_programs)
        fprintf(stderr, "flash: %llu chip erases, %llu bytes programmed\n",
                (unsigned long long)fl_erases, (unsigned long long)fl_programs);
    stats();
    return rc;
}
