#
# BoardConfig.mk — Xiaomi 17T Pro (warhol), MediaTek Dimensity 9500 (mt6993)
#
# Every value below is either derived from the stock OS3.0.310.0.WPSMIXM images
# (marked "stock:") or carried from the degas/chagall trees (marked "carried:").
# Nothing here is guessed; anything still unverified is marked TODO(device).
#
DEVICE_PATH := device/xiaomi/warhol

# ── Arch ──────────────────────────────────────────────────────────────────────
# stock: base DTB /cpus has 8 cores in 3 tiers (capacity-dmips-mhz 0x319 x4,
# 0x3b8 x3, 0x400 x1) — Dimensity 9500 is all-big (C1-Pro/Premium/Ultra), no A5xx.
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a76
TARGET_SUPPORTS_64_BIT_APPS := true

# stock: ro.vendor.product.cpu.abilist32 is EMPTY — this is a 64-bit-only device.
# The 2ND_ARCH block is kept because the TWRP 14.1 base still expects it, but no
# 32-bit code is built or shipped.
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a76

# ── Platform ──────────────────────────────────────────────────────────────────
# stock: bootargs androidboot.hardware=mt6993 (base DTB /chosen); scatter project=warhol
TARGET_BOARD_PLATFORM := mt6993
TARGET_BOOTLOADER_BOARD_NAME := warhol

# ── Kernel (GKI v4, prebuilt) ─────────────────────────────────────────────────
# stock: boot.img kernel is Google GKI 6.12.38-android16-5-g1d46253471dd-ab15048002-4k,
# built by kleaf. Nothing device-specific is compiled in, so we reuse it verbatim.
TARGET_NO_KERNEL := true
BOARD_KERNEL_IMAGE_NAME := Image
BOARD_KERNEL_PAGESIZE := 4096
BOARD_BOOT_HEADER_VERSION := 4
BOARD_VENDOR_BOOT_HEADER_VERSION := 4
BOARD_RAMDISK_USE_LZ4 := true

# stock: unpack_bootimg --format=mkbootimg on vendor_boot.img reports
#   --pagesize 0x1000 --base 0x0 --kernel_offset 0x80000000
#   --ramdisk_offset 0xa3800000 --tags_offset 0x87c80000 --dtb_offset 0x87c80000
# NOTE: these differ from chagall/degas (mt6899/mt6897) — do not copy those.
BOARD_KERNEL_BASE    := 0x00000000
BOARD_KERNEL_OFFSET  := 0x80000000
BOARD_RAMDISK_OFFSET := 0xa3800000
BOARD_TAGS_OFFSET    := 0x87c80000
BOARD_DTB_OFFSET     := 0x87c80000

# stock: vendor_boot.img dtb blob is an MTK dt_table (magic 0xd7b7ab1e, 1 entry),
# NOT a bare d00dfeed FDT. mkbootimg packs it as an opaque blob, so ship it as-is.
TARGET_PREBUILT_DTB := $(DEVICE_PATH)/prebuilt/dtb/warhol.dtb
BOARD_MKBOOTIMG_ARGS += --header_version 4 --dtb $(TARGET_PREBUILT_DTB)

TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery.fstab

# stock vendor_cmdline is exactly 'bootopt=64S3,32N2,64N2 bootconfig'.
# carried: androidboot.selinux=permissive — TWRP's recovery policy does not cover
# this vendor; degas and chagall both black-screened until they ran permissive.
# The flashed image's cmdline is actually set by patch_touch_warhol.sh (it appends
# to the stock header); this line only covers a native `mka vendorbootimage`.
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 bootconfig androidboot.selinux=permissive

# ── Recovery lives in vendor_boot (GKI v4, no recovery partition) ─────────────
# stock: scatter has no recovery_a/recovery_b. vendor_boot.img carries two ramdisk
# fragments: type 0x1 name "" (36,638,170 B — the 295 kernel modules) and type 0x2
# name "recovery" (16,036,595 B — MiRecovery). We replace only the second.
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_USES_VENDOR_BOOT := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true

# stock: scatter vendor_boot_a/_b partition_size = 0x4000000 = 64 MiB.
# Budget check: stock ramdisk00 (34.9 MiB) + TWRP ramdisk (~20 MiB) + dtb (0.6 MiB)
# is close to the ceiling. patch_touch_warhol.sh can prune modules not listed in
# modules.load.recovery (--slim) if it overflows.
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 104857600

