/* newlib system calls for the CoreMark firmware: stdout and stderr go to the
 * UART, the heap is the SRAM between .bss and the stack, and there are no
 * files. */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include "doomacracy_hw.h"

#undef errno
extern int errno;

static void uart_putc(int c)
{
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint32_t)(c & 0xff);
}

int _write(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    size_t k;
    if (fd != 1 && fd != 2) {
        errno = EBADF;
        return -1;
    }
    for (k = 0; k < n; k++) {
        if (p[k] == '\n')
            uart_putc('\r');
        uart_putc(p[k]);
    }
    return (int)n;
}

extern char __heap_start[], __heap_end[];
static char *heap_ptr = __heap_start;

void *_sbrk(ptrdiff_t incr)
{
    char *old = heap_ptr;
    if (incr < 0 || (size_t)incr > (size_t)(__heap_end - heap_ptr)) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_ptr += incr;
    return old;
}

void _exit(int code)
{
    /* Done: power off through the syscon. The CPU halts with HEX 00FF and
       LEDR9 on, the emulator exits and the RTL testbench stops. A nonzero
       code stays on HEX instead. */
    if (code)
        HEX = 0xE000 | (code & 0xfff);
    else
        *(volatile uint32_t *)(IO_BASE + 0x2000) = 0x5555;
    __asm__ volatile("1: j 1b");
    for (;;)
        ;
}

int _read(int fd, void *buf, size_t n) { (void)fd; (void)buf; (void)n; return 0; }
int _close(int fd) { (void)fd; return 0; }
int _lseek(int fd, int off, int whence) { (void)fd; (void)off; (void)whence; errno = ESPIPE; return -1; }
int _isatty(int fd) { return fd >= 0 && fd <= 2; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void) { return 1; }

int _fstat(int fd, struct stat *st)
{
    (void)fd;
    st->st_mode = S_IFCHR;
    return 0;
}
