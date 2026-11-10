# doomacracy spec

Doom (shareware, via doomgeneric) on the Terasic DE1, running on a homemade
RV32IM soft CPU written in VHDL. Sibling of `../tetricide`, same habits: VHDL-93,
`ieee.numeric_std` only, everything simulated in nvc before it goes near
Quartus.

## Target

| thing | value |
| --- | --- |
| board | DE1, Cyclone II EP2C20F484C7 (18,752 LEs, 52 M4K, 26 mult 18x18) |
| toolchain | Quartus II 13.0 SP1 (last with Cyclone II), nvc for sim |
| system clock | 50 MHz `CLOCK_50`, one clock domain |
| CPU | RV32IM, no interrupts, no privilege modes |
| video | 320x200 8 bpp from SRAM, doubled to 640x400 inside 640x480 @ 60 Hz |
| input | PS/2 keyboard, raw scancode bytes to software |
| software | doomgeneric, `riscv32-none-elf-gcc` + newlib, `-march=rv32im -mabi=ilp32` |

## Memory map

| base | size | what | notes |
| --- | --- | --- | --- |
| `0x0000_0000` | 4 KB | boot ROM | M4K, reset vector is `0x0` |
| `0x1000_0000` | 512 KB | SRAM | 16-bit async SRAM, cached |
| `0x2000_0000` | 8 MB | SDRAM | cached |
| `0x3000_0000` | 4 MB | flash | read only, uncached, slow (about 25 cycles per word) |
| `0xF000_0000` | | I/O | uncached, word access only |

Misaligned loads and stores are not supported by the hardware. Anything the
compiler emits for packed structs is byte loads, which is fine.

### SRAM layout (set by the firmware linker script)

| range | use |
| --- | --- |
| `0x1000_0000` .. `0x1006_0000` | hot firmware (`.text`, `.rodata`, `.data`), Doom's render buffer, stack at the top |
| `0x1006_0000` .. `0x1006_FA00` | framebuffer A (320x200 bytes) |
| `0x1007_0000` .. `0x1007_FA00` | framebuffer B |

