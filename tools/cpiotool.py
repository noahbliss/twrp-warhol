#!/usr/bin/env python3
"""
cpiotool.py — read/modify/write Android newc cpio ramdisks *in memory*.

Why not `cpio -idm` + `find | cpio -o`: extracting to a filesystem loses
uid/gid and device nodes unless you are root, and macOS cannot create
/dev/console at all. Editing the archive in place keeps every entry byte-exact
except the ones you deliberately touch.

Commands:
  list    <cpio>
  cat     <cpio> <path>
  extract <cpio> <path> <dest>
  edit    <cpio> <out> [ops...]
          --add     <path>=<localfile>[:mode]   add or replace an entry
          --rm      <path>                      drop an entry (glob ok)
          --rmdir   <path>                      drop an entry and everything under it
          --patch   <path>=<pyfile>             rewrite entry data via patch(data)->data
          --append  <path>=<text>               append text to an existing entry
"""
import sys, os, io, fnmatch, struct, signal

# `cpiotool list | grep -q x` closes the pipe as soon as grep is satisfied, which
# makes Python raise BrokenPipeError and dump a traceback. Restore the default
# SIGPIPE behaviour so we just exit quietly like a normal unix filter.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

MAGIC = b'070701'
TRAILER = 'TRAILER!!!'
FIELDS = ('ino','mode','uid','gid','nlink','mtime','filesize',
          'devmajor','devminor','rdevmajor','rdevminor','namesize','check')

class Entry:
    __slots__ = ('name','data') + FIELDS
    def __repr__(self):
        return f"<{self.name} mode={self.mode:#o} uid={self.uid} gid={self.gid} size={len(self.data)}>"

def _pad4(n):
    return (4 - (n % 4)) % 4

def read(buf):
    """Parse a newc cpio into a list of Entry."""
    out, off = [], 0
    while off < len(buf):
        if buf[off:off+6] != MAGIC:
            # trailing zero padding after TRAILER!!!
            if buf[off:].strip(b'\0') == b'':
                break
            raise ValueError(f"bad cpio magic at {off}: {buf[off:off+6]!r}")
        e = Entry()
        vals = [int(buf[off+6+i*8: off+6+i*8+8], 16) for i in range(13)]
        for k, v in zip(FIELDS, vals):
            setattr(e, k, v)
        nstart = off + 110
        name = buf[nstart: nstart + e.namesize - 1].decode('utf-8', 'surrogateescape')
        e.name = name
        dstart = nstart + e.namesize
        dstart += _pad4(dstart)
        e.data = bytes(buf[dstart: dstart + e.filesize])
        off = dstart + e.filesize
        off += _pad4(off)
        if name == TRAILER:
            break
        out.append(e)
    return out

def write(entries):
    """Serialise entries (+ trailer) back to newc bytes."""
    o = io.BytesIO()
    def emit(e, data):
        nb = e.name.encode('utf-8', 'surrogateescape') + b'\0'
        hdr = MAGIC + b''.join(b'%08X' % v for v in (
            e.ino, e.mode, e.uid, e.gid, e.nlink, e.mtime, len(data),
            e.devmajor, e.devminor, e.rdevmajor, e.rdevminor, len(nb), 0))
        o.write(hdr); o.write(nb); o.write(b'\0' * _pad4(len(hdr) + len(nb)))
        o.write(data); o.write(b'\0' * _pad4(len(data)))
    for e in entries:
        emit(e, e.data)
    t = Entry()
    for k in FIELDS: setattr(t, k, 0)
    t.name, t.data, t.nlink = TRAILER, b'', 1
    emit(t, b'')
    # pad archive to 512 like GNU cpio does (harmless, keeps tools happy)
    while o.tell() % 512: o.write(b'\0')
    return o.getvalue()

def _new_like(entries, path, data, mode=0o100644):
    """Build an entry for `path`, inheriting ino/uid/gid conventions of the archive."""
    e = Entry()
    e.name = path.lstrip('/')
    e.data = data
    e.ino = max((x.ino for x in entries), default=0) + 1
    e.mode = mode
    e.uid = e.gid = 0
    e.nlink = 1
    e.mtime = 0
    e.filesize = len(data)
    e.devmajor = e.devminor = e.rdevmajor = e.rdevminor = 0
    e.namesize = len(e.name) + 1
    e.check = 0
    return e

def find(entries, path):
    p = path.lstrip('/')
    for e in entries:
        if e.name == p: return e
    return None

def main():
    if len(sys.argv) < 3: sys.exit(__doc__)
    cmd, src = sys.argv[1], sys.argv[2]
    entries = read(open(src, 'rb').read())

    if cmd == 'list':
        for e in entries:
            kind = {0o1: 'p', 0o2: 'c', 0o4: 'd', 0o6: 'b', 0o10: '-', 0o12: 'l', 0o14: 's'}.get(e.mode >> 12, '?')
            print(f"{kind} {e.mode & 0o7777:04o} {e.uid:>5} {e.gid:>5} {len(e.data):>9}  {e.name}"
                  + (f" -> {e.data.decode('utf-8','replace')}" if kind == 'l' else ''))
        return
    if cmd in ('cat', 'extract'):
        e = find(entries, sys.argv[3])
        if not e: sys.exit(f"not found: {sys.argv[3]}")
        if cmd == 'cat': sys.stdout.buffer.write(e.data)
        else: open(sys.argv[4], 'wb').write(e.data); print(f"wrote {sys.argv[4]} ({len(e.data)} B)")
        return
    if cmd != 'edit': sys.exit(__doc__)

    out = sys.argv[3]
    args = sys.argv[4:]
    i = 0
    while i < len(args):
        op = args[i]; val = args[i+1]; i += 2
        if op == '--add':
            path, _, rest = val.partition('=')
            local, _, mode = rest.partition(':')
            mode = int(mode, 8) if mode else 0o644
            data = open(local, 'rb').read()
            e = find(entries, path)
            if e:
                e.data = data; e.mode = (e.mode & 0o170000) | mode
                print(f"  [~] replace {path} ({len(data)} B)")
            else:
                entries.append(_new_like(entries, path, data, 0o100000 | mode))
                print(f"  [+] add {path} ({len(data)} B)")
        elif op in ('--rm', '--rmdir'):
            pat = val.lstrip('/')
            n0 = len(entries)
            if op == '--rmdir':
                entries = [e for e in entries if not (e.name == pat or e.name.startswith(pat + '/'))]
            else:
                entries = [e for e in entries if not fnmatch.fnmatch(e.name, pat)]
            print(f"  [-] {op} {pat}: dropped {n0 - len(entries)}")
        elif op == '--patch':
            path, _, pyf = val.partition('=')
            e = find(entries, path)
            if not e: sys.exit(f"--patch: not found: {path}")
            ns = {}
            exec(open(pyf).read(), ns)
            new = ns['patch'](e.data)
            print(f"  [*] patch {path}: {len(e.data)} -> {len(new)} B")
            e.data = new
        elif op == '--append':
            path, _, text = val.partition('=')
            e = find(entries, path)
            if not e: sys.exit(f"--append: not found: {path}")
            e.data = e.data + text.encode() + b'\n'
            print(f"  [>] append to {path}")
        else:
            sys.exit(f"unknown op {op}")
    blob = write(entries)
    open(out, 'wb').write(blob)
    print(f"wrote {out}: {len(entries)} entries, {len(blob)} B")

main()
