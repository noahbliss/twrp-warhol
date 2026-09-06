# Flashing safely, and how to undo it

## Which partition are we actually flashing?

**`vendor_boot`.** Not `recovery`, not `boot`, not `init_boot`. Worth being blunt
about, because all four are easy to conflate:

| partition | contents | do we touch it? |
|---|---|---|
| `recovery_a/b` | — | **does not exist on warhol.** `grep -c "partition_name: recovery"` on the scatter returns 0. `fastboot flash recovery` would fail with "partition not found". |
| `boot_a/b` | GKI kernel only (`ramdisk_size = 0`) | no |
| `init_boot_a/b` | generic ramdisk — **this is what Magisk patches** | no |
| `vendor_boot_a/b` | vendor ramdisk + the `recovery` ramdisk fragment | **yes, this one** |

Recovery on this device is a *boot mode*, not a partition. The bootloader loads
the same `boot` + `init_boot` + `vendor_boot` every time and simply includes
`vendor_boot`'s second ramdisk fragment (the one named `recovery`) when
`androidboot.force_normal_boot` is absent. Stock's own `flash_all.sh` confirms
the partition set — it flashes `vendor_boot_ab`, `boot_ab` and `init_boot_ab`,
and there is no recovery line.

## Magisk is in `init_boot`, and we do not touch `init_boot`

The device is rooted with Magisk. On Android 13+ devices that have an
`init_boot` partition — warhol does — Magisk patches **`init_boot`**, not `boot`.

**So root survives flashing our image**, because we only write `vendor_boot`.
Nothing we flash overwrites the Magisk patch, and restoring stock `vendor_boot`
later does not disturb root either.

### But magiskinit *will* be present in the recovery ramdisk

This is the part worth understanding before flashing. From AOSP `bootimg.h`, the
bootloader's documented sequence for a vendor_boot v4 image is:

```
 3. load the vendor ramdisks at ramdisk_addr
 4. load the generic ramdisk immediately following the vendor ramdisk in memory
```

The ramdisks are concatenated cpio archives extracted in order, so **later
entries win** — which means the generic ramdisk from `init_boot` is extracted
**last** and its `/init` overrides `vendor_boot`'s. That is precisely why
patching `init_boot` gives Magisk control of boot, and it applies in *every* boot
mode, recovery included.

So on a recovery boot the `/init` that executes is **magiskinit**, not TWRP's.

That is a known-good arrangement rather than a problem, because magiskinit
explicitly detects a recovery ramdisk and gets out of the way — it restores the
original init from `/.backup/init` and execs it. Its detection keys on a recovery
binary being present in the ramdisk, and ours is: the TWRP fragment ships
`/system/bin/recovery` (2,164,464 B), and warhol's stock fragment 0 ships one
too. The resulting chain is:

```
magiskinit  ->  detects recovery, restores generic init  ->  first-stage init
            ->  execs /system/bin/init  ->  which is TWRP's init (fragment 1 wins
                over fragment 0 for that path; init_boot ships no /system/bin/init)
            ->  TWRP
```

**If TWRP does not boot, this is the first thing to rule out**, and there is a
clean way to do it: temporarily flash *stock* `init_boot` (we have it —
`fw/images/init_boot.img`), which removes Magisk from the equation entirely, then
restore the Magisk-patched one from the recon backup afterwards.

```bash
# rule Magisk out of a TWRP boot failure
fastboot flash init_boot_a fw/images/init_boot.img     # stock, un-patched
fastboot reboot recovery
# ... then put root back:
fastboot flash init_boot_a out/recon/<stamp>/images/init_boot_a.img
```

That is exactly why `warhol-recon.sh` backs up `init_boot_a`/`init_boot_b` before
anything else — that backup **is** your Magisk installation.

### One upside

Magisk on an unlocked Xiaomi effectively requires verity/verification already
disabled, so the `vbmeta` step below is very likely already done and can be
skipped. Check rather than assume — and skipping it is the low-risk choice, since
toggling verity can force a `/data` wipe.

## Correction: `vendor_boot` is *not* a recovery-only partition

The working assumption was "we can overwrite/restore recovery without impacting
the operation of the main ROM". That is *almost* right, and the gap is worth
knowing exactly.

warhol has **no `recovery` partition**. Recovery lives inside `vendor_boot`, which
has two ramdisk fragments:

| fragment | name | loaded on |
|---|---|---|
| 0 | `""` (platform) | **every boot — normal HyperOS and recovery** |
| 1 | `recovery` | recovery boot only |

