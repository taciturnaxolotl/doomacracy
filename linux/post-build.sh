#!/bin/sh
# buildroot post-build: compile our own programs into the target. Buildroot
# passes TARGET_DIR as $1 and exports HOST_DIR. Same flat-binary flags
# buildroot gives its own packages: -fPIC, and elf2flt -r (load to RAM,
# relocate); -s is the stack size written into the header.
set -e
here=$(cd "$(dirname "$0")" && pwd)
for prog in doomfetch doombench; do
    "$HOST_DIR/bin/riscv32-buildroot-linux-uclibc-gcc" -Os -Wall -fPIC -Wl,-elf2flt="-r -s 8192" \
        -o "$1/usr/bin/$prog" "$here/$prog/$prog.c"
    # elf2flt leaves a debug ELF next to the binary; it is 10x the size
    rm -f "$1/usr/bin/$prog.gdb"
done
