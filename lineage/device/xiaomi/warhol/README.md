# LineageOS 23 device tree for the Xiaomi 17T Pro (`warhol`)

**Status: scaffold. Not yet built, not yet booted.** This is the starting point,
with everything already established about the device baked in.

Target: **LineageOS 23.x** (Android 16). Check it out at
`device/xiaomi/warhol` in a `lineage-23.x` source tree.

## The strategy, and why

**Build only `system` / `system_ext` / `product`. Keep the stock vendor.**

warhol is `ro.treble.enabled=true` at vendor API level `202504`, and its stock
`vendor` / `odm` / `vendor_dlkm` already implement all **150 HALs** declared in
VINTF — roughly 30 `vendor.mediatek.*` and 40 `vendor.xiaomi.*` interfaces, most
with no AOSP equivalent at all. Rebuilding that from extracted blobs means
carrying **1647 files**, of which **784 are camera alone**:

| subsystem | files | | subsystem | files |
|---|---|---|---|---|
| Camera | 784 | | Wi-Fi / BT | 101 |
| Firmware | 289 | | Audio | 88 |
| Power / thermal | 112 | | NPU / APU | 77 |
| Radio / modem | 55 | | GPU / display | 49 |
| NFC / SE | 34 | | Sensors | 26 |
| Fingerprint | 15 | | Vibrator | 10 |
| IR blaster | 7 | | | |

Keeping the stock vendor avoids all of it, and is what most modern MediaTek
Lineage ports do. `proprietary-files.txt` is therefore best read as an
**inventory** — a map of what exists and what each piece is for — rather than a
copy list. Regenerate it with `tools/gen-proprietary-files.sh` from the TWRP repo.

There is also no kernel to build: `boot.img` carries Google's stock GKI
(`6.12.38-android16-5`) with every board driver as a loadable module in
`vendor_dlkm`, so `TARGET_NO_KERNEL := true` and the stock image is reused
verbatim. This is already proven — the TWRP build for this device does exactly
that and boots.

## What is already known

Measured on hardware, not assumed:

```
SoC            MediaTek Dimensity 9500 (mt6993), 8 cores, all-big
Display        1280x2772, density 520
Storage        UFS (single-die on the test unit; the platform supports dual)
/data          F2FS, FBE + metadata encryption (dm-default-key)
Partitions     A/B, dynamic; super 12.5 GB, group cap 12.49 GB
               NO recovery partition — recovery lives in vendor_boot
Kernel         stock GKI 6.12.38-android16-5, reused as-is
Touch          Goodix GT9895, THP mode
Fingerprint    Goodix FOD — location 535,2413  size 210,210
IR blaster     present (consumerir.common.so + android.hardware.ir-service.example)
Wi-Fi/BT       MT6653 combo
NFC            NXP SN100U, with eSE
GPU            Mali-G1-Ultra MC12 (Immortalis), driver v1.r54p1
NPU            MediaTek NeuroPilot / APU — the camera ML models run on it
```

A **GSI smoke test was run first** and is worth knowing about: LineageOS 23.2
GSIs (both ext4 and EROFS) install fine via DSU but fail to boot, with `odsign`
crash-looping ~8 times before boot completes. Importantly there were **no VINTF
failures, no missing-HAL errors and no SELinux denials** — so warhol's vendor
interface does not appear to reject a generic system. The failure was one named
userspace service. That is part of why a real device tree looks more promising
than a GSI here.

## Files

```
BoardConfig.mk        arch, kernel geometry, partitions, AVB, the keep-stock-vendor decision
device.mk             product packages, screen, API levels
lineage_warhol.mk     product definition (lunch lineage_warhol-bp2a-userdebug)
AndroidProducts.mk    lunch choices
proprietary-files.txt blob INVENTORY (1647 entries, grouped by subsystem)
```

## Known TODOs before this can build

Marked `TODO(lineage)` in the makefiles:

* Confirm `device/mediatek/sepolicy_vndr` exists in the LineageOS 23 manifest, and
  whether a `DEVICE_MANIFEST_FILE` is needed at all when the stock vendor is kept
  (it already ships its own VINTF fragments).
* Decide whether any `rootdir` init additions are needed — the stock
  `init.mt6993.rc` still runs when vendor is kept.
* Wire the FOD values into an overlay.
* First build will surface more. Expect it to.

## Related

* TWRP for this device, and the full device documentation:
  <https://github.com/noahbliss/twrp-warhol>
