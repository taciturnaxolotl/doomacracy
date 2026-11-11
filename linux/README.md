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
  simple applets in-process; a few big applets dropped (unzip, top, tree,
  lsof, checksums, xxd...). Busybox is 478 KB, under 512 KB: no-MMU loads a
  private copy per process in a power-of-two block, so this halves the cost
  of every command.
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
