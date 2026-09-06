# warhol — device facts

Everything here was read out of
`warhol_global_images_OS3.0.310.0.WPSMIXM_16.0`. Nothing is guessed; where a
value still needs on-device confirmation it says so.

## Identity

| | |
|---|---|
| Model | Xiaomi 17T Pro — `2602EPTC0G` |
| Codename | `warhol` (panel string `p12u`; the 17T is `chagall`/`P12A`) |
| SoC | MediaTek Dimensity 9500 — **MT6993** |
| Fingerprint | `Xiaomi/warhol_global/warhol:16/BP2A.250605.031.A3/OS3.0.310.0.WPSMIXM:user/release-keys` |
| Android | 16 (SDK 36), HyperOS 3.0, security patch 2026-02-01 |
| Kernel | **GKI 6.12.38-android16-5-g1d46253471dd-ab15048002-4k**, 4 K pages |
| `ro.hardware` | `mt6993` (from base DTB bootargs) |
| CPU | 8 cores, all-big: 4 × dmips 793, 3 × 952, 1 × 1024 |
| Display | 1280 × 2772, panel `p12u_42_02_0a_dsc_cmd` |
| Touch | Goodix **GT9895**, DT `compatible = "xiaomi,touch-spi"`, **THP mode** |
| Storage | UFS, **dual-die** (two UFS host controllers) |
| USB gadget | UDC `16751000.usb0` |
| Backlight | `/sys/class/leds/lcd-backlight/brightness` (max TBD on device) |

The kernel is a stock Google GKI build — `kleaf@build-host`, ab15048002 — with
**nothing device-specific compiled in**. Everything board-specific is a loadable
module. That is why `TARGET_NO_KERNEL := true` works and we never need to build
or even obtain kernel source for TWRP.

## Boot layout — A/B, GKI v4, no recovery partition

```
boot_a/b        64 MiB  header v4, kernel only (18 MiB lz4), ramdisk_size = 0
init_boot_a/b    8 MiB  header v4, generic ramdisk only (3 MiB lz4), kernel_size = 0
vendor_boot_a/b 64 MiB  header v4, TWO ramdisk fragments + dtb + bootconfig
dtbo_a/b         8 MiB  dt_table, 1 entry
```

There is **no `recovery_a` / `recovery_b`** in the scatter. Recovery lives in
`vendor_boot`, whose ramdisk table is:

| # | type | name | compressed | contents |
|---|---|---|---|---|
| 0 | `0x1` platform | `""` | 36,638,170 B | 295 kernel modules, full toybox/adbd userspace, `/system/bin/recovery`, `fstab.mt6993` |
| 1 | `0x2` recovery | `recovery` | 16,036,595 B | MiRecovery resources, `fstab.emmc` + `fstab.raid`, `init.recovery.mt6993.rc`, recovery sepolicy |

**TWRP replaces fragment 1 and augments fragment 0.** Nothing else needs to change.

### vendor_boot header geometry (from `unpack_bootimg --format=mkbootimg`)

```
--header_version 4 --pagesize 0x1000 --base 0x00000000
--kernel_offset 0x80000000 --ramdisk_offset 0xa3800000
--tags_offset 0x87c80000 --dtb_offset 0x87c80000
--vendor_cmdline 'bootopt=64S3,32N2,64N2 bootconfig'
```

These differ from degas (mt6897) and chagall (mt6899). Do not copy theirs.

The `dtb` blob inside `vendor_boot` is an **MTK `dt_table`** (magic `0xd7b7ab1e`,
1 entry, 649,548 B), not a bare `d00dfeed` FDT. `mkbootimg` packs it opaquely, so
it ships as-is at `prebuilt/dtb/warhol.dtb`.

## super.img — liblp v10.2, 12.5 GB

`BOARD_SUPER_PARTITION_SIZE = 13421772800`, groups `main_a`/`main_b` max
`13411287040`. Members (slot A populated, slot B empty):

| partition | size |
|---|---|
| `product_a` | 3275.34 MiB |
| `odm_a` | 1910.08 MiB |
| `vendor_a` | 1669.82 MiB |
| `mi_ext_a` | 1072.02 MiB |
| `system_ext_a` | 903.65 MiB |
| `system_a` | 842.58 MiB |
| `vendor_dlkm_a` | 24.70 MiB |
| `system_dlkm_a` | 7.63 MiB |
| `odm_dlkm_a` | 0.33 MiB |

All EROFS. `mi_ext` and `system_dlkm` are excluded from
`BOARD_..._PARTITION_LIST` because the TWRP 14.1 base's `config.mk` rejects those
names; they are mounted through `recovery.fstab` instead.

