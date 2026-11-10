#!/usr/bin/env python3
"""Flash image for the loader test: spec header + hello.bin at 0x100."""
import struct
fw = open("hello.bin", "rb").read()
fw += b"\0" * (-len(fw) % 4)
hdr = struct.pack("<6I", 0x4D4F4F44, 0x10000000, len(fw), 0x10000000, 0, 0)
img = hdr + b"\xff" * (0x100 - len(hdr)) + fw
open("image.bin", "wb").write(img)
