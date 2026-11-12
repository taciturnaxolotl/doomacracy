# doomacracy spec

Doom (shareware, via doomgeneric) on the Terasic DE1, running on a homemade
RV32IM soft CPU written in VHDL. Sibling of `../tetricide`, same habits: VHDL-93,
`ieee.numeric_std` only, everything simulated in nvc before it goes near
Quartus.

## Target

| thing | value |
| --- | --- |
| board | DE1, Cyclone II EP2C20F484C7 (18,752 LEs, 52 M4K, 26 mult 18x18) |
| toolchain | Quartus II 8.1 Web Edition (13.0 SP1 also works), nvc for sim; the JTAG Tcl scripts are Tcl 8.4 |
| system clock | 50 MHz `CLOCK_50`, one clock domain |
| CPU | RV32IMA with Zicsr, M and U modes, timer and software interrupts (see Linux platform) |
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
| `0x3C` | `VIDEO_MODE` | R/W | bit 0: RGB565 pixels instead of palette indices; latched with `FB_BASE` at vertical blank; 0 after reset |
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
- `VIDEO_MODE` bit 0 switches to 320x200 RGB565 (640 bytes a line, top 4
  bits of each channel to the DAC); Linux's console uses it. The line buffer
  holds two 320-halfword lines (4 M4K).

## Blocks

| block | job |
| --- | --- |
| `cpu` | RV32IM multicycle core; separate instruction and data ports |
| `icache` | 8 KB direct mapped, 16-byte lines, over ROM, SRAM and SDRAM |
| `dcache` | 8 KB direct mapped, 16-byte lines, write-through with a one-word write buffer, no write allocate, over SRAM and SDRAM |
| `membus` | routes cache fills, write-throughs and uncached accesses to the slaves |
| `sram_ctrl` | 16-bit async SRAM, video gets priority |
| `sdram_ctrl` | IS42S16400, CL2, burst length 1, one open row per bank (hits skip the activate), auto refresh |
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

## Linux platform

For a no-MMU Linux. Implemented in both the emulator and the RTL.

| addition | where | notes |
| --- | --- | --- |
| A extension | CPU | LR.W, SC.W, AMO*.W (read, compute, write through the data port) |
| machine-mode CSRs | CPU | mstatus (MIE, MPIE, MPP), misa, mie, mip, mtvec, mscratch, mepc, mcause, mtval, cycle, time, instret |
| traps | CPU | ecall, ebreak, illegal instruction, misaligned and access faults, MRET; WFI is a no-op in the RTL; M and U privilege |
| FENCE.I | CPU | clears every I-cache tag (512 cycles) |
| SDRAM alias | `0x8000_0000` | the same 8 MB as `0x2000_0000`; the D-cache folds both onto one tag, so the two views can't go stale |
| console | `0xF000_1000` | 16550, registers 4 bytes apart (Linux `ns16550a`, `reg-shift = 2`), polled; output goes to the RS-232 pin and the JTAG console |
| syscon | `0xF000_2000` | write `0x5555` to power off (CPU halts, HEX `00FF`), `0x7777` to reboot (full board reset) |
| PS/2 | `0xF000_3000` | the keyboard FIFO laid out like Altera's PS/2 core (Linux `altr,ps2-1.0`): `+0` read pops a byte, bits 31:16 = bytes waiting, bit 15 valid; `+4` bit 0 = receive interrupt enable, bit 8 = interrupt pending. Receive only |
| PLIC | `0xF400_0000` | `sifive,plic-1.0.0` with one source (1 = PS/2) and one context (M-mode, MEIP): priority `+0x4`, pending `+0x1000`, enable `+0x2000` bit 1, threshold `+0x200000`, claim/complete `+0x200004` |
| CLINT | `0xF100_0000` | msip `+0`, mtimecmp `+0x4000`, mtime `+0xBFF8`; mtime counts microseconds and is also `TIMER_US` |

### JTAG console (Virtual JTAG IR 3)

One 80-bit DR scan per poll, least significant bit first, run by
`tools/jtag_console.tcl`. Board to host: bits 3:0 byte count (0 to 8), bits
7:4 `0xA`, bits 12:8 RX read pointer (mod 32), bit 13 attached, bytes at bit
16 + 8i. Host to board: bits 3:0 count, bit 4 attach, bit 5 detach, bytes at
bit 16 + 8i. Two 16-byte FIFOs; the host never sends more than 16 bytes past
the board's read pointer. While a host is attached the 16550 reports its
transmitter busy when the FIFO is full; with no host (or no scan for about
0.67 s) output is dropped instead, so Linux never stalls.

### Booting Linux from flash

A flash image whose magic is `0x58554E4C` ("LNUX") is a Linux image
(`tools/mklinuxflash.py`): +4 kernel length, +8 DTB offset, +12 DTB length,
kernel at `0x100`. The boot ROM copies the kernel to the start of SDRAM and
the DTB to its top 16 KB, then jumps to `0x80000000` with `a0 = 0` and
`a1` = the DTB address.

Traps go to `mtvec` only once it is nonzero. Before that every fault stops
the machine, which keeps bare-metal bugs (and Doom's) loud.

Our own build (`linux/`, Linux 6.8 with a trimmed busybox) boots to a root
shell in the emulator with the DE1's real 8 MB, with about 3.5 MB free. The
kernel must have `CONFIG_RISCV_MISALIGNED`, because misaligned loads and
stores trap here.
