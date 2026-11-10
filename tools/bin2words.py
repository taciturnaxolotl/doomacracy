#!/usr/bin/env python3
"""Raw little-endian binary -> one 32-bit hex word per line."""
import struct, sys
d = open(sys.argv[1], "rb").read()
d += b"\0" * (-len(d) % 4)
open(sys.argv[2], "w").write("".join("%08x\n" % w for w in struct.unpack("<%dI" % (len(d) // 4), d)))
