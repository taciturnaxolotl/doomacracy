// PS/2 receive through the PLIC as a machine external interrupt: enable
// everything the way Linux does, then print each byte from the handler.
// Booted like a kernel (sim/traptest/start.S); output must match the emulator.
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(a))
#define THR  REG(0xF0001000u)
#define LSR  REG(0xF0001014u)
#define PS2D REG(0xF0003000u)
#define PS2C REG(0xF0003004u)
#define PLIC 0xF4000000u

static void out(char c) { while (!(LSR & 0x20)) ; THR = (uint8_t)c; }
static void puts_(const char *s) { while (*s) out(*s++); }
static void hex2(uint32_t v) { out("0123456789abcdef"[(v >> 4) & 15]); out("0123456789abcdef"[v & 15]); }

extern void trap_entry(void);
volatile uint32_t user_result;   /* referenced by the shared start.S */
static volatile int got;
static volatile uint32_t bad;

void trap_c(uint32_t *frame)
{
    uint32_t cause;
    (void)frame;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause != 0x8000000bu) { bad = cause; return; }
    uint32_t id = REG(PLIC + 0x200004);            // claim
    if (id != 1) { puts_(" spurious"); return; }
    uint32_t d;
    while ((d = PS2D) & 0xffff0000u) {               // RAVAIL
        out(' '); hex2(d & 0xff);
        got++;
    }
    REG(PLIC + 0x200004) = id;                       // complete
}

int main(void)
{
    puts_("ps2test");
    __asm__ volatile("csrw mtvec, %0" :: "r"(trap_entry));
    REG(PLIC + 0x000004) = 1;                        // priority of source 1
    REG(PLIC + 0x002000) = 2;                        // enable source 1, context 0
    REG(PLIC + 0x200000) = 0;                        // threshold
    PS2C = 1;                                        // RE
    __asm__ volatile("csrs mie, %0" :: "r"(1u << 11));
    __asm__ volatile("csrs mstatus, %0" :: "r"(8u));
    while (got < 8 && !bad)
        ;
    __asm__ volatile("csrc mstatus, %0" :: "r"(8u));
    if (bad) { puts_(" bad cause "); hex2(bad); }
    puts_("\ndone\n");
    REG(0xF0002000u) = 0x5555;                       // power off
    for (;;) ;
}
