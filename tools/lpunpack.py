#!/usr/bin/env python3
"""Minimal liblp (super.img) reader/extractor. Usage: lpunpack.py super.raw [outdir] [names...]"""
import struct, sys, os

GEOM_MAGIC = 0x616C4467
HDR_MAGIC  = 0x414C5030
SECTOR     = 512

def cstr(b):
    return b.split(b'\x00', 1)[0].decode('utf-8', 'replace')

def read_meta(f):
    # LP_PARTITION_RESERVED_BYTES=4096, then primary+backup geometry (4096 each)
    geom_off = None
    for cand in (4096, 8192, 0):
        f.seek(cand); g = f.read(4096)
        if len(g) >= 8 and struct.unpack('<I', g[:4])[0] == GEOM_MAGIC:
            geom_off = cand; break
    if geom_off is None:
        raise SystemExit("no LP geometry found (is this a raw super image?)")
    max_size, slots, lbs = struct.unpack('<III', g[40:52])
    f.seek(4096 + 4096 * 2)
    h = f.read(max_size)
    (hmagic, maj, minr, hsz) = struct.unpack('<IHHI', h[:12])
    if hmagic != HDR_MAGIC:
        raise SystemExit(f"bad metadata header magic {hmagic:#x}")
    tables_size, = struct.unpack('<I', h[44:48])
    off = 80
    descs = {}
    for name in ('partitions', 'extents', 'groups', 'block_devices'):
        descs[name] = struct.unpack('<III', h[off:off+12]); off += 12
    base = hsz
    def table(name, size):
        o, n, esz = descs[name]
        return [h[base+o+i*esz: base+o+i*esz+esz] for i in range(n)]
    parts  = table('partitions', 52)
    exts   = table('extents', 24)
    groups = table('groups', 48)
    bdevs  = table('block_devices', 64)
    print(f"liblp v{maj}.{minr}  slots={slots}  logical_block_size={lbs}  metadata_max={max_size}")
    bd = []
    for b in bdevs:
        fls, align, aoff, size = struct.unpack('<IIIQ', b[:20])
        fls, = struct.unpack('<Q', b[:8])
        align, aoff = struct.unpack('<II', b[8:16])
        size, = struct.unpack('<Q', b[16:24])
        bd.append(dict(first_sector=fls, size=size, name=cstr(b[24:60])))
    for b in bd:
        print(f"  block_device {b['name']!r}: size={b['size']/2**30:.2f} GiB first_sector={b['first_sector']}")
    for g_ in groups:
        print(f"  group {cstr(g_[:36])!r} max={struct.unpack('<Q', g_[40:48])[0]/2**30:.2f} GiB")
    out = []
    for p in parts:
        name = cstr(p[:36])
        attrs, fei, nex, gi = struct.unpack('<IIII', p[36:52])
        e = []
        total = 0
        for i in range(fei, fei+nex):
            nsec, ttype = struct.unpack('<QI', exts[i][:12])
            tdata, tsrc = struct.unpack('<QI', exts[i][12:24])
            e.append((nsec, ttype, tdata, tsrc)); total += nsec
        out.append(dict(name=name, attrs=attrs, extents=e, size=total*SECTOR, group=cstr(groups[gi][:36])))
    return out, bd

def main():
    src = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else None
    want = set(sys.argv[3:])
    with open(src, 'rb') as f:
        parts, bd = read_meta(f)
        print(f"\n{len(parts)} logical partitions:")
        for p in parts:
            print(f"  {p['name']:<20} {p['size']/2**20:>10.2f} MiB  group={p['group']:<16} "
                  f"attrs={p['attrs']:#x} extents={len(p['extents'])}")
        if not outdir:
            return
        os.makedirs(outdir, exist_ok=True)
        for p in parts:
            if want and p['name'] not in want:
                continue
            dst = os.path.join(outdir, p['name'] + '.img')
            with open(dst, 'wb') as o:
                for nsec, ttype, tdata, tsrc in p['extents']:
                    n = nsec * SECTOR
                    if ttype == 0:
                        f.seek(tdata * SECTOR)
                        rem = n
                        while rem:
                            b = f.read(min(1 << 22, rem))
                            if not b: break
                            o.write(b); rem -= len(b)
                    else:
                        o.seek(n, 1)
                o.truncate(p['size'])
            print(f"  extracted {dst} ({p['size']/2**20:.2f} MiB)")

main()
