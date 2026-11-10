#!/usr/bin/env python3
"""Build the doomacracy flash image (spec.md, "Flash image").

  0x000000  header, little-endian u32s:
              +0x00 magic 0x4D4F4F44 ("DOOM")
              +0x04 load_addr
              +0x08 length (firmware bytes, multiple of 4)
              +0x0C entry
              +0x10 wad_offset
              +0x14 wad_length
            rest of the first 256 bytes is 0xFF
  0x000100  firmware binary (padded to a multiple of 4); this is what the
            boot ROM copies to load_addr, header.length bytes
  0x100 + length  optional cold image (--cold), copied by the firmware's own
            startup code from flash to SDRAM
  wad_offset (4 KB aligned) WAD
  unused space is 0xFF (erased flash)

usage: mkflash.py --firmware fw.bin [--cold cold.bin] --wad doom.wad --load 0x10000000
                  --entry 0x10000000 --out flash.bin [--hex flash.hex]
                  [--max-firmware BYTES]
"""
import argparse
import struct
import sys

FLASH_SIZE = 4 * 1024 * 1024
MAGIC = 0x4D4F4F44
FW_OFFSET = 0x100


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--firmware", required=True)
    ap.add_argument("--cold", help="image stored right after the firmware, not copied by the boot ROM")
    ap.add_argument("--wad", required=True)
    ap.add_argument("--load", type=lambda s: int(s, 0), default=0x10000000)
    ap.add_argument("--entry", type=lambda s: int(s, 0), default=0x10000000)
    ap.add_argument("--max-firmware", type=lambda s: int(s, 0), default=0x58000,
                    help="largest firmware that leaves room for the stack")
    ap.add_argument("--out", required=True)
    ap.add_argument("--hex")
    a = ap.parse_args()

    fw = bytearray(open(a.firmware, "rb").read())
    while len(fw) % 4:
        fw.append(0)
    cold = bytearray(open(a.cold, "rb").read()) if a.cold else bytearray()
    while len(cold) % 4:
        cold.append(0)
    wad = open(a.wad, "rb").read()

    if len(fw) > a.max_firmware:
        sys.exit("mkflash: FAIL: firmware is %d bytes, limit %d" % (len(fw), a.max_firmware))

    wad_offset = (FW_OFFSET + len(fw) + len(cold) + 4095) & ~4095
    end = wad_offset + len(wad)
    if end > FLASH_SIZE:
        sys.exit("mkflash: FAIL: image needs %d bytes, flash is %d (over by %d)"
                 % (end, FLASH_SIZE, end - FLASH_SIZE))

    img = bytearray(b"\xff" * end)
    hdr = struct.pack("<6I", MAGIC, a.load, len(fw), a.entry, wad_offset, len(wad))
    img[0:len(hdr)] = hdr
    img[FW_OFFSET:FW_OFFSET + len(fw)] = fw
    img[FW_OFFSET + len(fw):FW_OFFSET + len(fw) + len(cold)] = cold
    img[wad_offset:end] = wad
    open(a.out, "wb").write(img)

    if a.hex:
        with open(a.hex, "w") as f:
            f.write("\n".join("%02X" % b for b in img))
            f.write("\n")

    print("mkflash: %s: firmware %d bytes at 0x%06x, cold %d bytes at 0x%06x, "
          "wad %d bytes at 0x%06x, image %d bytes, %d bytes free of %d"
          % (a.out, len(fw), FW_OFFSET, len(cold), FW_OFFSET + len(fw), len(wad), wad_offset, end,
             FLASH_SIZE - end, FLASH_SIZE))


if __name__ == "__main__":
    main()
