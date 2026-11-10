// Tiny firmware for the JTAG loader test: proves the boot ROM booted an
// image it just wrote into flash itself.
#include <stdint.h>
#define IO(off) (*(volatile uint32_t *)(0xF0000000u + (off)))
static void out(char c) { while (!(IO(0x04) & 1)) ; IO(0x00) = (uint8_t)c; }
void _start(void) __attribute__((naked, section(".text.start")));
void _start(void) { __asm__ volatile("li sp, 0x10060000\n call main_\n ebreak\n"); }
void main_(void) {
    const char *s = "hello from flash\n";   /* lives in the copied image */
    while (*s) out(*s++);
    IO(0x20) = 0xBEEF;
}