The whole firmware does not fit in SRAM, so code and data used only at
startup, in menus or on level load go in a `.cold` section linked at SDRAM
`0x2000_0000`. `.bss` and the heap (`sbrk`, Doom's 6 MB zone) follow it.

## I/O registers (`0xF000_0000` + offset)

All 32-bit, word access only. The flash region allows aligned word and byte
loads.

| offset | name | R/W | meaning |
| --- | --- | --- | --- |
| `0x00` | `UART_DATA` | W | send byte `[7:0]` (only when `UART_STATUS.tx_ready`) |
| `0x00` | `UART_DATA` | R | bit 31 = byte valid, `[7:0]` = byte; reading pops |
| `0x04` | `UART_STATUS` | R | bit 0 = tx_ready |
| `0x08` | `TIMER_US` | R | free-running microseconds since reset |
| `0x0C` | `TIMER_CYCLES` | R | free-running 50 MHz cycle count |
| `0x10` | `KBD` | R | bit 8 = valid, `[7:0]` = raw PS/2 byte (`E0`, `F0` included); reading pops a 16-deep FIFO |
| `0x14` | `SWITCHES` | R | `[9:0]` = SW, `[19:16]` = KEY (1 = released) |
| `0x18` | `LEDR` | W | `[9:0]` |
| `0x1C` | `LEDG` | W | `[7:0]` |
| `0x20` | `HEX` | W | `[15:0]` shown as four hex digits on HEX3..0 |
| `0x30` | `FB_BASE` | R/W | byte offset into SRAM of the displayed framebuffer, reset value `0x60000`; latched at the start of vertical blank |
| `0x34` | `FRAME_COUNT` | R | increments at the start of vertical blank, in the same cycle `FB_BASE` is latched |
| `0x40` | `JTAG_DATA` | R | next word from the JTAG loader; reading pops a 16-word FIFO |
| `0x44` | `JTAG_STATUS` | R | bit 0 = word waiting, bit 1 = FIFO overflowed (sticky until reset) |
| `0x38` | `PALETTE` | W | `[31:24]` index, `[23:16]` R, `[15:8]` G, `[7:0]` B; hardware keeps the top 4 bits of each |

UART is 115200 8N1 on the DE1 RS-232 port.

## Flash image

The 4 MB flash holds a header, the firmware, and a stripped WAD.

```
0x000000  header (little-endian u32s)
            +0x00 magic       0x4D4F4F44 ("DOOM")
            +0x04 load_addr   where the boot ROM copies the firmware (0x10000000)
            +0x08 length      firmware length in bytes, multiple of 4
            +0x0C entry       address the boot ROM jumps to
            +0x10 wad_offset  byte offset of the WAD in flash
            +0x14 wad_length  bytes
0x000100  firmware binary (the SRAM image)
0x000100 + length  cold image; crt0 copies it to SDRAM 0x20000000
wad_offset (4 KB aligned)  WAD
```

The WAD is `doom1.wad` with every sound effect (`DS*`, `DP*`), music (`D_*`)
and `ENDOOM` lump set to zero length; the directory is kept intact so lookups
still succeed. That takes it from 4,196,020 bytes to about 3.41 MB.

The boot ROM checks the magic, copies `length` bytes from flash `0x100` to
`load_addr`, and jumps to `entry`. If the magic is wrong it prints to the UART
and spins with the LEDs showing an error.

## Video

- 640x480 @ 60 Hz timing (25 MHz pixel enable from the 50 MHz clock).
- Rows 40..439 show the framebuffer, each source pixel 2x2. Everything else is black.
- Each 320-byte source line is prefetched from SRAM into an M4K line buffer while
  the previous line is on screen. Video wins SRAM arbitration.
- Palette: 256 x 12-bit M4K, written through `PALETTE`.

## Blocks

| block | job |
| --- | --- |
| `cpu` | RV32IM multicycle core; separate instruction and data ports |
| `icache` | 8 KB direct mapped, 16-byte lines, over ROM, SRAM and SDRAM |
| `dcache` | 8 KB direct mapped, 16-byte lines, write-through with a one-word write buffer, no write allocate, over SRAM and SDRAM |
| `membus` | routes cache fills, write-throughs and uncached accesses to the slaves |
| `sram_ctrl` | 16-bit async SRAM, video gets priority |
| `sdram_ctrl` | IS42S16400, CL2, burst length 1, auto refresh |
| `flash_ctrl` | 8-bit NOR reads |
| `video` | VGA timing, line prefetch, palette |
| `ps2_rx` | PS/2 byte receiver into a FIFO |
| `uart` | 115200 8N1 |
| `io` | timers, LEDs, HEX, switches, register decode |
| `boot_rom` | generated from `sw/boot` |

## Performance

From the emulator's cycle model of this RTL (`--timing`), on `-timedemo
demo1`: about 1.28M instructions per frame at CPI 3.0, so roughly 13 fps.
Cache size barely matters (4 KB to 32 KB each moves it from 12 to 14 fps);
what limits it is the multicycle core itself, 2 cycles per instruction and 3
per load or store. A pipelined core is the next big win.

## JTAG flash loader

With SW9 up at reset, the boot ROM writes a new flash image before booting.
`tools/jtag_flash.tcl` (run with `quartus_stp`) sends it through an Altera
Virtual JTAG instance (`rtl/vjtag_port.vhd`, 2-bit IR):

- IR 1: DR scans carry the stream, 32 bits per word, least significant bit
  first. `rtl/jtag_rx.vhd` moves each word into the system clock domain and a
  16-word FIFO behind `JTAG_DATA`.
- IR 2: a 32-bit DR capture of {overflow, words received}.

Stream: `0x4A544147` ("JTAG"), word count n, n image words, their 32-bit
sum. The boot ROM buffers the image in SDRAM, checks the sum, chip-erases,
programs every byte that isn't `FF` (AMD byte-mode commands, DQ7 data
polling), verifies, and then boots normally.

HEX shows the phase: `1xxx` receiving, `2000` erasing, `3xxx` programming,
`4000` verifying, `600d` done. Errors: `E010` image too big, `E011` bad
checksum, `E012` FIFO overflow, `E013` erase failed, `E014` program failed,
`E015` verify mismatch, each followed by a value as with `E001`.
