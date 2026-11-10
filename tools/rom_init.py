#!/usr/bin/env python3
"""Turn the boot ROM binary into one 32-bit hex word per line.

Little-endian words, zero padded to exactly 1024 lines (4 KB). The RTL side
turns this into the boot_rom contents.

usage: rom_init.py boot.bin boot_rom_init.txt
"""
import struct
import sys

WORDS = 1024


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    data = bytearray(open(sys.argv[1], "rb").read())
    if len(data) > WORDS * 4:
        sys.exit("rom_init: FAIL: %s is %d bytes, ROM is %d" % (sys.argv[1], len(data), WORDS * 4))
    used = len(data)
    data += b"\0" * (WORDS * 4 - len(data))
    with open(sys.argv[2], "w") as f:
        for i in range(WORDS):
            f.write("%08X\n" % struct.unpack_from("<I", data, 4 * i)[0])
    print("rom_init: %s: %d of %d bytes used" % (sys.argv[2], used, WORDS * 4))


if __name__ == "__main__":
    main()
