#!/usr/bin/env python3
"""
modules_dep_add.py — add entries to a ramdisk modules.dep for grafted modules.

WHY THIS EXISTS (learned the hard way, 2026-09-06):
Appending a module to modules.load.recovery is NOT enough. Android's init
resolves modules through libmodprobe, which looks each one up in modules.dep.
A module with no modules.dep entry cannot be resolved, and init treats that as
fatal:

    init: LoadWithAliases was unable to load xiaomi_touch_warhol
    init: Failed to load kernel modules
    Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00

...which is an instant bootloop. depmod normally writes these lines; we are
editing a prebuilt ramdisk, so we have to write them ourselves.

Each line is the module followed by its FULL transitive dependency closure,
which is what depmod emits:

    /lib/modules/foo.ko: /lib/modules/bar.ko /lib/modules/baz.ko

Usage:
  modules_dep_add.py <modules.dep-in> <modules.dep-out> <module.ko> [module.ko...]
Dependencies are read from each .ko's own `depends=` modinfo field, and the
closure is expanded using the existing modules.dep.
"""
import re, sys, os

PREFIX = "/lib/modules/"

def modinfo_depends(path):
    data = open(path, 'rb').read()
    for m in re.finditer(rb'depends=([^\x00]*)', data):
        val = m.group(1).decode('utf-8', 'replace')
        return [d for d in val.split(',') if d]
    return []

def main():
    src, dst = sys.argv[1], sys.argv[2]
    kos = sys.argv[3:]
    lines = open(src).read().splitlines()

    dep_of = {}
    order = []
    for ln in lines:
        if ':' not in ln:
            continue
        mod, _, rest = ln.partition(':')
        dep_of[mod.strip()] = rest.split()
        order.append(mod.strip())

    def closure(direct):
        """Full transitive closure, order-preserving, deduped."""
        out, seen = [], set()
        for d in direct:
            p = PREFIX + d + ".ko"
            if p not in seen:
                seen.add(p); out.append(p)
            for sub in dep_of.get(p, []):
                if sub not in seen:
                    seen.add(sub); out.append(sub)
        return out

    added = []
    for ko in kos:
        name = os.path.basename(ko)
        key = PREFIX + name
        direct = modinfo_depends(ko)
        deps = closure(direct)
        # a module we are adding may itself be a dependency of a later one
        dep_of[key] = deps
        if key in order:
            lines = [l for l in lines if not l.startswith(key + ":")]
        line = key + ":" + ("".join(" " + d for d in deps))
        lines.append(line)
        added.append((name, direct, len(deps)))

    open(dst, 'w').write("\n".join(lines) + "\n")
    for name, direct, n in added:
        print(f"  [dep] {name}: direct={direct or '(none)'} closure={n} modules")
    print(f"  modules.dep: {len(lines)} lines")

main()
