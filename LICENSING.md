# Licensing

This repository mixes three things with different licences. They are kept
separate deliberately.

## 1. This device tree and its tooling — Apache-2.0

`device/`, `tools/`, `docker/`, `docs/` are original work here, following the
AOSP convention for device trees. See [`LICENSE`](LICENSE).

## 2. `patches/` — GPL-3.0-or-later

`device/xiaomi/warhol/patches/bootable/recovery/*.patch` modifies TWRP's
`bootable/recovery`, whose own code is **GPL-3.0-or-later**
(`twrp.cpp`: *"either version 3 of the License, or (at your option) any later
version"*, Copyright 2012-2020 TeamWin). A patch to GPL-3.0 code is a derivative
work of it, so those patches are GPL-3.0-or-later regardless of the licence on
the rest of this repo.

The `Set_Active_Slot` patch originates from
[Advnirr's degas tree](https://github.com/Advnirr/twrp_device_xiaomi_degas) and
is carried here with attribution.

## 3. Vendor binaries — NOT redistributed here

The build needs proprietary Xiaomi / MediaTek / Goodix binaries: the stock
`boot.img` and `vendor_boot.img`, the board DTB, the Goodix touch kernel modules
and their firmware.

**None of them are committed to this repository.** They are `.gitignore`d and
extracted from your own copy of the stock firmware:

```bash
./tools/extract-blobs.sh /path/to/warhol_global_images_OS3.0.x_16.0
```

## Note on released images

A built `vendor_boot.img` necessarily contains:

* **TWRP binaries** — GPL-3.0-or-later. The corresponding source is the TWRP
  minimal manifest plus this device tree plus `patches/`; exact revisions are
  recorded in [`BUILDING.md`](BUILDING.md), which is how the source-provision
  obligation is met.
* **Xiaomi / MediaTek / Goodix binaries** — the stock GKI kernel, 292 vendor
  kernel modules and the Goodix touch firmware, all taken unmodified from the
  device's own firmware.

That second category is vendor property. Anyone flashing a release is expected to
already own a warhol and be entitled to that firmware. If you would rather not
rely on someone else's build, `extract-blobs.sh` + `BUILDING.md` reproduce it
from your own device's firmware.

## Kernel source

The kernel is Google's stock GKI (`6.12.38-android16-5`), unmodified — source is
in AOSP's `common-android16-6.12` branch. Xiaomi has **not** published warhol's
vendor kernel module sources as of 2026-09-06; the only related branch on
`MiCode/Xiaomi_Kernel_OpenSource` is `bsp-chagall-w-oss` (the Xiaomi 17T). That is
Xiaomi's obligation, not something this repository can satisfy.
