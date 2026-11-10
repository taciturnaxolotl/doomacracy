#!/usr/bin/env python3
"""Wrap a flash image in the JTAG loader stream (see sw/boot/boot.c):
magic, word count, words, 32-bit sum. tools/jtag_flash.tcl builds the same
stream itself; this copy feeds the emulator and the testbench."""
import struct, sys
data = open(sys.argv[1], "rb").read()
data += b"\xff" * (-len(data) % 4)
words = struct.unpack("<%dI" % (len(data) // 4), data)
out = struct.pack("<II", 0x4A544147, len(words)) + data + struct.pack("<I", sum(words) & 0xFFFFFFFF)
open(sys.argv[2], "wb").write(out)
if len(sys.argv) > 3:   # also one hex word per line, for the VHDL testbench
    open(sys.argv[3], "w").write("".join("%08x\n" % w for w in struct.unpack("<%dI" % (len(out) // 4), out)))
