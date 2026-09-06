#!/usr/bin/env python3
"""Minimal Android sparse image -> raw, writing holes for DONT_CARE (sparse output)."""
import struct, sys, os

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW, CHUNK_FILL, CHUNK_DONTCARE, CHUNK_CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4

def convert(src, dst):
    with open(src, 'rb') as f, open(dst, 'wb') as o:
        hdr = f.read(28)
        (magic, major, minor, fhs, chs, blk_sz, total_blk,
         total_chunks, crc) = struct.unpack('<IHHHHIIII', hdr)
        if magic != SPARSE_MAGIC:
            raise SystemExit(f"{src}: not a sparse image (magic {magic:#x})")
        print(f"{os.path.basename(src)}: block={blk_sz} blocks={total_blk} "
              f"chunks={total_chunks} raw_size={total_blk*blk_sz/2**30:.2f} GiB")
        if fhs > 28:
            f.seek(fhs - 28, 1)
        out = 0
        for i in range(total_chunks):
            ch = f.read(chs)
            ctype, _, csz, tsz = struct.unpack('<HHII', ch[:12])
            if chs > 12:
                f.seek(chs - 12, 1)
            n = csz * blk_sz
            if ctype == CHUNK_RAW:
                remaining = n
                while remaining:
                    b = f.read(min(1 << 22, remaining))
                    if not b:
                        raise SystemExit("truncated raw chunk")
                    o.write(b); remaining -= len(b)
                out += n
            elif ctype == CHUNK_FILL:
                fill = f.read(4)
                if fill == b'\x00\x00\x00\x00':
                    o.seek(n, 1)                       # hole
                else:
                    buf = fill * (blk_sz // 4)
                    for _ in range(csz):
                        o.write(buf)
                out += n
            elif ctype == CHUNK_DONTCARE:
                o.seek(n, 1)                           # hole
                out += n
            elif ctype == CHUNK_CRC32:
                f.seek(4, 1)
            else:
                raise SystemExit(f"unknown chunk type {ctype:#x} at {i}")
        o.truncate(total_blk * blk_sz)
    print(f"  -> {dst} ({out/2**30:.2f} GiB logical)")

if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
