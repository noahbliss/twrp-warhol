#
# device.mk — LineageOS 23 for warhol
#
LOCAL_PATH := device/xiaomi/warhol

# API levels. warhol shipped with Android 16.
PRODUCT_SHIPPING_API_LEVEL := 36
PRODUCT_TARGET_VNDK_VERSION := 36

# Treble. warhol is ro.treble.enabled=true at vendor API level 202504.
PRODUCT_FULL_TREBLE_OVERRIDE := true
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_VIRTUAL_AB_OTA := true
PRODUCT_VIRTUAL_AB_COMPRESSION := true

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=erofs \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += \
    otapreopt_script \
    update_engine \
    update_engine_sideload \
    update_verifier

# Screen — 1280x2772, density 520 (derived from the Goodix panel-max values and
# confirmed with `wm size` / `wm density` on the device).
PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xxxhdpi
PRODUCT_PROPERTY_OVERRIDES += \
    ro.sf.lcd_density=520

# ── NOT included, deliberately ───────────────────────────────────────────────
# No HAL packages are listed here. This build keeps the stock vendor/odm/
# vendor_dlkm (see BoardConfig.mk), which already provide all 150 declared HALs.
# Adding AOSP HAL implementations on top would conflict with them.
#
# The one thing that WILL need attention is anything the framework expects that
# the Xiaomi vendor provides through a proprietary interface with no AOSP
# consumer — see device/xiaomi/warhol/proprietary-files.txt for the inventory,
# and the notes on fingerprint (Goodix FOD) and camera in the TWRP repo's
# docs/LINEAGEOS.md.

# ── Fingerprint (Goodix FOD) ─────────────────────────────────────────────────
# Values read from the device; these are hardware constants, identical on every
# warhol. The sensor itself is straightforward; the display-dimming path
# (vendor.xiaomi.hardware.displayfeature_aidl) is the usual sticking point.
#   persist.vendor.sys.fp.fod.location.X_Y        = 535,2413
#   persist.vendor.sys.fp.fod.size.width_height   = 210,210
#   ro.hardware.fp.fod                            = true   (location "low")
# TODO(lineage): wire these into an overlay once a build boots.

# ── rootdir ───────────────────────────────────────────────────────────────────
# TODO(lineage): decide whether any init.rc additions are needed at all when the
# stock vendor is kept — its own init.mt6993.rc already runs.
