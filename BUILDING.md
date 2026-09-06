# Building

This also serves as the **corresponding-source record** for the GPL-3.0 TWRP
binaries in any released image — the exact inputs are pinned below.

## Sources

| component | source | revision |
|---|---|---|
| TWRP manifest | `https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp` | branch `twrp-14.1` |
| TWRP recovery | `https://github.com/TeamWin/android_bootable_recovery` | branch `android-14.1` (as pulled by the manifest) |
| device tree | this repository | the tagged commit of the release |
| local changes | `device/xiaomi/warhol/patches/` | applied by `patches/apply_patches.sh` |
| kernel | Google stock GKI, **unmodified**, taken from the device's own `boot.img` | `6.12.38-android16-5-g1d46253471dd-ab15048002-4k` |

The kernel is not built. `TARGET_NO_KERNEL := true`; the stock GKI image is reused
byte-for-byte, so there is no kernel source to provide beyond AOSP's
`common-android16-6.12`.

## Prerequisites

* An **x86_64 Linux** build host, or macOS with `colima` + Rosetta (see below).
  ~90 GB disk and **at least 24 GB RAM available to the builder**.
* A copy of the stock firmware for your device.

## Vendor binaries

None are committed. Extract them from your own firmware first:

```bash
./tools/extract-blobs.sh /path/to/warhol_global_images_OS3.0.x_16.0
```

## Build

```bash
./docker/build-env.sh up      # colima (vz + Rosetta) + the amd64 build image
./docker/build-env.sh sync    # repo init + sync twrp-14.1  (~60 GB, once, slow)
./docker/prune-tree.sh --go --aggressive    # AFTER sync: ~17 GB of unused toolchains
./docker/prune-tree.sh --go --drop-git      # ~57 GB of git objects; one-way
./docker/build-env.sh build   # lunch, mka, then repack
./tools/verify-image.sh       # 18 pre-flash checks
```

Produces `out/twrp_warhol-vendor_boot.img`.

## Things that will bite you

**`ALLOW_MISSING_DEPENDENCIES=true` is mandatory.** TWRP's manifest deliberately
omits projects that other retained projects reference, so Soong will not bootstrap
without it. It is AOSP's own mechanism for this
(`system/sepolicy/build/soong/validate_bindings.go` checks
`ctx.Config().AllowMissingDependencies()` before panicking). `build-env.sh` sets it.

**Do not "fix" bootstrap errors by deleting the complaining directory.** Deleting
a consumer often deletes module *definitions* other things need, and it cascades.
Removing `cts` alone turned 13 errors into 86 deletions here. Add the *provider*
back, or set the flag above.

**`mka vendorbootimage` does not build the system install set**, so
`task_profiles.json` — which `bootable/recovery/Android.mk` copies into the
recovery root — is never produced, and the build fails with
`cp: bad .../system/etc/task_profiles.json`. Adding it to `PRODUCT_PACKAGES` does
*not* help. Build it explicitly first (`build-env.sh` does):

```bash
mka task_profiles.json -j4
mka vendorbootimage   -j4
```

**Use `-j4`, not `-j$(nproc)`, under Rosetta.** At higher parallelism individual
clang processes die silently — a bare `FAILED:` with no compiler diagnostic, no OOM
in `dmesg`, no segfault, and the same file compiles fine by hand.

**Memory.** `soong_build` needs >20 GB for analysis; at 20 GB it is OOM-killed and
the log says only `Killed`. But do not starve the host either — a browser holding
several GB was enough to get builds killed from the *host* side. 24 GB to the VM on
a 36 GB machine, plus a swapfile in the VM, works.

**Disk.** A synced tree is ~60 GB, of which `.repo/project-objects` is ~57 GB of git
history the build never reads. `prune-tree.sh --drop-git` reclaims it, but only run
that once the sync reports clean — it is one-way (later syncs re-clone). And on
macOS, deleting inside the VM does not shrink the host disk image until you
`fstrim`; `prune-tree.sh` does it automatically.

## Repacking without a full build

The build output alone is not flashable — `TARGET_NO_KERNEL` means the vendor
kernel modules are absent. `patch_touch_warhol.sh` grafts the stock module ramdisk,
adds the Goodix touch modules, applies the THP patch, updates `modules.dep`, and
bakes in the device files:

```bash
./device/xiaomi/warhol/patch_touch_warhol.sh --twrp out/build/vendor_boot-fresh.img
```

It can also build an image from **another device's** released TWRP ramdisk
(`--twrp-ramdisk`), which is how this port was first bootstrapped before the native
build worked.