# ── A/B ───────────────────────────────────────────────────────────────────────
# stock: every firmware partition in the scatter has _a/_b pairs; flash_all.sh
# ends with `fastboot set_active a`.
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += boot init_boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor

# ── Dynamic partitions ────────────────────────────────────────────────────────
# stock: liblp v10.2 metadata read from super.img —
#   super block device = 13,421,772,800 B; groups main_a/main_b max 13,411,287,040 B.
#   Members: system system_ext vendor product odm vendor_dlkm odm_dlkm system_dlkm mi_ext
# NOTE: system_dlkm and mi_ext are intentionally NOT in the member list — the TWRP
# 14.1 base's config.mk rejects those names. They are mounted/backed up through
# recovery.fstab instead (same workaround degas/chagall used).
# NOTE: PRODUCT_USE_DYNAMIC_PARTITIONS is deliberately NOT set here. It is a
# *product* variable and is already readonly by the time board_config.mk reads
# this file, so assigning it errors with "cannot assign to readonly variable".
# (The chagall/degas trees set it in BoardConfig.mk; that does not work on this
# base.) It is set in twrp_warhol.mk and device.mk, which are product context.
BOARD_SUPER_PARTITION_GROUPS := xiaomi_dynamic_partitions
BOARD_XIAOMI_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext vendor product odm vendor_dlkm odm_dlkm
BOARD_XIAOMI_DYNAMIC_PARTITIONS_SIZE := 13411287040
BOARD_SUPER_PARTITION_SIZE := 13421772800

BOARD_USES_VENDORIMAGE := true
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE     := ext4
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE     := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE    := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEMIMAGE_PARTITION_RESERVED_SIZE := 104857600
BOARD_VENDORIMAGE_PARTITION_RESERVED_SIZE := 104857600

# ── TWRP ──────────────────────────────────────────────────────────────────────
TW_THEME := portrait_hdpi
TW_DEVICE_VERSION := warhol-wip
RECOVERY_SDCARD_ON_DATA := true
TARGET_RECOVERY_PIXEL_FORMAT := BGRA_8888
BOARD_HAS_MTK_HARDWARE := true
TW_INCLUDE_RESETPROP := true
TW_HAPTICS_OEM_VIBRATOR := true

# stock: vendor/etc/init/hw/init.mt6993.rc chowns /sys/class/leds/lcd-backlight/brightness.
# stock: dtbo.img fragment@10 (&mtk_leds, compatible "mediatek,disp-leds") declares
#   backlight { max-brightness = <0x3fff>; min-brightness = <0x1>; max-hw-brightness = <0x3fff>; }
# so 16383 is warhol's own value, not one inherited from chagall.
# The same node has lk_backlight = <0x3ac> (940) — what the bootloader uses.
TW_BRIGHTNESS_PATH := "/sys/class/leds/lcd-backlight/brightness"
TW_MAX_BRIGHTNESS := 16383
TW_DEFAULT_BRIGHTNESS := 8192

# carried: the binder health HAL is unreliable in standalone recovery on these
# Xiaomi/MTK builds; read sysfs directly instead.
TW_USE_LEGACY_BATTERY_SERVICES := true
# stock: "battery" is the power_supply name registered by mtk_battery_manager.ko,
# mt6379-battery.ko, mt6379-chg.ko and bq28z610.ko (all four carry it as a literal;
# mtk_battery_manager.ko is in modules.load.recovery, so the node exists in recovery).
# Pinned explicitly rather than auto-detected because several charger psy nodes
# also register and auto-detect would be ambiguous.
TW_CUSTOM_BATTERY_PATH := /sys/class/power_supply/battery

TW_INPUT_BLACKLIST := "hbtp_vm"

# ── Encryption ────────────────────────────────────────────────────────────────
# Deliberately omitted for first bring-up. warhol's /data is F2FS with FBE
# (aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized) *and* metadata encryption
# (keydirectory=/metadata/vold/metadata_encryption -> dm-default-key). On degas
# and chagall the metadata key proved to be TEE Root-of-Trust bound and could not
# be unwrapped from a custom recovery. See docs/ENCRYPTION.md.
# TW_INCLUDE_CRYPTO := true
# TW_INCLUDE_FBE    := true

# ── AVB ───────────────────────────────────────────────────────────────────────
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

# ── SELinux ───────────────────────────────────────────────────────────────────
BOARD_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy
