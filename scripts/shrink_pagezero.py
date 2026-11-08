#!/usr/bin/env python3
"""Shrink __PAGEZERO so the low 4 GiB of the address space becomes mappable.

Why this is needed
------------------
Every Wine ntdll syscall stub reads a fixed address before it reaches the kernel:

    f6 04 25 08 03 fe 7f 01     test byte ptr [0x7ffe0308], 1
    75 03                       jne  <int 2e path>
    0f 05 / c3                  syscall / ret

That displacement is 32-bit and zero-extended, so the page MUST live below 4 GiB.
A 64-bit iOS app, however, reserves the first 4 GiB with __PAGEZERO:

    __PAGEZERO  vmaddr=0x0  vmsize=0x100000000

so 0x7ffe0000 falls inside the app's own guard region and cannot be mapped --
mmap with MAP_FIXED fails outright (device log: "M8i: MAP_FIXED mmap at
0x7ffe0000 failed"). Shrinking the guard to one 64 KiB page keeps the null-page
protection that matters and frees everything above it.

This must run BEFORE codesign: the signature covers the Mach-O header.

Usage: python3 shrink_pagezero.py <path-to-app-binary> [target-size]
"""
import pathlib
import struct
import sys

LC_SEGMENT_64 = 0x19
MH_MAGIC_64 = 0xFEEDFACF
DEFAULT_TARGET = 0x10000      # 64 KiB; anything above this becomes mappable


def main(argv):
    if len(argv) < 2:
        print("usage: shrink_pagezero.py <binary> [target]", file=sys.stderr)
        return 2
    path = pathlib.Path(argv[1])
    target = int(argv[2], 0) if len(argv) > 2 else DEFAULT_TARGET

    data = bytearray(path.read_bytes())
    if len(data) < 32:
        print("shrink_pagezero: %s is too small to be Mach-O" % path, file=sys.stderr)
        return 1
    magic, = struct.unpack_from("<I", data, 0)
    if magic != MH_MAGIC_64:
        print("shrink_pagezero: %s is not a 64-bit Mach-O (magic 0x%x)" % (path, magic),
              file=sys.stderr)
        return 1
    ncmds, = struct.unpack_from("<I", data, 16)

    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if size < 8:
            print("shrink_pagezero: malformed load command at 0x%x" % off, file=sys.stderr)
            return 1
        if cmd == LC_SEGMENT_64:
            name = bytes(data[off + 8:off + 24]).rstrip(b"\0")
            if name == b"__PAGEZERO":
                vmaddr, vmsize = struct.unpack_from("<QQ", data, off + 24)
                if vmaddr != 0:
                    print("shrink_pagezero: __PAGEZERO starts at 0x%x, not 0" % vmaddr,
                          file=sys.stderr)
                    return 1
                if vmsize <= target:
                    print("shrink_pagezero: __PAGEZERO already 0x%x, nothing to do" % vmsize)
                    return 0
                struct.pack_into("<Q", data, off + 32, target)
                path.write_bytes(data)
                print("shrink_pagezero: __PAGEZERO 0x%x -> 0x%x (low 4 GiB now mappable)"
                      % (vmsize, target))
                return 0
        off += size

    # No PAGEZERO at all also means the low 4 GiB is free -- nothing to do.
    print("shrink_pagezero: no __PAGEZERO segment (low addresses already free)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
