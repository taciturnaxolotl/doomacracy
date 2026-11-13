# doomacracy software

Boot ROM, Doom firmware (doomgeneric port), flash image tools and a host
emulator of the SoC. The hardware contract is `spec.md` in the repo root.

## Toolchain

`nix develop` gives `riscv32-none-elf-gcc`, nvc, python3, make and imagemagick.
The compiler is the nixpkgs `riscv32-none-elf` cross gcc, but configured with
`arch = rv32im, abi = ilp32` (see `flake.nix`). The stock
`pkgsCross.riscv32-embedded` toolchain ships newlib and libgcc built for
rv32gc/ilp32d only, which cannot be linked into rv32im/ilp32 code. The first
`nix develop` builds gcc and newlib from source (about 20 minutes). Inside a
git checkout, nix only sees tracked files, so `flake.nix` has to be tracked
(or use `nix develop path:$PWD`). The shell disables the cc wrapper's
hardening flags, which otherwise change the firmware (stack protector,
fortify).

Without nix, any `riscv32-none-elf-` toolchain whose newlib/libgcc are
rv32im/ilp32 works. Use `make CROSS=/path/to/riscv32-none-elf-` for a prefix
that is not on PATH.

## Make targets (top-level Makefile, software section)

| target | what |
| --- | --- |
| `make sw` | boot ROM, firmware, stripped WAD, flash image |
| `make wad` | `build/doom1-stripped.wad` only |
| `make emu` | `build/emu` (host cc) |
| `make run-emu` | boot to the title screen, `build/frames/title-*.png` |
| `make demo-emu` | menu, new game, gameplay from `sw/doom/keys-demo.txt`, `build/frames/play-*.png` |
| `make attract-emu` | title and attract-mode demos, `build/frames/attract-*.png` |
| `make bench-emu` | `-timedemo demo1` (SW0 up), prints instructions between page flips |
| `make sw-clean` | remove the software outputs |

Outputs:

- `sw/build/boot.bin`, copied to `build/boot.bin`: boot ROM image.
- `build/boot_rom_init.txt`: boot ROM as 1024 lines of 8 hex digits (one
  little-endian 32-bit word per line, word 0 first, zero padded).
- `sw/build/doom.elf`, `sw/build/doom.map`: firmware.
- `build/flash.bin`: flash image. `build/flash.hex`: the same, one byte per
  line as 2 hex digits, byte 0 first (only the used part of the flash; the
  rest is erased, 0xFF).

## Layout

`sw/boot/`: boot ROM (start.S, boot.c, boot.ld). Stack at 0x10060000. It
has no .data/.bss/.rodata at all (the linker script asserts this): strings
are emitted as `li` immediates, so the ROM only has to be readable by
instruction fetch. It prints a banner, checks the header, copies
`length` bytes from flash 0x100 to `load_addr` and jumps to `entry`. Errors
print on the UART, set LEDR to all on and HEX to `E00n`, and spin
(1 bad magic, 2 bad load address/length, 3 bad entry).

`sw/doom/`: the firmware.

- `crt0.S`: sets gp/sp, copies the cold image from flash to SDRAM, zeroes
  .bss, runs constructors, calls main.
- `doom.ld`: memory layout (below).
- `syscalls.c`: newlib syscalls. fd 1/2 go to the UART (LF becomes CRLF).
  `doom1.wad` (any directory) can be opened read only and reads from flash;
  everything else fails, so config and savegame writes fail cleanly.
  `_sbrk` hands out SDRAM from the end of .bss to 0x20800000.
- `doomgeneric_doomacracy.c`: main, DG_* functions and the PS/2 decoder.
- `i_video_doomacracy.c`: replaces upstream `i_video.c` (8-bit video, page
  flip, palette register).
- `w_file_flash.c`: replaces upstream `w_file_stdc.c`; WAD reads copy from
  flash into zone memory, nothing is ever mapped.
- `keys-demo.txt`: emulator key script used by `make demo-emu`.

`tools/`: `wad_strip.py` (zero-length sfx/music/ENDOOM lumps),
`mkflash.py` (flash image), `rom_init.py` (boot ROM init file).

`emu/doomacracy_emu.c`: the emulator.

## Firmware memory layout

| range | contents |
| --- | --- |
| SRAM 0x10000000.. | crt0, libgcc, libc mem*/str*, then the rest of .text, .rodata, .data (copied by the boot ROM) |
| after that | `.sram_bss`: Doom's 320x200 render buffer (not in the image) |
| SRAM ..0x10060000 | 16 KB stack (the emulator reports the lowest sp seen) |
| SDRAM 0x20000000.. | `.cold`: code and data that only run at startup, in menus, per tic or on level load (libc stdio/printf, savegames, menus, config, automap, intermission, level setup...) |
| after that | .bss, then the heap; Doom's zone is a 6 MB malloc |

