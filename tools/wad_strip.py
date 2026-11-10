#!/usr/bin/env python3
"""Strip a Doom IWAD for the doomacracy flash.

Every sound effect (DS*, DP*), music (D_*) and ENDOOM lump is made zero
length. The directory keeps every entry (same names, same order) so lump
lookups by name still succeed; only the data is dropped. Zero-length lumps
get filepos 0. Lumps listed in KEEP are never stripped.

usage: wad_strip.py in.wad out.wad
"""
import struct
import sys

# Lumps that match the strip patterns but that the engine needs anyway.
# (None known for the shareware IWAD with sound disabled; DS*/DP*/D_* are only
# read by the sound and music code, ENDOOM only on quit.)
KEEP = set()


def should_strip(name):
    if name in KEEP:
        return False
    if name == "ENDOOM":
        return True
    if name.startswith("DS") or name.startswith("DP"):
        return True
    if name.startswith("D_"):
        return True
    return False


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    data = open(sys.argv[1], "rb").read()
    ident, numlumps, diroff = struct.unpack_from("<4sii", data, 0)
    if ident not in (b"IWAD", b"PWAD"):
        sys.exit("not a WAD: %r" % ident)
    lumps = []
    for i in range(numlumps):
        pos, size, name = struct.unpack_from("<ii8s", data, diroff + 16 * i)
        name = name.split(b"\0", 1)[0].decode("ascii")
        lumps.append((name, pos, size))

    out = bytearray(12)
    directory = bytearray()
    stripped = 0
    stripped_bytes = 0
    for name, pos, size in lumps:
        if size and should_strip(name):
            stripped += 1
            stripped_bytes += size
            size = 0
        if size == 0:
            newpos = 0
        else:
            # keep lump data 4-byte aligned so word copies out of flash are fast
            while len(out) % 4:
                out.append(0)
            newpos = len(out)
            out += data[pos:pos + size]
        directory += struct.pack("<ii8s", newpos, size, name.encode("ascii"))
    while len(out) % 4:
        out.append(0)
    newdir = len(out)
    out += directory
    struct.pack_into("<4sii", out, 0, ident, numlumps, newdir)
    open(sys.argv[2], "wb").write(out)
    print("wad_strip: %s: %d lumps, %d stripped (%d bytes), %d -> %d bytes"
          % (sys.argv[2], numlumps, stripped, stripped_bytes, len(data), len(out)))


if __name__ == "__main__":
    main()
