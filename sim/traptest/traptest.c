// Machine-mode and Linux-platform checks for the doomacracy RTL, written to
// print exactly the same thing in the emulator (emu --kernel) and in nvc
// (tb_soc with sim/linuxboot as the boot ROM). Only values that do not
// depend on timing are printed. Ends with a syscon power off.
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define U_THR  REG(0xF0001000u)
#define U_IER  REG(0xF0001004u)
#define U_IIR  REG(0xF0001008u)
#define U_LCR  REG(0xF000100Cu)
#define U_MCR  REG(0xF0001010u)
#define U_LSR  REG(0xF0001014u)
#define U_MSR  REG(0xF0001018u)
#define U_SCR  REG(0xF000101Cu)
#define SYSCON REG(0xF0002000u)
#define MSIP   REG(0xF1000000u)
#define CMP_LO REG(0xF1004000u)
#define CMP_HI REG(0xF1004004u)
#define MT_LO  REG(0xF100BFF8u)
#define MT_HI  REG(0xF100BFFCu)

#define csrr(n) ({ uint32_t v_; __asm__ volatile("csrr %0, " #n : "=r"(v_)); v_; })
#define csrw(n, v) __asm__ volatile("csrw " #n ", %0" :: "r"(v))
#define csrs(n, v) __asm__ volatile("csrs " #n ", %0" :: "r"(v))
#define csrc(n, v) __asm__ volatile("csrc " #n ", %0" :: "r"(v))

extern char trap_entry[], vec_table[], user_return[];
extern void run_user(void (*fn)(void));
extern void user_fn(void);
volatile uint32_t user_result;

static void putc_(char c) { while (!(U_LSR & 0x20)) ; U_THR = (uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void hex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]); }
static void kv(const char *k, uint32_t v) { puts_(k); putc_(' '); hex(v); putc_('\n'); }

// ---------------------------------------------------------------- traps
struct frame { uint32_t ra, t0, t1, t2, a[8], t3, t4, t5, t6; };
static volatile uint32_t n_traps, last_cause, last_epc, last_tval, last_vec, timer_hits;

void trap_c(struct frame *f)
{
    uint32_t cause = csrr(mcause), epc = csrr(mepc);
    n_traps++;
    last_cause = cause;
    last_epc = epc;
    last_tval = csrr(mtval);
    last_vec = csrr(mscratch);
    csrw(mscratch, 0x1f);
    if (cause == 0x80000003u) {             // software interrupt
        MSIP = 0;
    } else if (cause == 0x80000007u) {      // timer
        CMP_HI = 0xffffffffu;
        CMP_LO = 0xffffffffu;
        csrc(mie, 0x80);
        timer_hits++;
    } else if (cause == 0 || cause == 1) {  // bad fetch: back to the caller
        csrw(mepc, f->ra);
    } else if (cause == 8) {                // ecall from U: back to M-mode
        csrw(mepc, (uint32_t)user_return);
        csrs(mstatus, 0x1800);
    } else {
        csrw(mepc, epc + 4);
    }
}

static void report(const char *what, uint32_t base)
{
    puts_(what);
    puts_(" cause "); hex(last_cause);
    puts_(" epc+"); hex(last_epc - base);
    puts_(" tval "); hex(last_tval);
    putc_('\n');
}

static uint32_t do_ecall(void)   { uint32_t a; __asm__ volatile("1: ecall\n la %0, 1b" : "=r"(a) :: "memory"); return a; }
static uint32_t do_ebreak(void)  { uint32_t a; __asm__ volatile("1: ebreak\n la %0, 1b" : "=r"(a) :: "memory"); return a; }
static uint32_t do_ill0(void)    { uint32_t a; __asm__ volatile("1: .word 0xffffffff\n la %0, 1b" : "=r"(a) :: "memory"); return a; }
static uint32_t do_ill1(void)    { uint32_t a; __asm__ volatile("1: .word 0x00000000\n la %0, 1b" : "=r"(a) :: "memory"); return a; }
static uint32_t do_ill2(void)    { uint32_t a; __asm__ volatile("1: .word 0x00004073\n la %0, 1b" : "=r"(a) :: "memory"); return a; } // SYSTEM funct3 4
static uint32_t do_ill3(void)    { uint32_t a; __asm__ volatile("1: .word 0x40001033\n la %0, 1b" : "=r"(a) :: "memory"); return a; } // OP f7=0x20 f3=1
static uint32_t do_ill4(void)    { uint32_t a; __asm__ volatile("1: .word 0x12000073\n la %0, 1b" : "=r"(a) :: "memory"); return a; } // sfence.vma

