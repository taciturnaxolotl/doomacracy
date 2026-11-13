# Linux on doomacracy

A no-MMU Linux 6.8 (cnlohr's mini-rv32ima fork) with busybox in an
initramfs, configured for the DE1's 8 MB of SDRAM.

## Build (on a Linux machine)

```
cd linux
nix-build fhs.nix -o br-fhs      # NixOS only: a normal /usr layout for buildroot
./br-fhs/bin/br-fhs -c ./build.sh
```

The first build makes a cross toolchain and takes about an hour on two
cores. Copy `work/buildroot/output/images/Image` to `build/linux-Image`.

## Run in the emulator

```
make linux-emu            # 8 MB, the board's real size
```

## Changes from cnlohr's configs

- `CONFIG_RISCV_MISALIGNED=y`: our CPU traps on misaligned loads and stores
  (cnlohr's emulator quietly handles them), so the kernel has to fix them up.
- busybox: `FEATURE_PREFER_APPLETS` and `FEATURE_SH_STANDALONE`, so hush runs
  simple applets in-process; `vi` turned on; a few applets dropped (unzip,
  top, tree, lsof, checksums, xxd, and login/getty, which pulled in 83 KB of
  password code nothing here uses). No-MMU loads a private copy of busybox
  for every process, rounded up to a power of two, so its load size (text +
  data + bss + stack, from `flthdr`) has to stay under 512 KB; it is 430 KB.
- `patches/uclibc/0001-riscv32-no-64bit-syscall-arg-alignment.patch`: uClibc
  padded 64-bit syscall arguments ARM-style on riscv32, so `ftruncate`
  received a length of 0 and `vi` emptied every file it saved.
- `overlay/etc/inittab`: a respawning root shell on the serial console and
  one on the screen (`tty1`).
- Framebuffer console: `FB_SIMPLE`, `FRAMEBUFFER_CONSOLE`, `FONT_6x8`.
- Keyboard: `SERIO_ALTERA_PS2`, `KEYBOARD_ATKBD`, and the PLIC driver.
- `patches/linux/0001-altera_ps2-receive-only.patch`: the board's PS/2 port
  only receives, so the driver registers no write function; `atkbd` then
  skips probing the keyboard and treats it as plain set 2. The patch
  directory is listed after cnlohr's own (`board/qemu/riscv32-virt/nommu/
  patches`), which carries the rv32 no-MMU support; replacing it instead of
  adding to it builds a kernel whose `wait4` returns ENOSYS.
- The kernel's built-in device tree is not used; `tools/gen_dts.py` writes it.

## doomfetch

`doomfetch/doomfetch.c` is a small neofetch, compiled into the image by
`post-build.sh` and run from `/etc/profile` when a shell starts. It is C on
purpose: every process here loads its own copy of its program, so a 64 KB
binary is far cheaper than a script that runs busybox (430 KB) a dozen
times. For the same reason a pipe of two external busybox commands can run
out of memory; prefer shell builtins where you can.

Programs of your own are built the same way: the buildroot cross gcc with
`-fPIC -Wl,-elf2flt="-r -s STACK"`, and delete the `.gdb` file elf2flt
leaves next to the binary.

## doombench

`doombench` (`-q` for a quicker run) times a set of small tests and prints,
for each, the wall time, a rate, and the real cycles per instruction from
the CPU's own `cycle` and `instret` counters: integer ALU, multiply, divide,
`qsort`, reads and writes inside the D-cache (4K) and well beyond it (128K),
`memcpy`, load latency for a dependent pointer chase (cycles per hop,
including the loop), a system call, and starting a process. The last line
checks the cycle counter against the wall clock (it should read 50 MHz).
The table fits the 53x25 screen, since there is no pager.

In the emulator with `--timing` the same table comes from the RTL cycle
model, so the two can be compared row by row. Model, at 50 MHz:

```
doombench x1     ms     rate        CPI
alu             209    14.36 Mop/s  2.05
mul              34     3.71 M/s    2.65
div              45     1.11 M/s    9.99
qsort 1K         78    39.21 Kel/s  2.60
read 4K          71    28.07 MB/s   2.42
read 128K       111    18.03 MB/s   3.72
write 4K         66    30.41 MB/s   3.49
write 128K       67    29.86 MB/s   3.52
memcpy 64K       86    11.61 MB/s   3.46
lat 4K           14      279 ns     13.9 cyc
lat 128K         34      673 ns     33.5 cyc
syscall          75    66.62 K/s    2.93
spawn           147    54.57 /s     5.21
```