The cold image is stored in flash directly after the firmware
(flash 0x100 + header.length) and crt0 copies it to SDRAM. The boot ROM does
not know about it. This was needed because the whole program (about 530 KB)
does not fit in the 384 KB SRAM firmware area.

## Video

Doom renders into its own 320x200 buffer in SRAM. `I_FinishUpdate` waits
until FRAME_COUNT has changed since the previous flip (so the previous
front buffer is no longer being scanned out), copies the buffer into the
back framebuffer (SRAM 0x60000 or 0x70000), writes FB_BASE and swaps.
`I_SetPalette` writes all 256 entries through PALETTE (gamma applied). At
start both framebuffers are cleared and FB_BASE is set to buffer A, which
the emulator counts as flip 1 (a black frame).

## Keyboard

Raw set-2 bytes from KBD are decoded (E0 prefix, F0 break, E1 pause, ack and
self-test bytes ignored). Keys follow doomgeneric's default bindings:
arrows move/turn, either ctrl fires, space is use, either shift runs, either
alt strafes, `,` and `.` strafe, Enter, Escape, Tab (automap), y/n, 1-7
weapons, F1-F12, `-`/`=` (automap zoom, screen size), Pause. The keypad
arrows/Home/End/PgUp/PgDn work as on DOS.

## Switches

SW0 up at boot: run `-timedemo demo1` and stop at the end (benchmark; the
result is printed on the UART).

The firmware reads the version byte of DEMO1 and passes `-gameversion` to
match (the v1.8 shareware demos are version 108; without this chocolate
Doom assumes 1.9 and refuses to play them).

## Emulator

```
build/emu [--boot build/boot.bin] [--flash build/flash.bin] [options]
```

It models RV32IM and the memory map exactly. Fatal errors (with pc and
instruction count): misaligned load/store/fetch, store to ROM or flash,
unmapped address, byte/halfword I/O access, undefined I/O register,
illegal instruction (including any CSR instruction), fetch from flash or
I/O. A jump to itself (`j .`) halts the run (that is what `_exit` and the
boot ROM error path do). ecall/ebreak also stop it.

Time comes from the instruction count: cycles = instret * cpi
(`--cpi`, default 3), TIMER_US = cycles / 50, FRAME_COUNT = cycles / 718400.
UART output goes to stdout (CR dropped). SWITCHES returns `--switches` with
all KEYs released.

Options:

- `--keys FILE`: keyboard script. Each line is `<vga_frame> tokens...`
  (bytes become available once FRAME_COUNT reaches that value) or
  `f<n> tokens...` (after page flip n). Tokens are 2-digit hex raw PS/2
  bytes, or `+name` (make), `-name` (break), `*name` (make then break).
  Names: a-z, 0-9, minus, equals, comma, period, slash, backspace, space,
  tab, capslock, lshift/rshift/shift, lctrl/ctrl, rctrl, lalt/alt, ralt,
  enter, esc, f1-f12, up, down, left, right, home, end, pgup, pgdn, insert,
  delete, kpenter. Bytes enter the 16-byte FIFO one per millisecond of
  emulated time; overflow drops bytes and is counted. `#` starts a comment.
- `--dump DIR`, `--dump-every N`, `--dump-prefix S`, `--scale 1|2`: on each
  FB_BASE write, write the displayed frame through the palette as PPM.
  Colours are reduced to 4 bits per channel like the hardware, unless
  `--full-color`.
- `--max-flips N`, `--max-instr N`: stop.
- `--log-flips`: print instret and VGA frame on every flip.
- `--trace FILE [--trace-count K]`: retirement trace of the first K
  instructions (default 1,000,000).

On exit it prints instructions retired, cycles, loads/stores per region,
flips, estimated fps at the configured CPI, min/avg/max instructions between
flips and the lowest stack pointer seen.

### Trace format

One line per retired instruction, all fields fixed-width lowercase hex,
separated by single spaces:

```
PPPPPPPP IIIIIIII RR VVVVVVVV
```

- `PPPPPPPP`: pc of the instruction.
- `IIIIIIII`: the instruction word.
- `RR`: destination register written (00-1f). `00` when the instruction
  writes no register (stores, branches, fence) or its rd is x0.
- `VVVVVVVV`: value written to rd; `00000000` when RR is `00`.

Example (`li sp, 0x10060000` then `li gp, 0`):

```
00000000 10060137 02 10060000
00000004 00000193 03 00000000
```

The trace is exact for anything that does not depend on time: loads from
TIMER_US, TIMER_CYCLES, FRAME_COUNT and KBD return values derived from the
emulator's CPI model, so a cycle-accurate RTL simulation will diverge at the
first such load (the boot ROM does not read any of them).
