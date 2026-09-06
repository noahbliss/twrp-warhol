# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit from warhol device
$(call inherit-product, device/xiaomi/warhol/device.mk)

# Inherit some common Lineage stuff.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME         := lineage_warhol
PRODUCT_DEVICE       := warhol
PRODUCT_MANUFACTURER := Xiaomi
PRODUCT_BRAND        := Xiaomi
PRODUCT_MODEL        := 2602EPTC0G

PRODUCT_SYSTEM_NAME         := warhol_global
PRODUCT_SYSTEM_DEVICE       := warhol

# Match the stock fingerprint so vendor components and Play Integrity see what
# they expect. Taken verbatim from the device.
PRODUCT_BUILD_PROP_OVERRIDES += \
    TARGET_DEVICE=warhol \
    PRODUCT_NAME=warhol_global \
    PRIVATE_BUILD_DESC="warhol_global-user 16 BP2A.250605.031.A3 OS3.0.310.0.WPSMIXM release-keys"

BUILD_FINGERPRINT := Xiaomi/warhol_global/warhol:16/BP2A.250605.031.A3/OS3.0.310.0.WPSMIXM:user/release-keys