#define LD(name, op) static uint32_t name(uint32_t p) { uint32_t a, v = 0; \
    __asm__ volatile("1: " op " %1, 0(%2)\n la %0, 1b" : "=&r"(a), "+r"(v) : "r"(p) : "memory"); return a; }
#define ST(name, op) static uint32_t name(uint32_t p) { uint32_t a; \
    __asm__ volatile("1: " op " zero, 0(%1)\n la %0, 1b" : "=&r"(a) : "r"(p) : "memory"); return a; }
#define AM(name, op) static uint32_t name(uint32_t p) { uint32_t a, v = 0; \
    __asm__ volatile("1: " op " %1, zero, (%2)\n la %0, 1b" : "=&r"(a), "+r"(v) : "r"(p) : "memory"); return a; }
LD(do_lw, "lw") LD(do_lh, "lh") LD(do_lhu, "lhu") LD(do_lb, "lb")
ST(do_sw, "sw") ST(do_sh, "sh")
AM(do_amoadd, "amoadd.w") AM(do_amoswap, "amoswap.w")
static uint32_t do_lr(uint32_t p) { uint32_t a, v; __asm__ volatile("1: lr.w %1, (%2)\n la %0, 1b" : "=&r"(a), "=&r"(v) : "r"(p) : "memory"); return a; }
static uint32_t do_badamo(uint32_t p) { uint32_t a; __asm__ volatile("1: .insn r 0x2f, 2, 0x14, x0, %1, x0\n la %0, 1b" : "=&r"(a) : "r"(p) : "memory"); return a; } // funct5 00101

static uint32_t jump_to(uint32_t target)
{
    uint32_t a;
    __asm__ volatile("1: jalr ra, 0(%1)\n la %0, 1b" : "=&r"(a) : "r"(target) : "ra", "memory");
    return a;
}
static void ret_only(void) { }

// ---------------------------------------------------------------- AMOs
#define AMO(op, p, v) ({ uint32_t o_; __asm__ volatile(op " %0, %2, (%1)" : "=r"(o_) : "r"(p), "r"(v) : "memory"); o_; })
static uint32_t lr(volatile uint32_t *p) { uint32_t v; __asm__ volatile("lr.w %0, (%1)" : "=r"(v) : "r"(p) : "memory"); return v; }
static uint32_t sc(volatile uint32_t *p, uint32_t v) { uint32_t r; __asm__ volatile("sc.w %0, %2, (%1)" : "=r"(r) : "r"(p), "r"(v) : "memory"); return r; }

static void amo_tests(volatile uint32_t *w, const char *name)
{
    uint32_t h = 0;
    puts_("amo "); puts_(name); putc_('\n');
    *w = 100;
    h = h * 31 + AMO("amoswap.w", w, 7);
    h = h * 31 + AMO("amoadd.w", w, 5);
    h = h * 31 + AMO("amoxor.w", w, 0xff);
    h = h * 31 + AMO("amoand.w", w, 0xf0);
    h = h * 31 + AMO("amoor.w", w, 0x80000001u);
    h = h * 31 + AMO("amomin.w", w, 3);            // signed: negative stays
    h = h * 31 + AMO("amomax.w", w, 3);
    h = h * 31 + AMO("amominu.w", w, 0x80000000u);
    h = h * 31 + AMO("amomaxu.w", w, 0x90000000u);
    kv("  hash", h);
    kv("  final", *w);
    // LR/SC
    *w = 1;
    uint32_t v = lr(w);
    uint32_t r1 = sc(w, v + 10);           // succeeds
    uint32_t r2 = sc(w, 99);               // reservation gone: fails
    kv("  lrsc", v | r1 << 8 | r2 << 12);
    kv("  after", *w);
    lr(w);
    uint32_t r3 = sc(w + 1, 5);            // other address: fails
    lr(w);
    __asm__ volatile("ecall" ::: "memory"); // a trap clears it
    uint32_t r4 = sc(w, 5);
    kv("  sc other/trap", r3 | r4 << 4);
    kv("  value", *w);
}

