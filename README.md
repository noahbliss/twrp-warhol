# TWRP for the Xiaomi 17T Pro (`warhol`)

Unofficial TWRP recovery for the **Xiaomi 17T Pro** — codename `warhol`,
MediaTek Dimensity 9500 (`mt6993`), HyperOS 3 / Android 16.

> **Status: working.** Boots, touch works, ADB and MTP work, partitions mount.
> Built and tested against `OS3.0.310.0.WPSMIXM`.

---

## ⚠️ Read this before you flash

**1. `warhol` has no `recovery` partition.** Recovery lives inside `vendor_boot`.
`fastboot flash recovery` will fail — the partition does not exist. You flash
`vendor_boot`.

**2. Flash the slot your device is actually on.** Check with
`fastboot getvar current-slot`. Flashing the inactive slot silently does nothing.

**3. `fastboot reboot recovery` leaves a sticky flag.** It writes a
`boot-recovery` command into the `misc` partition, and **that flag persists**, so
the device will keep booting into recovery until something clears it. If you end
up in a recovery loop:

> Hold **Power** for 15–20 s to force off, then boot normally. A successful
> Android boot clears the flag. To avoid it entirely, leave TWRP with its own
> **Reboot → System** menu rather than pulling the battery or `fastboot reboot`.

This is normal Android A/B behaviour, not a bug in this build — but it surprises
people, so it is called out here.

**4. TWRP cannot decrypt `/data` on this device — with or without your PIN.**
Not a missing feature; see [Encryption](#encryption) below and
[`docs/ENCRYPTION.md`](docs/ENCRYPTION.md).

**5. Back up first.** `tools/warhol-recon.sh` saves your `vendor_boot`,
`init_boot` (**your Magisk install — often the only copy**) and the
irreplaceable `nvdata` / `nvcfg` / `protect1` / `protect2` / `persist` partitions,
which hold IMEI and RF calibration.

---

## Requirements

* Xiaomi 17T Pro (`warhol`) with an **unlocked bootloader**
* Verified boot already disabled — `fastboot getvar secure` should say `no`
  (it will be, if you have Magisk installed)
* `adb` and `fastboot` on your computer

## Install

```bash
# 0. Back up. Not optional — this is what makes step 2 reversible.
./tools/warhol-recon.sh

# 1. Confirm your slot
adb reboot bootloader
fastboot getvar current-slot          # note whether it says a or b

# 2. Flash TWRP to THAT slot
fastboot flash vendor_boot_b twrp_warhol-vendor_boot.img     # or _a
fastboot reboot recovery
```

**Do not flash `vbmeta`.** It is not needed on an already-unlocked device, and
toggling verity can force a `/data` wipe.

Full procedure, including the irreversible actions to avoid, is in
[`docs/FLASHING.md`](docs/FLASHING.md).

### Going back to stock

```bash
fastboot flash vendor_boot_b out/recon/<timestamp>/images/vendor_boot_b.img
fastboot reboot
```

## What works

| | |
|---|---|
| Boot, display, TWRP GUI | ✅ |
| **Touch** | ✅ Goodix GT9895 |
| ADB, MTP | ✅ |
| Partition mounting, flashing zips, wiping | ✅ |
| A/B slot switching | ✅ built in (direct `misc` write) — untested on hardware |
| **Decrypting `/data`** | ❌ impossible on this device — see below |
| Backup to internal storage | ❌ storage *is* `/data`; use `/cache` or OTG |
| USB-OTG (host mode) | ❓ untested |

### Encryption

`/data` is F2FS with FBE **plus** metadata encryption (`dm-default-key`). The
metadata key is **not derived from your password** — it is wrapped by KeyMint and
bound to the Verified Boot Root of Trust, which differs under a custom recovery.
The TEE therefore refuses the key with `INVALID_KEY_BLOB`.

This was chased all the way to KeyMint on the closely-related Xiaomi 14T: the
entire software chain can be made to work in recovery and it *still* fails, purely
on the hardware Root-of-Trust binding.
([research](https://github.com/Advnirr/twrp_device_xiaomi_degas/blob/fbe-decryption-research/docs/RESEARCH.md))

**Practical upshot:** back up from a *rooted, booted* HyperOS instead — it reads
`/data` decrypted natively, which TWRP fundamentally cannot.
`tools/warhol-data-backup.sh` does exactly that.

## Touch — how it was made to work

The panel is a Goodix **GT9895** in **THP** mode: the kernel driver normally ships
only raw capacitance frames, and a userspace HAL on `odm`
(`vendor.xiaomi.hw.touchfeature-service` + TensorFlow Lite) computes the finger
coordinates. That HAL does not exist in recovery, so touch is dead by default.

Two changes together fix it, and nothing else is needed:

1. **`enable_touch_raw 0`** in `init.recovery.mt6993.rc`.
2. An **8-byte patch** to `xiaomi_touch_warhol.ko`, neutering
   `xiaomi_drm_panel_notifier_callback` (`mov w0, wzr; ret`) so the display driver
   cannot flip the IC back into THP/doze mode. Located by ELF symbol, so it
   survives a module rebuild — see `tools/patch_thp_notifier.py`.

The kernel driver then reports coordinates directly on `event1 goodix_ts`.

## Building

See **[BUILDING.md](BUILDING.md)**. Short version: a `linux/amd64` container, the
TWRP `twrp-14.1` minimal manifest, `ALLOW_MISSING_DEPENDENCIES=true`, and
`tools/extract-blobs.sh` to pull the vendor binaries from your own firmware.

## Repository layout

```
device/xiaomi/warhol/    the device tree
tools/                   host tooling, pure Python/bash, macOS + Linux
  warhol-recon.sh          read-only device recon + partition backup
  warhol-data-backup.sh    /data backup from the running rooted OS
  warhol-hw-inventory.sh   HAL/blob inventory (for LineageOS work)
  extract-blobs.sh         pull vendor binaries from stock firmware
  verify-image.sh          18 pre-flash checks; refuses a wrong-device image
  patch_thp_notifier.py    the touch fix
  cpiotool.py              in-memory cpio editor (keeps uid/gid + device nodes)
  simg2img.py lpunpack.py  sparse and super.img readers
docker/                  reproducible linux/amd64 build environment
docs/                    reference
  DEVICE.md                partition layout, dual-UFS /data, touch stack, kernel
  FLASHING.md              safe flash/restore loop and the irreversible actions
  ENCRYPTION.md            why TWRP cannot decrypt /data here
  LINEAGEOS.md             HAL/blob inventory and GApps planning for future work
```

[`docs/DEVICE.md`](docs/DEVICE.md) is the useful one if you are porting to a
related device — partition layout, the dual-UFS `/data` handling, and how the
touch stack fits together.

## Credits

* **[Advnirr](https://github.com/Advnirr)** — the
  [`degas`](https://github.com/Advnirr/twrp_device_xiaomi_degas) (Xiaomi 14T) and
  [`chagall`](https://github.com/Advnirr/twrp_device_xiaomi_chagall) (Xiaomi 17T)
  trees. The THP touch neuter, the `Set_Active_Slot` misc-write patch and the FBE
  research are theirs; this port would have taken far longer without them.
* **[TeamWin](https://github.com/TeamWin)** — TWRP itself.

## Licence

Apache-2.0 for this tree, GPL-3.0-or-later for `patches/`, and no vendor binaries
are redistributed here. Details in **[LICENSING.md](LICENSING.md)**.
