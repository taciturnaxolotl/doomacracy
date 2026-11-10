# doomacracy

![title screen, captured from the VGA pins in the VHDL simulation](docs/title-rtl.png)

Doom on a Terasic DE1, running on a homemade RV32IM CPU written in VHDL. See [spec.md](spec.md) for the memory map, registers and flash layout, and [sw/README.md](sw/README.md) for the software and the emulator.

The majority of this project was done with llms as a what if question on whether this was even possible.

## Build

```
nix develop path:$PWD
make sw emu            # firmware, flash image, emulator
make run-emu           # title screen in build/frames/
make cpu-test          # CPU against ideal memory, compare with the host
make soc-test          # whole board in nvc with chip models
make soc-boot          # boot the real firmware in nvc and compare with the emulator
make rom               # put the real boot ROM back before Quartus
```

The WAD is not bundled with the repo; put the shareware `doom1.wad` in `wad/`.

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