## Dual-UFS `/data` — supported by the platform, but NOT on this unit

> **Measured on the actual phone (fastboot, 2026-09-06): `lane: 2`, and
> `partition-size:userdata_stripe_0` / `_1` both come back empty. This unit is
> SINGLE-UFS.** `/data` is an ordinary `by-name/userdata`, 970 GiB, f2fs — a 1 TB
> device. `flash_all.sh` branches on `lane = 4` for the striped layout, so it
> would flash plain `userdata.img` here.
>
> The handling below stays in `init.recovery.mt6993.rc` because it is exactly what
> stock does unconditionally, and it is a harmless no-op on a single-UFS unit
> (`userdata_setup` does nothing; the symlink fails with `EEXIST` because a real
> `by-name/userdata` already exists). It matters for other warhol units, not this
> one.

### How it works on a dual-UFS unit

The scatter has `userdata`, **and also** `userdata_stripe_0` (UFS_LU2, 1536 MiB
placeholder), `userdata_stripe_1` (UFS_LU0) and `userdata_rem` (UFS_LU0). The
base DTB has **two** UFS host controllers: `ufshci@16810000` and
`ufshci@16890000`.

`flash_all.sh` branches on `fastboot getvar lane`; `lane = 4` means two dies and
it flashes the two stripe images instead of `userdata.img`.

At boot, `/system/bin/userdata_setup` (MTK, `external/ufs_util`) builds a
**dm-stripe** across `userdata_stripe_0` + `userdata_stripe_1` plus a linear
`userdata_rem` tail, chunk size from `ro.vendor.mtk_ufs_stripe_size`, and names it
`/dev/block/mapper/mtk_userdata`. Stock `init.recovery.mt6993.rc` then does:

```
on fs
    exec u:r:recovery:s0 root root -- /system/bin/userdata_setup
    symlink /dev/block/mapper/mtk_userdata /dev/block/by-name/userdata
```

On a single-die unit `userdata_setup` is a no-op and the symlink fails with
`EEXIST`, which is why stock runs it unconditionally.

**This must be reproduced in TWRP.** Without it `/data` is invisible, and — worse
— a "wipe" would land on only one of the two stripes. It is in our
`recovery/root/init.recovery.mt6993.rc`. Neither degas nor chagall has this;
it is warhol's own hazard.

## Touch

* IC: Goodix GT9895 on SPI.
* `goodix_core_warhol.ko` — matches DT `compatible = "xiaomi,touch-spi"`,
  `depends = xiaomi_touch_warhol`.
* `xiaomi_touch_warhol.ko` — the Xiaomi touch framework, exposes
  `/sys/class/touch/touch_dev/{enable_touch_raw,panel_display}` and
  `/dev/xiaomi-touch`. `depends = mediatek-drm, miev` (both already in the stock
  recovery module list).
* `gt9895.ko` — legacy `platform:mtk-tpd3` path, `goodix,nottingham`; **not used**
  by this board's DT. Deliberately excluded.
* Firmware: `/odm/firmware/goodix_firmware_warhol.bin`,
  `goodix_cfg_group_warhol.bin`. Stock cmdline sets
  `firmware_class.path=/vendor/firmware,/odm/firmware`, so we bake both files at
  `/vendor/firmware` and `/lib/firmware` in the ramdisk.
* THP: `/odm/firmware/warhol_gtp_thp_config.ini`,
  `/odm/bin/hw/vendor.xiaomi.hw.touchfeature-service`, `libtouchreport_alg.so`,
  `libtensorflowlite_touch_c.so`.

**None of the touch modules are in the stock recovery ramdisk** —
`modules.load.recovery` (281 entries) has no touch driver at all, because
MiRecovery is key-driven. We add them.

## Kernel module loading

Every vendor module — in the boot ramdisk *and* in `vendor_dlkm` — carries
`vermagic=6.12.38-android16-5-gec2f49dacfeb-4k SMP preempt mod_unload modversions
aarch64`, which differs from the GKI kernel's own uname
(`…-g1d46253471dd-ab15048002-4k`). The kernel accepts them anyway (Android GKI
compares the KMI generation, not the git SHA). So the `vendor_dlkm` touch modules
load fine when grafted into the recovery ramdisk.

**Modules are not signed** (1 of 287 in `vendor_dlkm`, 2 of 290 in the ramdisk
match the signature trailer, i.e. noise), so binary-patching a `.ko` is safe.

## Encryption — see `03-encryption-and-data.md`

`/data` is F2FS with FBE `aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized`,
`fsverity`, **plus** metadata encryption
(`keydirectory=/metadata/vold/metadata_encryption` → `dm-default-key`).
