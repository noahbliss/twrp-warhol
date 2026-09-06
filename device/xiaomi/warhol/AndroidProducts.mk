PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/twrp_warhol.mk

# Android 14 (this base) requires the three-part <product>-<release>-<variant>
# form. `ls build/release/release_configs` on this tree offers only `ap2a`, so
# the two-part `twrp_warhol-eng` that the degas/chagall trees use is rejected
# here with "Invalid lunch combo".
COMMON_LUNCH_CHOICES := \
    twrp_warhol-ap2a-eng \
    twrp_warhol-ap2a-userdebug
