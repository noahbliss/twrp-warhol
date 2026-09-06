#!/usr/bin/env python3
"""
rebrand_ramdisk.py — make a ported TWRP ramdisk identify as THIS device.

When the TWRP userspace is borrowed from another device's released build (the
--twrp-ramdisk path), every build property still names that device. On warhol the
borrowed chagall build reported `ro.product.device=chagall`,
`ro.build.fingerprint=Xiaomi/twrp_chagall/chagall:...` and
`ro.twrp.version=3.7.1_12-Advnirr` across ~30 properties. That is wrong on the
device, confusing in logs, and makes TWRP name its backup folders after the wrong
phone.

Two things are rewritten:
  1. prop.default   — textual, straightforward.
  2. system/bin/recovery — TWRP compiles TW_DEVICE_VERSION into the binary, so the
     version string is patched in place. Only ever shortened and NUL-padded, never
     lengthened, so offsets and the ELF stay valid.

ATTRIBUTION: this changes what the *device* calls itself. It does not erase credit.
The TWRP userspace here is Advnirr's build for chagall, and that is stated plainly
in README.md and README.md. Rebranding device identity while keeping
provenance in the docs is the honest split. The permanent fix is building from
source, where TW_DEVICE_VERSION is simply ours.

Usage: rebrand_ramdisk.py <cpio-in> <cpio-out> <device> <twrp_device_version>
"""
import sys, os, re, importlib.util

def load_cpiotool():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cpiotool.py')
    src = open(p).read().replace('\nmain()\n', '\n')
    ns = {'__name__': 'c'}
    exec(src, ns)
    return ns

def main():
    src, dst, device, twrpver = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    c = load_cpiotool()
    entries = c['read'](open(src, 'rb').read())

    # ---- 1. prop.default -----------------------------------------------------
    changed_props = 0
    for name in ('prop.default', 'default.prop', 'system/etc/prop.default'):
        e = c['find'](entries, name)
        if not e or not e.data:
            continue
        text = e.data.decode('utf-8', 'replace')
        before = text
        # Any foreign codename -> ours. Detect it from the props themselves rather
        # than hardcoding, so this works for a ramdisk borrowed from any device.
        m = re.search(r'^ro\.product\.system\.device=(\S+)', text, re.M)
        foreign = m.group(1) if m else None
        if foreign and foreign != device:
            text = text.replace(f'twrp_{foreign}', f'twrp_{device}')
            text = re.sub(rf'\b{re.escape(foreign)}\b', device, text)
        # build identity -> neutral + ours
        text = re.sub(r'^(ro\.build\.user)=.*$',  r'\1=warhol', text, flags=re.M)
        text = re.sub(r'^(ro\.build\.host)=.*$',  r'\1=localhost', text, flags=re.M)
        # eng.mikhai.20260613.130003 -> eng.warhol   (whole token, not a prefix)
        text = re.sub(r'eng\.[a-z0-9]+(?:\.\d+)+', f'eng.{device}', text)
        text = re.sub(r'\b[a-z]+\d{8,}\b', f'eng.{device}', text)
        if text != before:
            e.data = text.encode()
            changed_props = sum(1 for a, b in zip(before.splitlines(), text.splitlines()) if a != b)
            print(f"  [rebrand] {name}: {changed_props} properties rewritten"
                  + (f" ({foreign} -> {device})" if foreign else ""))

    # ---- 2. compiled-in TWRP version ----------------------------------------
    # TW_DEVICE_VERSION is baked into MORE THAN ONE binary: system/bin/recovery
    # AND system/bin/twrp (the openrecoveryscript CLI) both carry it, and an
    # earlier version of this script only patched the first, so `twrp --help`
    # still announced the foreign maintainer. Scan every executable.
    targets = [e for e in entries
               if (e.mode & 0o170000) == 0o100000 and e.data[:4] == b'\x7fELF'
               and (e.name.startswith('system/bin/') or e.name.startswith('sbin/'))]
    for e in targets:
        data = bytearray(e.data)
        pat = re.compile(rb'(\d+\.\d+\.\d+_\d+)-([A-Za-z0-9_.-]{1,32})\x00')
        hits = list(pat.finditer(bytes(data)))
        touched = False
        for m in hits:
            base = m.group(1).decode()
            old = m.group(0)[:-1].decode()
            new = f"{base}-{twrpver}"
            if new == old:
                continue
            if len(new) > len(old):
                print(f"  [rebrand] SKIP {e.name}: {old!r} -> {new!r} is longer")
                continue
            buf = new.encode() + b'\x00' * (len(old) - len(new) + 1)
            data[m.start():m.start() + len(buf)] = buf
            print(f"  [rebrand] {e.name} @{m.start()}: {old} -> {new}")
            touched = True
        if touched:
            e.data = bytes(data)

    open(dst, 'wb').write(c['write'](entries))
    print(f"  [rebrand] wrote {dst}")

main()