So flashing `vendor_boot` *does* alter the normal HyperOS boot path. It is not
like the old days of a standalone `recovery` partition you could scribble on
freely.

**What this tree does about it**, so that the main ROM genuinely is unaffected:

* Fragment 1 is replaced wholesale. Recovery-only — no effect on normal boot.
* Fragment 0 is touched **additively only**:
  * two `.ko` files added (`xiaomi_touch_warhol.ko`, `goodix_core_warhol.ko`,
    ~780 KB total);
  * those two names appended to `lib/modules/**modules.load.recovery**`.
* `lib/modules/modules.load` — the list normal boot uses — **is not modified**.
  The repack verifies this; `patch_touch_warhol.sh` never writes to it, and the
  post-build check greps it to confirm zero touch entries.
* The byte-patched `xiaomi_touch_warhol.ko` only exists in the *ramdisk*. Normal
  HyperOS loads its `xiaomi_touch_warhol.ko` from the **`vendor_dlkm` partition**,
  which we never touch. So the running OS keeps the unpatched driver and normal
  touch behaviour.

### The one shared setting: `androidboot.selinux=permissive`

The repack appends this to the vendor_boot header's `vendor_cmdline`, and the
cmdline **is** shared between normal and recovery boot. TWRP needs it (its
recovery policy does not cover this vendor; degas and chagall both black-screened
without it).

This is safe here, and the reason is specific: AOSP `init` only honours
`androidboot.selinux=permissive` when `ALLOW_PERMISSIVE_SELINUX` is compiled in,
which happens on `userdebug`/`eng` builds only. Stock warhol is
`ro.build.type=user`, `ro.secure=1`, `ro.debuggable=0` — its init parses the flag
and then ignores it, staying enforcing. TWRP's own init is an `eng` build and
honours it.

Still: confirm after the first flash with `adb shell getenforce` on the **normal**
ROM. It must say `Enforcing`. If it ever says `Permissive`, stop and rebuild
without the flag.

> **CONFIRMED ON DEVICE 2026-09-06.** After running the custom `vendor_boot` and
> rebooting to HyperOS: `getenforce` = **Enforcing**, `boot_completed=1`,
> `ro.crypto.state=encrypted`, Magisk root working, and `/data` and installed
> apps untouched. TWRP itself reports `Permissive` in the same boot chain, so
> the flag *is* present and *is* being honoured by TWRP's eng init and ignored by
> the stock user-build init — exactly as predicted. The additive-only design
> holds: flashing `vendor_boot` left the normal OS untouched.

## Verified device state (fastboot, 2026-09-06) — read this before the loop below

```
product            warhol            unlocked        yes
current-slot       b                 secure          no
slot-successful:b  yes               anti            1     (== the OTA's anti_version)
slot-successful:a  no                lane            2
slot-retry-count:a 0                 max-fetch-size  (empty)
userdata           970 GiB           super           12.50 GiB
```

Four consequences, all of which changed the plan:

1. **The device runs from slot B, and slot B is the only working slot.** Slot A has
   never booted successfully and has zero retries left. An earlier draft of
   `recovery.fstab` pinned `_a` everywhere — copied from the OTA, whose
   `flash_all.sh` ends with `set_active a` — which was simply wrong for this unit
   and would have made TWRP back up and restore the dead slot. Fixed.

   This also corrects an earlier claim of mine that "slot B has no OS": that was
   true of the *OTA image* (every `*_b` logical partition in `super.img` is 0
   bytes), not of the device. On the device it is inverted — B is live.

2. **`lane: 2`, and `partition-size:userdata_stripe_0/1` come back empty — this
   unit is single-UFS, not dual.** `flash_all.sh` branches on `lane = 4` for the
   striped layout. The dual-UFS handling in `init.recovery.mt6993.rc` stays (it is
   exactly what stock does, and is a harmless no-op here: `userdata_setup` does
   nothing and the symlink fails with `EEXIST`), but on *this* phone `/data` is an
   ordinary `by-name/userdata`, 970 GiB, f2fs.

3. **`max-fetch-size` is empty — `fastboot fetch` is not supported.** Partitions
   cannot be read out in fastboot mode. **Backups require booting to Android with
   adb + root.** There is no fastboot-only path to a restore point.

4. **`unlocked: yes`, `secure: no`** — verification is already off, which is
   consistent with Magisk being installed. **Do not flash `vbmeta`.** It is not
   needed, and toggling verity can force a `/data` wipe.

