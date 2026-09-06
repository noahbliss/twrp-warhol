#
# BoardConfig.mk — LineageOS 23 for the Xiaomi 17T Pro (warhol / MT6993)
#
# Values are carried from the proven TWRP tree for this device, where they were
# each verified against the stock images or read off the device. Anything not yet
# confirmed for a LineageOS build is marked TODO(lineage).
#
DEVICE_PATH := device/xiaomi/warhol

# ── Arch ──────────────────────────────────────────────────────────────────────
# NOTE: warhol is 64-bit ONLY. Stock reports ro.vendor.product.cpu.abilist32 as
# EMPTY, so do not add a 2ND_ARCH here — there is no 32-bit userspace to match.
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a76
TARGET_SUPPORTS_64_BIT_APPS := true
TARGET_SUPPORTS_32_BIT_APPS := false
TARGET_USES_64_BIT_BINDER := true

# ── Platform ──────────────────────────────────────────────────────────────────
TARGET_BOARD_PLATFORM := mt6993
TARGET_BOOTLOADER_BOARD_NAME := warhol
TARGET_NO_BOOTLOADER := true

# ── Kernel — stock GKI, reused verbatim ───────────────────────────────────────
# boot.img carries Google's stock GKI 6.12.38-android16-5-g1d46253471dd-ab15048002-4k
# built by kleaf, with nothing device-specific compiled in: every board driver is
# a loadable module in vendor_dlkm. So there is no kernel to build.
TARGET_NO_KERNEL := true
BOARD_BOOT_HEADER_VERSION := 4
BOARD_VENDOR_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_PAGESIZE := 4096
BOARD_RAMDISK_USE_LZ4 := true
BOARD_KERNEL_BASE    := 0x00000000
BOARD_KERNEL_OFFSET  := 0x80000000
BOARD_RAMDISK_OFFSET := 0xa3800000
BOARD_TAGS_OFFSET    := 0x87c80000
BOARD_DTB_OFFSET     := 0x87c80000
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 bootconfig

# ── Partitions ────────────────────────────────────────────────────────────────
# Read from the device's own liblp metadata (v10.2): super is 13421772800 B and
# groups main_a/main_b are capped at 13411287040 B.
BOARD_SUPER_PARTITION_SIZE := 13421772800
BOARD_SUPER_PARTITION_GROUPS := xiaomi_dynamic_partitions
BOARD_XIAOMI_DYNAMIC_PARTITIONS_SIZE := 13411287040

# *** STRATEGY: keep the stock vendor. ***
# warhol is ro.treble.enabled=true at vendor API level 202504, and its stock
# vendor/odm/vendor_dlkm already implement all 150 HALs declared in VINTF —
# including ~40 vendor.xiaomi.* interfaces with no AOSP equivalent. Rebuilding
# that from 1647 extracted blobs (784 of them camera alone) is a large, fragile
# job for no benefit. So we build ONLY system/system_ext/product and leave
# vendor, odm and vendor_dlkm as the device shipped them.
#
# If you later decide to build vendor too, add it here AND to AB_OTA_PARTITIONS,
# and expect to do the full blob extraction.
BOARD_XIAOMI_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE     := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE    := ext4
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_PRODUCT    := product
TARGET_COPY_OUT_VENDOR     := vendor
BOARD_USES_METADATA_PARTITION := true

# ── A/B + Virtual A/B ─────────────────────────────────────────────────────────
# Confirmed on device: ro.virtual_ab.enabled=true, compression enabled.
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += system system_ext product
BOARD_USES_RECOVERY_AS_BOOT := false
PRODUCT_VIRTUAL_AB_OTA := true
PRODUCT_VIRTUAL_AB_COMPRESSION := true

# ── AVB ───────────────────────────────────────────────────────────────────────
# Flashed to a device with verification already disabled (see the TWRP tree's
# docs/FLASHING.md). Signing only what we build.
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_VBMETA_SYSTEM := system system_ext product
BOARD_AVB_VBMETA_SYSTEM_KEY_PATH := external/avb/test/data/testkey_rsa2048.pem
BOARD_AVB_VBMETA_SYSTEM_ALGORITHM := SHA256_RSA2048
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX := $(PLATFORM_SECURITY_PATCH_TIMESTAMP)
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX_LOCATION := 2

# ── Recovery ──────────────────────────────────────────────────────────────────
# warhol has NO recovery partition — recovery lives in vendor_boot. This build
# does not produce one; use the separately-maintained TWRP for this device.
# https://github.com/noahbliss/twrp-warhol
TARGET_NO_RECOVERY := true

# ── Security patch ────────────────────────────────────────────────────────────
VENDOR_SECURITY_PATCH := 2026-02-01
BOOT_SECURITY_PATCH   := 2026-02-01

# ── SELinux ───────────────────────────────────────────────────────────────────
include device/mediatek/sepolicy_vndr/SEPolicy.mk
BOARD_VENDOR_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/vendor

# ── HIDL/AIDL ─────────────────────────────────────────────────────────────────
DEVICE_MANIFEST_FILE := $(DEVICE_PATH)/manifest.xml
DEVICE_MATRIX_FILE   := device/mediatek/sepolicy_vndr/compatibility_matrix.xml

# TODO(lineage): confirm against a first build —
#   * whether device/mediatek/sepolicy_vndr exists in the LineageOS 23 manifest
#   * whether a DEVICE_MANIFEST_FILE is needed at all when vendor is kept stock
#     (the stock vendor already ships its own VINTF manifest fragments)
