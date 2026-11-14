# doomacracy

![title screen, captured from the VGA pins in the VHDL simulation](docs/title-rtl.png)

Doom on a Terasic DE1, running on a homemade RV32IMA CPU written in VHDL. The same board also boots a no-MMU Linux to a shell on the VGA monitor and the PS/2 keyboard.

The majority of this project was done with llms as a what if question on whether this was even possible.

| | |
| --- | --- |
| CPU | RV32IMA, five stage pipeline, 50 MHz, M and U modes |
| caches | 8 KB instruction, 8 KB data |
| memory | 512 KB SRAM, 8 MB SDRAM, 4 MB flash |
| video | 320x200, shown as 640x400 at 70 Hz so it fills a 4:3 monitor |
| speed | about 22 fps in Doom's timedemo and 2.4 CoreMark/MHz, both from the emulator's cycle model, which the board matches within a few percent on [doombench](linux/README.md) |

## Docs

- [spec.md](spec.md): memory map, registers, flash layout.
- [sw/README.md](sw/README.md): the firmware, the emulator and CoreMark.
- [linux/README.md](linux/README.md): building and running Linux.
- [docs/book](docs/book): a hardware reference manual with block diagrams, state machines and timing. `make book` builds the PDF.

## Build

```
nix develop
make sw emu            # firmware, flash image, emulator
make run-emu           # title screen in build/frames/
make coremark-emu      # CoreMark score from the emulator's cycle model
make cpu-test          # CPU against ideal memory
make soc-test          # whole board in nvc with chip models
make soc-boot          # boot the real firmware in nvc and compare with the emulator
make rom               # adds back boot rom
make qar               # build/doomacracy.qar Quartus archive
make book              # docs/book/doomacracy.pdf (needs TeX Live, not in the nix shell)
```

The WAD is not bundled with the repo; put the shareware `doom1.wad` in `wad/`.

Use plain `nix develop`, not `nix develop path:$PWD`. The `path:` form copies the whole directory into the nix store every time, `build/` included, and that is several GB a go.

## Running it on the board

`make qar` builds `build/doomacracy.qar`, which also carries `flash.bin`,
`linux-flash.bin`, `jtag_flash.tcl` and `jtag_console.tcl`. In Quartus II
13.0 SP1:

1. Restore the archive, compile, and program `doomacracy.sof` (JTAG mode,
   one device in the chain).
2. Load the flash once, no Control Panel needed: put SW9 up, press KEY0 (HEX
   shows `1000`), then from the project folder run

   ```
   quartus_stp -t jtag_flash.tcl flash.bin
   ```

   HEX then counts through `20rr` and `30rr` (erasing and programming each
   64 KB region `rr` that changed) and `600d`, and the game boots. Only
   regions that differ from what's already in flash are rewritten, so loading
   a slightly changed image is quick.
3. Put SW9 back down. From now on KEY0 just boots Doom.

Redo step 2 only when the firmware changes.

The picture is 640x400 at 70 Hz, the VGA mode DOS Doom used. A 4:3 monitor
stretches it to fill the screen. An LCD may detect it as 720x400 and look a
little soft.

### Linux

Load `linux-flash.bin` the same way as `flash.bin` and the board boots Linux
instead: a shell on the monitor and the PS/2 keyboard, and another on the
serial console. The serial console is the RS-232 port and, over the
USB-Blaster, `quartus_stp -t jtag_console.tcl`. To try a Linux image without
writing the flash at all, put SW8 up as well as SW9: it boots straight from
RAM and is gone at the next reset.

The kernel image is not built here. `make qar` expects `build/linux-Image`,
which comes from a buildroot run on a Linux machine; see
[linux/README.md](linux/README.md).

### CoreMark

`make coremark` builds `build/coremark-flash.bin`. Load it like `flash.bin`
and read the report on the RS-232 port at 115200 baud. See
[sw/README.md](sw/README.md) for what the numbers mean.

the canonical repo for this is hosted on tangled over at [`https://tangled.org/dunkirk.sh/doomacracy`](https://tangled.org/dunkirk.sh/doomacracy)

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

<p align="center">
    <i><code>&copy; 2026-present <a href="https://dunkirk.sh">Kieran Klukas</a></code></i>
</p>

<p align="center">
    <a href="https://tangled.org/dunkirk.sh/doomacracy/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