// ---------------------------------------------------------------- fence.i
static uint32_t call_code(uint32_t addr) { return ((uint32_t (*)(void))addr)(); }

static void fencei_test(void)
{
    volatile uint32_t *code = (volatile uint32_t *)0x10000100u;
    // li a0, 42 ; ret
    code[0] = 0x02a00513; code[1] = 0x00008067;
    __asm__ volatile("fence.i" ::: "memory");
    uint32_t a = call_code((uint32_t)code);
    code[0] = 0x02b00513;                   // li a0, 43
    __asm__ volatile("fence.i" ::: "memory");
    uint32_t b = call_code((uint32_t)code);
    // the same through the SDRAM alias: write at 0x2..., run at 0x8...
    volatile uint32_t *c2 = (volatile uint32_t *)0x20600000u;
    c2[0] = 0x02c00513; c2[1] = 0x00008067;  // li a0, 44
    __asm__ volatile("fence.i" ::: "memory");
    uint32_t c = call_code(0x80600000u);
    c2[0] = 0x02d00513;                      // li a0, 45
    __asm__ volatile("fence.i" ::: "memory");
    uint32_t d = call_code(0x80600000u);
    kv("fence.i", a | b << 8 | c << 16 | d << 24);
}

// ---------------------------------------------------------------- main
int main(void)
{
    puts_("traptest\n");

    // CSRs without traps
    kv("misa", csrr(misa));
    kv("mvendorid", csrr(mvendorid) | csrr(marchid) | csrr(mimpid) | csrr(mhartid));
    csrw(mstatus, 0xffffffffu);
    kv("mstatus all ones", csrr(mstatus));
    csrw(mstatus, 0);
    csrw(mie, 0xffffffffu);
    kv("mie all ones", csrr(mie));
    csrw(mie, 0);
    csrw(mscratch, 0xdeadbeefu);
    kv("mscratch", csrr(mscratch));
    csrw(mepc, 0x12345677u);
    kv("mepc", csrr(mepc));
    csrw(mcause, 0x8000000bu);
    kv("mcause", csrr(mcause));
    csrw(mtval, 0xcafef00du);
    kv("mtval", csrr(mtval));
    csrw(mip, 0xffffffffu);
    kv("mip", csrr(mip));
    {
        uint32_t o1, o2, o3, o4;
        __asm__ volatile("csrrwi %0, mscratch, 21\n csrrsi %1, mscratch, 10\n csrrci %2, mscratch, 1\n csrr %3, mscratch"
                         : "=r"(o1), "=r"(o2), "=r"(o3), "=r"(o4));
        kv("csr imm", o1 ^ o2 << 8 ^ o3 << 16 ^ o4 << 24);
        __asm__ volatile("csrrs %0, mscratch, zero\n csrrc %1, mscratch, zero" : "=r"(o1), "=r"(o2));
        kv("csr read only", o1 | o2 << 8);
    }
    {
        uint32_t u;
        __asm__ volatile("csrw 0x7c0, %1\n csrr %0, 0x7c0" : "=r"(u) : "r"(0x1234));
        kv("unknown csr", u);
        uint32_t c0 = csrr(cycle), i0 = csrr(instret);
        uint32_t c1 = csrr(cycle), i1 = csrr(instret);
        kv("counters move", (c1 > c0) | (i1 > i0) << 1);
        uint32_t t0 = csrr(time), m0 = MT_LO, h = csrr(timeh);
        kv("time vs mtime", (m0 >= t0) | (h == MT_HI) << 1);
    }

    // traps, direct mode
    csrw(mtvec, (uint32_t)trap_entry);
    kv("mtvec", csrr(mtvec) - (uint32_t)trap_entry);
    csrw(mscratch, 0x1f);
    uint32_t a;
    a = do_ecall();  report("ecall", a);
    a = do_ebreak(); report("ebreak", a);
    a = do_ill0();   report("illegal ffffffff", a);
    a = do_ill1();   report("illegal 0", a);
    a = do_ill2();   report("illegal system f3=4", a);
    a = do_ill3();   report("illegal op f7=20", a);
    a = do_ill4();   report("illegal sfence.vma", a);
    kv("mstatus after traps", csrr(mstatus));

    a = do_lw(0x80001001u);  report("lw misaligned", a);
    a = do_lh(0x80001003u);  report("lh misaligned", a);
    a = do_lhu(0x80001001u); report("lhu misaligned", a);
    a = do_sw(0x80001002u);  report("sw misaligned", a);
    a = do_sh(0x80001001u);  report("sh misaligned", a);
    a = do_amoadd(0x80001002u); report("amo misaligned", a);
    a = do_lr(0x80001001u);  report("lr misaligned", a);
    a = do_lw(0x40000000u);  report("lw unmapped", a);
    a = do_lw(0x00001000u);  report("lw past rom", a);
    a = do_lw(0x10080000u);  report("lw past sram", a);
    a = do_lw(0x80800000u);  report("lw past sdram", a);
    a = do_lw(0x20800000u);  report("lw past sdram 2", a);
    a = do_lb(0xf0000000u);  report("lb io", a);
    a = do_lw(0xf0000100u);  report("lw io hole", a);
    a = do_lw(0xf0001020u);  report("lw past uart", a);
    a = do_lw(0xf0002004u);  report("lw past syscon", a);
    a = do_lw(0xf1010000u);  report("lw past clint", a);
    a = do_sw(0x00000100u);  report("sw rom", a);
    a = do_sw(0x30000000u);  report("sw flash", a);
    a = do_sh(0x30000000u);  report("sh flash", a);
    a = do_amoadd(0x00000100u); report("amoadd rom", a);
    a = do_amoswap(0x40000000u); report("amoswap unmapped", a);
    a = do_lr(0x50000000u);  report("lr unmapped", a);
    a = do_badamo(0x80001000u); report("amo bad funct5", a);
    kv("traps so far", n_traps);

    uint32_t ret = 0;
    __asm__ volatile("la %0, 1f\n 1:" : "=r"(ret));
    a = jump_to((uint32_t)ret_only + 2); report("fetch misaligned", (uint32_t)ret_only);
    a = jump_to(0x40000000u); report("fetch unmapped", 0);
    a = jump_to(0x30000000u); report("fetch flash", 0);
    a = jump_to(0x00001000u); report("fetch past rom", 0);
    a = jump_to(0x10080000u); report("fetch past sram", 0);
    (void)a;

    // U-mode, ecall back
    run_user(user_fn);
    report("ecall from U", (uint32_t)user_fn);
    kv("user result", user_result);
    kv("mstatus back in M", csrr(mstatus));

    // software interrupt: pending but masked in M, taken at once in U
    MSIP = 1;
    csrw(mie, 0x8);
    kv("mip with msip", csrr(mip));
    kv("msip reads", MSIP);
    uint32_t before = n_traps;
    run_user(user_fn);
    kv("traps for U run", n_traps - before);
    report("last", (uint32_t)user_fn);
    kv("msip after", MSIP);

    // vectored mode: an interrupt goes to base + 4 * cause, exceptions to base
    csrw(mtvec, (uint32_t)vec_table | 1);
    MSIP = 1;
    csrs(mstatus, 0x8);                     // taken right here
    csrc(mstatus, 0x8);
    kv("vectored msi slot", last_vec);
    report("vectored msi", 0);
    __asm__ volatile("ecall");
    kv("vectored ecall slot", last_vec);
    csrw(mtvec, (uint32_t)trap_entry);
    csrw(mie, 0);

    // AMOs and LR/SC: cached SDRAM (both views), SRAM, and an uncached register
    amo_tests((volatile uint32_t *)0x80002000u, "sdram");
    amo_tests((volatile uint32_t *)0x20002010u, "sdram alias");
    amo_tests((volatile uint32_t *)0x10001000u, "sram");
    U_SCR = 0x11;
    kv("amoadd scr old", AMO("amoadd.w", &U_SCR, 0x22));
    kv("scr", U_SCR);
    // the two SDRAM views stay coherent through the D-cache
    {
        volatile uint32_t *p8 = (volatile uint32_t *)0x80003000u, *p2 = (volatile uint32_t *)0x20003000u;
        *p8 = 1; (void)*p8;
        *p2 = 2;
        uint32_t x8 = *p8;
        *p8 = 3;
        uint32_t x2 = *p2;
        kv("alias", x8 | x2 << 8);
    }

    fencei_test();

    // timer interrupt through the CLINT
    kv("mtimecmp reset", CMP_LO & CMP_HI);
    {
        uint32_t lo = MT_LO, hi = MT_HI;
        CMP_HI = 0xffffffffu;
        CMP_LO = lo + 40;
        CMP_HI = hi + (lo + 40 < lo);
        timer_hits = 0;
        csrw(mie, 0x80);
        csrs(mstatus, 0x8);
        while (!timer_hits)
            __asm__ volatile("wfi");
        csrc(mstatus, 0x8);
        kv("timer cause", last_cause);      // where it lands depends on timing
        kv("timer hits", timer_hits);
        kv("mie after", csrr(mie));
        kv("mtime moved", MT_LO - lo >= 40);
    }

    // 16550
    U_LCR = 0x83;
    U_THR = 0x1b;                           // DLL
    U_IER = 0x02;                           // DLM
    uint32_t dl = U_THR | U_IER << 8 | U_LCR << 16;
    U_LCR = 0x03;
    kv("dll dlm lcr", dl);
    kv("lcr", U_LCR);
    U_MCR = 0x0b;
    kv("mcr", U_MCR);
    REG(0xF0001008u) = 0x07;                // FCR: ignored
    kv("msr", U_MSR);
    U_SCR = 0x5a;
    kv("scr", U_SCR);
    U_IER = 0xff;
    kv("ier", U_IER);
    U_IER = 0;
    kv("iir none", U_IIR);
    while (!(U_LSR & 0x40)) ;
    U_IER = 2;
    kv("iir thre", U_IIR);
    while (!(U_LSR & 1)) ;                  // the testbench / stdin types "ok\r"
    U_IER = 3;
    kv("iir rx", U_IIR);
    U_IER = 0;
    char in[4];
    for (int i = 0; i < 3; i++) { while (!(U_LSR & 1)) ; in[i] = U_THR; }
    kv("rx", in[0] | in[1] << 8 | in[2] << 16);
    while (!(U_LSR & 0x40)) ;
    kv("lsr", U_LSR & 0x61);
    // a longer line: more than the 16-byte receive FIFO, so the JTAG host
    // has to wait for credit; let the FIFO fill up first
    {
        uint32_t t = MT_LO;
        while (MT_LO - t < 300) ;
        uint32_t h = 0, n = 0;
        for (;;) {
            while (!(U_LSR & 1)) ;
            uint32_t c = U_THR;
            if (c == '\r') break;
            h = h * 33 + c; n++;
        }
        kv("line hash", h);
        kv("line length", n);
    }
    kv("rbr empty", U_THR);

    kv("traps total", n_traps);
    puts_("done\n");
    SYSCON = 0x5555;
    for (;;) ;
}
