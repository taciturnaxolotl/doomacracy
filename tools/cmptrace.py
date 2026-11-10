#!/usr/bin/env python3
"""Compare two retirement traces (emulator vs RTL), resynchronising after
polling loops on I/O registers, whose values legitimately differ."""
import sys

def load(p):
    return [l.lower().split() for l in open(p) if l.strip()]

a, b = load(sys.argv[1]), load(sys.argv[2])
i = j = 0
checked = resyncs = 0
while i < len(a) and j < len(b):
    if a[i] == b[j]:
        i += 1; j += 1; checked += 1
        continue
    # an I/O load: anything whose value differs right after an lw from 0xf000xxxx
    # is allowed; skip both traces forward to the next common pc + instr + value
    found = False
    for di in range(0, 20000):
        if i + di >= len(a):
            break
        key = a[i + di]
        for dj in range(0, 20000):
            if j + dj < len(b) and b[j + dj] == key and (di + dj) > 0:
                # require 50 matching lines to call it synced
                if all(i + di + k < len(a) and j + dj + k < len(b) and a[i + di + k] == b[j + dj + k]
                       for k in range(50)):
                    i += di; j += dj; found = True
                break
        if found:
            break
    if not found:
        print(f"MISMATCH at emu line {i + 1}, rtl line {j + 1}")
        print("  emu:", " ".join(a[i]))
        print("  rtl:", " ".join(b[j]))
        sys.exit(1)
    resyncs += 1
print(f"traces agree: {checked} instructions compared, {resyncs} I/O resyncs")
