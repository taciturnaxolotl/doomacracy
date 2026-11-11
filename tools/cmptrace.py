#!/usr/bin/env python3
"""Compare two retirement traces (emulator vs RTL), resynchronising after
stretches whose values legitimately differ: polling loops on I/O registers,
timer and counter reads, and code that waits for an interrupt.

    cmptrace.py EMU_TRACE RTL_TRACE [--window N] [--quiet]

Each line is "pc instr rd value". If the traces start at different pcs (the
RTL ran a boot stub first), the RTL trace is skipped up to the emulator's
first pc.

At a mismatch, the cheap explanation is tried first: one side spun a polling
or wait loop more often than the other (the RTL's UART is really busy, the
emulator's never is). That is accepted if only one side skips, every skipped
line is within 256 bytes of the line where they meet again, and the next 8
lines agree. Otherwise both sides may skip up to --window lines (default
20000) and 50 lines (or all that is left) must agree afterwards; the
smallest total skip wins. Skipped lines are not compared; the totals are
printed."""
import sys

args = []
window = 20000
quiet = False
argv = sys.argv[1:]
k = 0
while k < len(argv):
    if argv[k] == "--window":
        window = int(argv[k + 1]); k += 2; continue
    if argv[k] == "--quiet":
        quiet = True; k += 1; continue
    args.append(argv[k]); k += 1


def load(p):
    return [" ".join(l.lower().split()) for l in open(p) if l.strip()]


a, b = load(args[0]), load(args[1])


def pc(line):
    return int(line[:8], 16)


i = j = 0
if a and b and a[0][:8] != b[0][:8]:
    while j < len(b) and b[j][:8] != a[0][:8]:
        j += 1
    print(f"skipped {j} RTL lines before the emulator's first pc {a[0][:8]}")

checked = resyncs = loops = skip_a = skip_b = 0
NEED = 50
LOOP_NEED = 8


def agree(i, j, n):
    n = min(n, len(a) - i, len(b) - j)
    for k in range(n):
        if a[i + k] != b[j + k]:
            return False
    return True


def loop_skip(x, y, xi, yj):
    """y spun longer: find x[xi] later in y, with only nearby code skipped"""
    p = pc(x[xi])
    for d in range(1, window):
        if yj + d >= len(y) or abs(pc(y[yj + d - 1]) - p) >= 256:
            return None
        if y[yj + d] == x[xi]:
            return d
    return None


def general(i, j):
    """the agreeing pair (di, dj) with the smallest di + dj"""
    idx = {}
    for dj in range(0, min(window, len(b) - j)):
        idx.setdefault(b[j + dj], []).append(dj)
    best = None
    limit = 2 * window
    for di in range(0, min(window, len(a) - i)):
        if di >= limit:
            break
        for dj in idx.get(a[i + di], ()):
            if di + dj >= limit:
                break
            if di + dj > 0 and agree(i + di, j + dj, NEED):
                best, limit = (di, dj), di + dj
                break
    return best


while i < len(a) and j < len(b):
    if a[i] == b[j]:
        i += 1; j += 1; checked += 1
        continue
    d = loop_skip(a, b, i, j)
    if d is not None and agree(i, j + d, LOOP_NEED):
        j += d; skip_b += d; loops += 1
        continue
    d = loop_skip(b, a, j, i)
    if d is not None and agree(i + d, j, LOOP_NEED):
        i += d; skip_a += d; loops += 1
        continue
    r = general(i, j)
    if r is None:
        print(f"MISMATCH at emu line {i + 1}, rtl line {j + 1} (after {checked} lines agreed)")
        print("  emu:", a[i])
        print("  rtl:", b[j])
        sys.exit(1)
    di, dj = r
    if not quiet:
        print(f"  resync: emu line {i + 1} (+{di}), rtl line {j + 1} (+{dj}), at pc {a[i + di][:8]}")
    i += di; j += dj; skip_a += di; skip_b += dj
    resyncs += 1
print(f"traces agree: {checked} instructions compared, {loops} loop resyncs, {resyncs} other resyncs; "
      f"skipped {skip_a} of {len(a)} emu lines and {skip_b} of {len(b)} rtl lines")