### Which slot to flash, given "do not endanger the existing OS"

Flash **`vendor_boot_b`** — the active slot — *after* backing it up.

That sounds like the riskier choice and is actually the safer one:

* Flashing `vendor_boot_a` would be a no-op: the device boots slot B, so nothing
  would change and the "test" would silently fail.
* Making slot A active to test it there is *worse*: slot A has no working OS and
  zero retries, so a TWRP failure would leave the device unable to boot anything
  until someone gets back into fastboot and runs `set_active b`.
* Our `vendor_boot_b` differs from stock in a strictly additive way: fragment 1
  (recovery-only) is replaced, and fragment 0 gains two `.ko` files plus two lines
  in `modules.load.recovery`. **`modules.load` — the list normal boot reads — is
  byte-identical**, and `verify-image.sh` asserts that. Normal HyperOS boot reads
  the same files it does today.

So the exposure is: one partition changed, one backup taken beforehand, and a
one-command restore. That is the smallest blast radius available.

## The safe flash/restore loop

The `recon` script backs up `vendor_boot_a` and `vendor_boot_b` first, precisely
so this loop exists. Nothing below is one-way.

```bash
# 0. Recon + backup FIRST. Do not skip.
./tools/warhol-recon.sh
#    -> out/recon/<stamp>/images/vendor_boot_a.img  (your undo button)
#    -> out/recon/<stamp>/images/nv*, protect*, persist  (keep private, keep forever)

# 1. Verify what you are about to flash was built for THIS device
python3 tools/mkbootimg/unpack_bootimg.py \
    --boot_img out/twrp_warhol-vendor_boot.img --out /tmp/chk --format=mkbootimg
#    kernel_offset must be 0x80000000, ramdisk_offset 0xa3800000,
#    tags/dtb 0x87c80000. If they read 0x40000000/0x66f00000 you are holding a
#    chagall or degas image — DO NOT FLASH IT.

# 2. Flash the ACTIVE slot (b on this device — confirm, do not assume).
adb reboot bootloader
fastboot getvar current-slot          # expect b
fastboot flash vendor_boot_b out/twrp_warhol-vendor_boot.img
fastboot reboot recovery

# 3a. It booted -> check touch, ADB, partitions. Leave slot A alone; it has no
#     working OS, and mirroring TWRP there buys nothing.

# 3b. It did not boot -> restore, no harm done:
fastboot flash vendor_boot_b out/recon/<stamp>/images/vendor_boot_b.img
fastboot reboot

# 3c. It did not boot AND normal HyperOS now misbehaves -> restore vendor_boot_b
#     as above. Nothing else was written, so that is a complete undo.
```

### vbmeta

The repacked image has **no AVB footer**, so `vendor_boot` will fail verification
unless verity/verification are already disabled. On an already-unlocked, rooted
device this has very likely been done — check first, and only flash vbmeta if
needed:

```bash
fastboot getvar secure              # this device: "no" -> verification already off
# ONLY if it comes back "yes" on some future device:
# fastboot --disable-verity --disable-verification flash vbmeta fw/images/vbmeta.img
```

Flashing `vbmeta` is itself reversible (`recon` backs up `vbmeta_a`/`vbmeta_b`),
but on some configurations toggling verity forces a `/data` wipe — so **do not
flash vbmeta casually on a phone with data you care about**. Check `verity` state
first; if it is already disabled, skip this entirely.

## Hard rules

1. **Never `fastboot flashing lock` while a custom `vendor_boot` is flashed.**
   Instant hard brick. Restore every stock image first.
2. **Never flash a `chagall` or `degas` image.** Different SoC, different DTB,
   different load addresses.
3. **Never flash a package with a lower anti-rollback index.** This firmware is
   `anti_version = 1`. It is a one-way fuse.
4. **Never wipe/format `metadata`.** It makes `/data` unreadable to stock HyperOS
   too, not just to TWRP.
5. Keep `out/recon/<stamp>/images/` off the phone and off the internet — it
   contains IMEI, RF calibration and DRM keys.

## Testing without flashing?

There isn't a good one. `fastboot boot` takes a `boot.img`, not a `vendor_boot`,
so the ramdisk we care about cannot be side-loaded. Slot B is not a test bed
either — every `*_b` logical partition in `super` is currently 0 bytes, so slot B
has no OS to fall back to.

The flash-and-restore loop above *is* the test method. That is exactly why the
recon backup is step 0 and not optional.
