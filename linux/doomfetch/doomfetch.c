/*
 * doomfetch: neofetch for doomacracy. A small C program on purpose: on this
 * no-MMU Linux every process gets its own copy of its binary, so a 20 KB
 * program is far cheaper than a script that runs busybox a dozen times.
 * Fits the 53x25 framebuffer console.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/utsname.h>

#define RED   "\033[1;31m"
#define YEL   "\033[1;33m"
#define BOLD  "\033[1m"
#define DIM   "\033[0;37m"
#define OFF   "\033[0m"

static const char *logo[] = {
    "   ________   ",
    "  /        \\  ",
    " /  __  __  \\ ",
    "|  (__)(__)  |",
    "|     /\\     |",
    " \\  ||||||  / ",
    "  \\________/  ",
    "   |_|__|_|   ",
    "              ",
    "  D O O M A C ",
    "    R A C Y   ",
};
#define LOGO_LINES (int)(sizeof logo / sizeof logo[0])

static char lines[16][128];
static int nlines;

static void add(const char *key, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

#include <stdarg.h>
static void add(const char *key, const char *fmt, ...)
{
    char val[80];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(val, sizeof val, fmt, ap);
    va_end(ap);
    if (key)
        snprintf(lines[nlines++], sizeof lines[0], YEL "%s" OFF " %s", key, val);
    else
        snprintf(lines[nlines++], sizeof lines[0], "%s", val);
}

/* first line of a small file, newline stripped; "" if missing */
static const char *slurp(const char *path, char *buf, size_t n)
{
    FILE *f = fopen(path, "r");
    buf[0] = 0;
    if (f) {
        if (!fgets(buf, (int)n, f))
            buf[0] = 0;
        fclose(f);
    }
    buf[strcspn(buf, "\n")] = 0;
    return buf;
}

static long meminfo(const char *key)
{
    char line[96];
    long v = -1;
    size_t k = strlen(key);
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f)
        return -1;
    while (fgets(line, sizeof line, f))
        if (!strncmp(line, key, k) && line[k] == ':') {
            v = strtol(line + k + 1, NULL, 10);
            break;
        }
    fclose(f);
    return v;
}

int main(void)
{
    struct utsname u;
    char buf[128], buf2[64], user[32] = "root";
    long total, avail, secs;
    int i, n;

    uname(&u);
    if (getenv("USER"))
        snprintf(user, sizeof user, "%s", getenv("USER"));

    snprintf(lines[nlines++], sizeof lines[0], RED "%s" OFF "@" RED "%s" OFF, user, u.nodename);
    n = (int)strlen(user) + 1 + (int)strlen(u.nodename);
    for (i = 0; i < n && i < 30; i++)
        buf[i] = '-';
    buf[i] = 0;
    add(NULL, "%s", buf);

    add("OS", "Buildroot, no MMU");
    add("Host", "Terasic DE1, Cyclone II");
    add("Kernel", "%s", u.release);

    secs = atol(slurp("/proc/uptime", buf, sizeof buf));
    if (secs >= 3600)
        add("Uptime", "%ldh %ldm", secs / 3600, secs / 60 % 60);
    else if (secs >= 60)
        add("Uptime", "%ldm %lds", secs / 60, secs % 60);
    else
        add("Uptime", "%lds", secs);

    snprintf(buf2, sizeof buf2, "/proc/%d/comm", (int)getppid());
    add("Shell", "%s (busybox)", strcmp(slurp(buf2, buf, sizeof buf), "sh") ? buf : "hush");

    slurp("/proc/device-tree/cpus/cpu@0/riscv,isa", buf, sizeof buf);
    for (i = 0; buf[i]; i++)
        if (buf[i] >= 'a' && buf[i] <= 'z')
            buf[i] -= 32;
    add("CPU", "homemade %s, 50 MHz", buf[0] ? buf : "RV32IMA");

    slurp("/sys/class/graphics/fb0/virtual_size", buf, sizeof buf);
    if (buf[0]) {
        char *c = strchr(buf, ',');
        if (c)
            *c = 'x';
        add("GPU", "%s %s-bit VGA", buf,
            slurp("/sys/class/graphics/fb0/bits_per_pixel", buf2, sizeof buf2));
    }

    total = meminfo("MemTotal");
    avail = meminfo("MemAvailable");
    if (total > 0)
        add("Memory", "%ld / %ld KiB", total - avail, total);

    slurp("/proc/loadavg", buf, sizeof buf);
    {
        char *t = strchr(buf, '/');
        if (t) {
            while (t > buf && t[-1] != ' ')
                t--;
            add("Tasks", "%d", atoi(strchr(t, '/') + 1));
        }
    }

    lines[nlines++][0] = 0;
    snprintf(lines[nlines++], sizeof lines[0],
             "\033[40m   \033[41m   \033[42m   \033[43m   \033[44m   \033[45m   \033[46m   \033[47m   " OFF);

    putchar('\n');
    for (i = 0; i < LOGO_LINES || i < nlines; i++) {
        printf(RED "%s" OFF "  %s\n", i < LOGO_LINES ? logo[i] : "              ",
               i < nlines ? lines[i] : "");
    }
    putchar('\n');
    return 0;
}
