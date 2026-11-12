#!/bin/sh
# buildroot post-build: compile doomfetch into the target. Buildroot passes
# TARGET_DIR as $1 and exports HOST_DIR. Same flat-binary flags buildroot
# gives its own packages: -fPIC, and elf2flt -r (load to RAM, relocate);
# -s is the stack size written into the header.
set -e
here=$(cd "$(dirname "$0")" && pwd)
"$HOST_DIR/bin/riscv32-buildroot-linux-uclibc-gcc" -Os -Wall -fPIC -Wl,-elf2flt="-r -s 8192" \
    -o "$1/usr/bin/doomfetch" "$here/doomfetch/doomfetch.c"
# elf2flt leaves a debug ELF next to the binary; it is 10x the size
rm -f "$1/usr/bin/doomfetch.gdb"
