#!/usr/bin/env python3
"""Flash image that boots Linux (sw/include/doomacracy_hw.h, LINUX_MAGIC):

    mklinuxflash.py Image doomacracy-8mb.dtb build/linux-flash.bin"""
import struct, sys
kernel = open(sys.argv[1], "rb").read()
dtb = open(sys.argv[2], "rb").read()
kernel += b"\0" * (-len(kernel) % 4)
dtb_off = 0x100 + len(kernel)
img = struct.pack("<4I", 0x58554E4C, len(kernel), dtb_off, len(dtb))
img += b"\xff" * (0x100 - len(img)) + kernel + dtb
if len(img) > 4 << 20:
    sys.exit(f"image is {len(img)} bytes, flash holds {4 << 20}")
open(sys.argv[3], "wb").write(img)
print(f"{sys.argv[3]}: kernel {len(kernel)}, dtb {len(dtb)} at {dtb_off:#x}, {len(img)} bytes, {(4 << 20) - len(img)} free")
