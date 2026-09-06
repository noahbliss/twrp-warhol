#!/usr/bin/env python3
"""
patch_thp_notifier.py — neuter the display->touch THP switch in a Xiaomi touch .ko

Xiaomi's touch framework module registers xiaomi_drm_panel_notifier_callback with
the DRM panel notifier. On a THP panel that callback flips the touch IC into
raw/THP mode (where coordinates are computed by a userspace HAL that does not
exist in recovery), so the kernel driver reports nothing and touch is dead.

Overwriting the callback's first two instructions with

    mov w0, wzr     ; NOTIFY_DONE
    ret

makes it a no-op that returns the correct value, so the IC stays in normal mode
and the driver reports input events itself. This is the degas/chagall fix, but
located by ELF symbol instead of a hardcoded offset, so it survives a module
rebuild.

Usage: patch_thp_notifier.py <module.ko> [--symbol NAME] [--check] [--force]
"""
import struct, sys, argparse

MOV_W0_WZR = 0x2a1f03e0
RET        = 0xd65f03c0

def find_symbol(d, want):
    if d[:4] != b'\x7fELF' or d[4] != 2:
        raise SystemExit("not a 64-bit ELF")
    e_shoff,   = struct.unpack_from('<Q', d, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from('<IIQQQQIIQQ', d, o)
        secs.append(dict(name=name, typ=typ, off=off, size=size, link=link,
                         info=info, entsize=entsize, idx=i))
    shstr = secs[e_shstrndx]
    def nm(tab, n):
        s = d[tab + n:]
        return s[:s.index(b'\0')].decode()
    for s in secs:
        s['n'] = nm(shstr['off'], s['name'])
    symtabs = [s for s in secs if s['n'] == '.symtab']
    if not symtabs:
        raise SystemExit("no .symtab (stripped module?)")
    st = symtabs[0]
    strtab = secs[st['link']]['off']
    for i in range(st['size'] // 24):
        o = st['off'] + i * 24
        nameoff, info, other, shndx = struct.unpack_from('<IBBH', d, o)
        value, size = struct.unpack_from('<QQ', d, o + 8)
        if nm(strtab, nameoff) == want:
            if shndx >= len(secs):
                raise SystemExit(f"{want}: bad section index {shndx}")
            sec = secs[shndx]
            return sec['off'] + value, size, sec['n'], sec['idx'], secs
    raise SystemExit(f"symbol {want!r} not found")

def relocs_in(d, secs, target_idx, lo, hi):
    """Any RELA/REL entries pointing into [lo,hi) of the target section?"""
    n = 0
    for s in secs:
        if s['info'] != target_idx:
            continue
        if s['typ'] == 4:      # SHT_RELA
            esz, cnt = 24, s['size'] // 24
        elif s['typ'] == 9:    # SHT_REL
            esz, cnt = 16, s['size'] // 16
        else:
            continue
        for i in range(cnt):
            off, = struct.unpack_from('<Q', d, s['off'] + i * esz)
            if lo <= off < hi:
                n += 1
    return n

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ko')
    ap.add_argument('--symbol', default='xiaomi_drm_panel_notifier_callback')
    ap.add_argument('--check', action='store_true', help='report only, do not write')
    ap.add_argument('--force', action='store_true', help='patch even if relocations overlap')
    a = ap.parse_args()

    d = bytearray(open(a.ko, 'rb').read())
    if d[-28:].find(b'Module signature appended') != -1:
        raise SystemExit("module is signed — patching would invalidate the signature")

    foff, size, secname, secidx, secs = find_symbol(d, a.symbol)
    w0, w1 = struct.unpack_from('<I', d, foff)[0], struct.unpack_from('<I', d, foff + 4)[0]
    print(f"  {a.symbol}")
    print(f"    section {secname}, file offset {foff} ({foff:#x}), size {size}")
    print(f"    current: {w0:#010x} {w1:#010x}")

    if (w0, w1) == (MOV_W0_WZR, RET):
        print("    already patched — nothing to do")
        return
    if size < 8:
        raise SystemExit(f"    function is only {size} bytes — refusing to patch")

    nrel = relocs_in(d, secs, secidx, foff - secs[secidx]['off'], foff - secs[secidx]['off'] + 8)
    if nrel:
        msg = f"    {nrel} relocation(s) point into the 8 bytes being replaced"
        if not a.force:
            raise SystemExit(msg + " — refusing (use --force if you are sure)")
        print(msg + " — proceeding due to --force")
    else:
        print("    no relocations overlap the patch site")

    if a.check:
        print("    --check: not writing")
        return
    struct.pack_into('<II', d, foff, MOV_W0_WZR, RET)
    open(a.ko, 'wb').write(d)
    print(f"    patched -> mov w0, wzr ; ret   ({MOV_W0_WZR:#010x} {RET:#010x})")

main()
