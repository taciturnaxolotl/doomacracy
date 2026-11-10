#!/usr/bin/env python3
"""Read and write Quartus II project archives (.qar).

Format, worked out from a Quartus II 8.1 archive:

    magic   71 02 75 00
    entry*  u32 LE  compressed size
            u16 LE  flags (0x0007 normal file, 0x0047 the timestamp table)
            u16 LE  name length
            name    path relative to the project, '/' separated
            data    zlib stream (default level, header 78 9c)

The last entry is `zlib_out_time_stamp_tmp.tmp`, a text table giving each
file's name and two Unix times, which Quartus uses to restore timestamps.

    qar.py unpack ARCHIVE.qar OUTDIR
    qar.py pack ARCHIVE.qar DIR FILE...    (FILE paths relative to DIR)
"""
import os
import struct
import sys
import time
import zlib

MAGIC = b"\x71\x02\x75\x00"
FLAG_FILE = 0x0700
FLAG_STAMPS = 0x4700
STAMPS = "zlib_out_time_stamp_tmp.tmp"


def read(path):
    data = open(path, "rb").read()
    if data[:4] != MAGIC:
        raise SystemExit(f"{path}: not a Quartus archive")
    pos, entries = 4, []
    while pos + 8 <= len(data):
        csize, flags, nlen = struct.unpack("<IHH", data[pos:pos + 8])
        pos += 8
        name = data[pos:pos + nlen].decode()
        pos += nlen
        entries.append((name, flags, zlib.decompress(data[pos:pos + csize])))
        pos += csize
    return entries


def entry(name, flags, body):
    z = zlib.compress(body)
    n = name.encode()
    return struct.pack("<IHH", len(z), flags, len(n)) + n + z


def write(path, root, files):
    out = [MAGIC]
    stamps = []
    now = int(time.time())
    for f in files:
        body = open(os.path.join(root, f), "rb").read()
        name = f.replace(os.sep, "/")
        out.append(entry(name, FLAG_FILE, body))
        mtime = int(os.path.getmtime(os.path.join(root, f)))
        stamps.append(f"<File_info_start>\n{name}\n{now}\n{mtime}\n<File_info_end>\n")
    out.append(entry(STAMPS, FLAG_STAMPS, "".join(stamps).encode()))
    open(path, "wb").write(b"".join(out))


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "unpack":
        for name, _, body in read(sys.argv[2]):
            if name == STAMPS:
                continue
            dest = os.path.join(sys.argv[3], name)
            os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
            open(dest, "wb").write(body)
            print(f"{len(body):9d}  {name}")
    elif len(sys.argv) >= 5 and sys.argv[1] == "pack":
        write(sys.argv[2], sys.argv[3], sys.argv[4:])
        print(f"wrote {sys.argv[2]} ({len(sys.argv) - 4} files)")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
