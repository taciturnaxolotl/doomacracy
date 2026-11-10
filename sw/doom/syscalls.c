/*
 * newlib system calls for doomacracy.
 *
 * fd 0/1/2 are the UART. The only file that can be opened is the IWAD
 * ("doom1.wad", any directory), which reads from memory-mapped flash at
 * FLASH_BASE + header.wad_offset. Everything else fails with ENOENT (or EROFS
 * for writes), so config/savegame writes fail gracefully.
 */
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include "doomacracy_hw.h"
#include "doomacracy.h"

#undef errno
extern int errno;

/* ---------------------------------------------------------------- UART */

static void uart_putc(int c)
{
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint32_t)(c & 0xff);
}

/* ---------------------------------------------------------------- time */

static uint32_t last_us;
static uint64_t total_us;

uint64_t doomacracy_time_us(void)
{
    uint32_t now = TIMER_US;
    total_us += (uint32_t)(now - last_us);
    last_us = now;
    return total_us;
}

/* ---------------------------------------------------------------- flash */

uint32_t doomacracy_wad_offset(void)  { return FLASH_HEADER->wad_offset; }
uint32_t doomacracy_wad_length(void)  { return FLASH_HEADER->wad_length; }

/* Copy from flash (uncached, slow) into RAM. Flash is only ever read with
 * aligned word loads except for the unaligned head/tail bytes. */
void doomacracy_flash_read(void *dst, uint32_t flash_off, size_t n)
{
    const volatile uint8_t *sb = (const volatile uint8_t *)(FLASH_BASE + flash_off);
    uint8_t *db = dst;

    while (n && ((uintptr_t)sb & 3)) {
        *db++ = *sb++;
        n--;
    }
    {
        const volatile uint32_t *sw = (const volatile uint32_t *)sb;
        if (((uintptr_t)db & 3) == 0) {
            uint32_t *dw = (uint32_t *)db;
            while (n >= 16) {
                uint32_t a = sw[0], b = sw[1], c = sw[2], d = sw[3];
                dw[0] = a; dw[1] = b; dw[2] = c; dw[3] = d;
                sw += 4; dw += 4; n -= 16;
            }
            while (n >= 4) {
                *dw++ = *sw++;
                n -= 4;
            }
            db = (uint8_t *)dw;
        } else {
            while (n >= 4) {
                uint32_t w = *sw++;
                db[0] = w; db[1] = w >> 8; db[2] = w >> 16; db[3] = w >> 24;
                db += 4; n -= 4;
            }
        }
        sb = (const volatile uint8_t *)sw;
    }
    while (n--)
        *db++ = *sb++;
}

/* ---------------------------------------------------------------- files */

#define MAX_FILES 4
#define FD_BASE 3
static struct { int used; uint32_t pos; } files[MAX_FILES];

int doomacracy_is_wad_path(const char *path)
{
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcasecmp(base, "doom1.wad") == 0;
}

int _open(const char *path, int flags, int mode)
{
    int i;
    (void)mode;
    if (!doomacracy_is_wad_path(path)) {
        errno = (flags & O_ACCMODE) != O_RDONLY ? EROFS : ENOENT;
        return -1;
    }
    if ((flags & O_ACCMODE) != O_RDONLY) {
        errno = EROFS;
        return -1;
    }
    for (i = 0; i < MAX_FILES; i++) {
        if (!files[i].used) {
            files[i].used = 1;
            files[i].pos = 0;
            return FD_BASE + i;
        }
    }
    errno = EMFILE;
    return -1;
}

static int file_slot(int fd)
{
    int i = fd - FD_BASE;
    if (i < 0 || i >= MAX_FILES || !files[i].used)
        return -1;
    return i;
}

int _close(int fd)
{
    int i = file_slot(fd);
    if (fd >= 0 && fd <= 2)
        return 0;
    if (i < 0) {
        errno = EBADF;
        return -1;
    }
    files[i].used = 0;
    return 0;
}

int _read(int fd, void *buf, size_t n)
{
    int i = file_slot(fd);
    uint32_t len;
    if (fd == 0)
        return 0; /* no console input */
    if (i < 0) {
        errno = EBADF;
        return -1;
    }
    len = doomacracy_wad_length();
    if (files[i].pos >= len)
        return 0;
    if (n > len - files[i].pos)
        n = len - files[i].pos;
    doomacracy_flash_read(buf, doomacracy_wad_offset() + files[i].pos, n);
    files[i].pos += n;
    return (int)n;
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

off_t _lseek(int fd, off_t off, int whence)
{
    int i = file_slot(fd);
    int32_t base;
    if (i < 0) {
        errno = (fd >= 0 && fd <= 2) ? ESPIPE : EBADF;
        return -1;
    }
    switch (whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = (int32_t)files[i].pos; break;
    case SEEK_END: base = (int32_t)doomacracy_wad_length(); break;
    default: errno = EINVAL; return -1;
    }
    if (base + off < 0) {
        errno = EINVAL;
        return -1;
    }
    files[i].pos = (uint32_t)(base + off);
    return files[i].pos;
}

int _fstat(int fd, struct stat *st)
{
    memset(st, 0, sizeof *st);
    if (fd >= 0 && fd <= 2) {
        st->st_mode = S_IFCHR;
        return 0;
    }
    if (file_slot(fd) < 0) {
        errno = EBADF;
        return -1;
    }
    st->st_mode = S_IFREG | 0444;
    st->st_size = doomacracy_wad_length();
    return 0;
}

int _stat(const char *path, struct stat *st)
{
    memset(st, 0, sizeof *st);
    if (!doomacracy_is_wad_path(path)) {
        errno = ENOENT;
        return -1;
    }
    st->st_mode = S_IFREG | 0444;
    st->st_size = doomacracy_wad_length();
    return 0;
}

int _isatty(int fd)
{
    if (fd >= 0 && fd <= 2)
        return 1;
    errno = ENOTTY;
    return 0;
}

/* ---------------------------------------------------------------- misc */

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
    /* show the exit code and stop; the emulator detects the jump to self */
    HEX = 0xE000 | (code & 0xfff);
    __asm__ volatile("1: j 1b");
    for (;;)
        ;
}

int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void) { return 1; }

int _gettimeofday(struct timeval *tv, void *tz)
{
    uint64_t us = doomacracy_time_us();
    (void)tz;
    if (tv) {
        tv->tv_sec = (time_t)(us / 1000000);
        tv->tv_usec = (suseconds_t)(us % 1000000);
    }
    return 0;
}

clock_t _times(struct tms *t)
{
    clock_t c = (clock_t)(doomacracy_time_us() / 1000);
    if (t) {
        t->tms_utime = c;
        t->tms_stime = 0;
        t->tms_cutime = 0;
        t->tms_cstime = 0;
    }
    return c;
}

int _unlink(const char *path) { (void)path; errno = EROFS; return -1; }
int _link(const char *a, const char *b) { (void)a; (void)b; errno = EROFS; return -1; }
int _rename(const char *a, const char *b) { (void)a; (void)b; errno = EROFS; return -1; }
int mkdir(const char *path, mode_t mode) { (void)path; (void)mode; errno = EROFS; return -1; }
int _mkdir(const char *path, mode_t mode) { (void)path; (void)mode; errno = EROFS; return -1; }
