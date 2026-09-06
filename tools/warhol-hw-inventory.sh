#!/usr/bin/env bash
# =============================================================================
# warhol-hw-inventory.sh — read-only hardware/blob inventory for LineageOS
#                          bring-up. Runs over adb; writes nothing to the phone.
#
# The output is the raw material for a LineageOS device tree:
#   - VINTF tells you which HALs MUST exist or the framework refuses to boot
#   - the HAL service list tells you which binaries provide them
#   - the per-subsystem sections map hardware -> blobs -> firmware -> kernel module
#
#     ./tools/warhol-hw-inventory.sh          -> out/hw-inventory/<stamp>/
# =============================================================================
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${OUT:-$ROOT/out/hw-inventory/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
exec > >(tee "$OUT/inventory.txt") 2>&1

adb wait-for-device
DEV="$(adb shell getprop ro.product.device | tr -d '\r')"
[ "$DEV" = "warhol" ] || { echo "not warhol (got '$DEV'), refusing"; exit 1; }
SU=""; adb shell "su -c id" 2>/dev/null | grep -q "uid=0" && SU="su -c"
R() { if [ -n "$SU" ]; then adb shell $SU "$*"; else adb shell "$*"; fi; }
say() { printf '\n\033[1m===== %s =====\033[0m\n' "$*"; }

say "Identity"
for p in ro.product.device ro.product.model ro.build.fingerprint ro.board.platform \
         ro.hardware ro.soc.model ro.boot.hwc ro.vendor.build.fingerprint; do
    printf '  %-32s %s\n' "$p" "$(adb shell getprop $p | tr -d '\r')"
done

say "VINTF — HALs the framework requires"
R "cat /vendor/etc/vintf/manifest.xml" > "$OUT/vendor_manifest.xml" 2>/dev/null
R "ls /vendor/etc/vintf/manifest/" > "$OUT/vendor_manifest_frags.txt" 2>/dev/null
R "ls /odm/etc/vintf/manifest/"    > "$OUT/odm_manifest_frags.txt" 2>/dev/null
echo "  vendor manifest fragments: $(wc -l < "$OUT/vendor_manifest_frags.txt" 2>/dev/null)"
echo "  odm manifest fragments:    $(wc -l < "$OUT/odm_manifest_frags.txt" 2>/dev/null)"
R "cat /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/manifest/*.xml /odm/etc/vintf/manifest/*.xml 2>/dev/null" \
  | tr -d '\r' | grep -oE '<name>[^<]+</name>' | sed 's/<[^>]*>//g' | sort -u > "$OUT/hal_interfaces.txt"
echo "  distinct HAL interfaces declared: $(wc -l < "$OUT/hal_interfaces.txt")"
echo "  --- non-AOSP (vendor/xiaomi/mediatek) interfaces, i.e. the porting work ---"
grep -vE '^android\.(hardware|frameworks|system)\.' "$OUT/hal_interfaces.txt" | sed 's/^/    /'

say "HAL service binaries"
for d in /vendor/bin/hw /odm/bin/hw /system/bin/hw; do
    echo "  --- $d ---"; R "ls $d" 2>/dev/null | tr -d '\r' | sed 's/^/    /'
done

say "Kernel modules actually loaded"
R "lsmod" 2>/dev/null | tr -d '\r' > "$OUT/lsmod.txt"
echo "  $(wc -l < "$OUT/lsmod.txt") modules loaded (-> lsmod.txt)"

subsys() {   # subsys <label> <regex>
    say "$1"
    echo "  --- properties ---"
    adb shell getprop 2>/dev/null | tr -d '\r' | grep -iE "$2" | sed 's/^/    /' | head -25
    echo "  --- blobs (vendor/odm/system_ext lib + bin) ---"
    R "ls /vendor/lib64/hw /vendor/lib64 /odm/lib64/hw /odm/lib64 /vendor/bin/hw /odm/bin/hw /system_ext/lib64 2>/dev/null" \
      | tr -d '\r' | grep -iE "$2" | sort -u | sed 's/^/    /' | head -30
    echo "  --- firmware ---"
    R "ls /vendor/firmware /odm/firmware 2>/dev/null" | tr -d '\r' | grep -iE "$2" | sed 's/^/    /' | head -15
    echo "  --- kernel modules ---"
    grep -iE "$2" "$OUT/lsmod.txt" | awk '{print "    "$1}' | head -15
}

subsys "CAMERA"       'camera|mialgo|micam|arcsoft|morpho|dualcam|megvii|sensor.*hal|seninf|isp'
subsys "FINGERPRINT"  'fingerprint|goodix|fod|biometric'
subsys "RADIO / MODEM" 'radio|ril|modem|ccci|mtk_?rild|imsa|volte|ims|telephony|sim'
subsys "IR BLASTER"   'consumerir|infrared'
subsys "AUDIO"        'audio|speaker_amp|aw8|cs35|tas2|soundtrigger|dsp'
subsys "SENSORS"      'sensor|msensor|contexthub|scp'
subsys "NFC"          'nfc|nxp|se_service|secure_element'
subsys "WIFI / BT"    'wifi|wlan|bluetooth|bt_|connsys|conninfra|connac'
subsys "GPU / DISPLAY" 'gpu|mali|powervr|gralloc|hwcomposer|composer|drm|display'
subsys "VIBRATOR"     'vibrator|haptic|aw8697'
subsys "POWER/THERMAL" 'thermal|power|perf|charger|battery'
subsys "DOLBY"        'dolby|dax|dvs|dms'
subsys "NPU / APU"    'apu|neuron|neuropilot|mdla|mvpu|aiste|armnn'

say "GOOGLE / GMS (baseline for planning GApps on LineageOS)"
echo "  GMS        $(adb shell dumpsys package com.google.android.gms 2>/dev/null | grep -m1 versionName | tr -d '\r')"
echo "  Play Store $(adb shell dumpsys package com.android.vending 2>/dev/null | grep -m1 versionName | tr -d '\r')"
echo "  google packages installed: $(adb shell pm list packages 2>/dev/null | grep -c 'com.google.android')"
echo "  --- Widevine (L1 is lost on an unlocked bootloader; expect L3) ---"
adb shell 'getprop | grep -iE "widevine|drm"' 2>/dev/null | tr -d '\r' | sed 's/^/    /' | head -6

say "Done"
echo "Output: $OUT"
