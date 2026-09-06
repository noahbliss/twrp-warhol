# Copyright (C) 2026 The Android Open Source Project
# SPDX-License-Identifier: Apache-2.0
#
# device.mk — Xiaomi 17T Pro (warhol)

LOCAL_PATH := device/$(PRODUCT_MANUFACTURER)/$(PRODUCT_DEVICE)

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=ext4 \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += otapreopt_script

# task_profiles.json — required by bootable/recovery/Android.mk (line ~557), which
# copies it into the recovery root as system/etc/task_profiles/task_profiles_30.json.
# It is a real module (system/core/libprocessgroup/profiles/Android.bp) but nothing
# in this minimal product pulls it into the install set, so the ramdisk assembly
# step fails with:
#   cp: bad 'out/target/product/warhol/system/etc/task_profiles.json': No such file
PRODUCT_PACKAGES += task_profiles.json

# TWRP-tree convention (degas/chagall both pin these on Android 16 devices).
# These describe the *build base* (TWRP 14.1), not the OS the device ships.
PRODUCT_SHIPPING_API_LEVEL := 32
PRODUCT_TARGET_VNDK_VERSION := 34

PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Boot Control HAL — deliberately NOT included.
#
# degas and chagall pull in android.hardware.boot@1.2-mtkimpl + bootctrl.mtXXXX.
# That is wrong for warhol, and would fail the build: this device uses the **AIDL**
# boot HAL, and ships no bootctrl blob at all. Verified against the stock images:
#
#   vendor/bin/hw/android.hardware.boot-service.mtk          (AIDL service)
#   vendor/lib64/android.hardware.boot-V1-ndk.so             (AIDL interface)
#   vendor/lib64/android.hardware.boot@1.{0,1}.so            (compat shims only)
#   -> no bootctrl.* anywhere in vendor/ or odm/
#   stock recovery ramdisk carries android.hardware.boot-service.mtk_recovery
#
# A/B slot switching is done instead by writing the `misc` bootloader_control
# struct directly — see patches/. degas and chagall both had to do this anyway
# because the boot-HAL path hangs in a standalone recovery, so nothing is lost.

# NOT included, on purpose (vendor_boot is 64 MiB and the stock module ramdisk
# already eats 34.9 MiB of it):
#   fastbootd, update_engine, update_engine_sideload, update_verifier
# TWRP has its own zip installer and adb sideload; these only add userspace
# fastboot and official A/B payload sideloading. Re-add if --slim frees room:
#   PRODUCT_PACKAGES += android.hardware.fastboot@1.0-impl-mock fastbootd
#   PRODUCT_PACKAGES += update_engine update_verifier update_engine_sideload
#
# vold / keymaster / gatekeeper are also left out — /data decryption is not
# reachable from recovery on this platform (see docs/ENCRYPTION.md),
# so they would only cost space. Battery reads sysfs (TW_USE_LEGACY_BATTERY_SERVICES),
# so the health HAL is not pulled in either.
