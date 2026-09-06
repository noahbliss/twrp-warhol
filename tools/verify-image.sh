#!/usr/bin/env bash
# =============================================================================
# verify-image.sh — refuse to let you flash the wrong vendor_boot.
#
#     ./tools/verify-image.sh out/twrp_warhol-vendor_boot.img
#
# Checks, in order of how badly each one bricks you:
#   1. header geometry matches warhol's stock vendor_boot (a chagall/degas image
#      has different load addresses -> hard brick)
#   2. fits in the 64 MiB vendor_boot partition
#   3. carries a "recovery" ramdisk fragment
#   4. fragment 0 still has the vendor kernel modules
#   5. modules.load (NORMAL HyperOS boot) has no touch entries added
#   6. the touch modules ARE in modules.load.recovery, and the .ko is patched
#   7. the device fstab and Goodix firmware are in fragment 1
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$ROOT/out/twrp_warhol-vendor_boot.img}"
TOOLS="$ROOT/tools"
WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# Stock geometry — read from warhol's own vendor_boot, not typed from memory.
EXP_KERNEL=0x80000000; EXP_RAMDISK=0xa3800000; EXP_TAGS=0x87c80000; EXP_DTB=0x87c80000
PART=67108864

fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
note() { printf '        %s\n' "$*"; }

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
echo "Verifying: $IMG"
echo

python3 "$TOOLS/mkbootimg/unpack_bootimg.py" --boot_img "$IMG" --out "$WS" \
    --format=mkbootimg > "$WS/args" 2>/dev/null || { echo "not a vendor_boot image" >&2; exit 1; }
ARGS="$(cat "$WS/args")"
get() { echo "$ARGS" | grep -o -- "$1 [^ ]*" | awk '{print $2}'; }

echo "1. Header geometry (wrong values = wrong device = brick)"
for pair in "--kernel_offset $EXP_KERNEL" "--ramdisk_offset $EXP_RAMDISK" \
            "--tags_offset $EXP_TAGS" "--dtb_offset $EXP_DTB"; do
    set -- $pair; flag=$1; exp=$2
    got="$(get "$flag")"
    # dtb_offset is printed zero-padded to 64 bits
    if [ "$((got))" = "$((exp))" ] 2>/dev/null; then ok "$flag = $got"
    else bad "$flag = $got  (expected $exp)"; note "This image was NOT built for warhol. DO NOT FLASH."; fi
done
echo

echo "2. Size"
SZ=$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG")
if [ "$SZ" -le "$PART" ]; then ok "$SZ B <= $PART B ($(( (PART-SZ)/1048576 )) MiB headroom)"
else bad "$SZ B > $PART B — will not fit"; fi
echo

echo "3. Ramdisk fragments"
if echo "$ARGS" | grep -q -- "--ramdisk_name recovery"; then ok "'recovery' fragment present"
else bad "no 'recovery' ramdisk fragment"; fi
echo

MODS="$WS/vendor_ramdisk00"; REC="$WS/vendor_ramdisk01"
[ -f "$MODS" ] && lz4 -d -f "$MODS" "$WS/m.cpio" >/dev/null 2>&1
[ -f "$REC" ]  && lz4 -d -f "$REC"  "$WS/r.cpio" >/dev/null 2>&1
# List ONCE into a file. Piping into `grep -q` is a trap here: cpiotool restores
# the default SIGPIPE, so grep exiting early kills it with 141, and `pipefail`
# turns that into a spurious FAIL for entries that are actually present.
python3 "$TOOLS/cpiotool.py" list "$WS/m.cpio" > "$WS/m.list" 2>/dev/null || true
python3 "$TOOLS/cpiotool.py" list "$WS/r.cpio" > "$WS/r.list" 2>/dev/null || true
C() { python3 "$TOOLS/cpiotool.py" cat  "$1" "$2" 2>/dev/null; }
has() { grep -q " $2\$" "$1"; }

echo "4. Fragment 0 kernel modules"
NKO=$(grep -c '\.ko$' "$WS/m.list")
if [ "$NKO" -gt 200 ]; then ok "$NKO modules present"
else bad "only $NKO modules — recovery will black-screen (display/UFS drivers missing)"; fi
echo

echo "5. Normal HyperOS boot untouched"
NT=$(C "$WS/m.cpio" lib/modules/modules.load | grep -cE 'goodix|xiaomi_touch')
if [ "$NT" = "0" ]; then ok "modules.load has no touch entries — normal boot unaffected"
else bad "modules.load contains $NT touch entries — this WOULD affect normal HyperOS boot"; fi
echo

echo "6. Touch bring-up"
for k in xiaomi_touch_warhol.ko goodix_core_warhol.ko; do
    if has "$WS/m.list" "lib/modules/$k"; then ok "$k in ramdisk"
    else bad "$k missing from ramdisk"; fi
    if C "$WS/m.cpio" lib/modules/modules.load.recovery | grep -qx "$k"; then ok "$k in modules.load.recovery"
    else bad "$k not in modules.load.recovery — it will never load"; fi
done
python3 "$TOOLS/cpiotool.py" extract "$WS/m.cpio" lib/modules/xiaomi_touch_warhol.ko "$WS/x.ko" >/dev/null 2>&1
if python3 "$TOOLS/patch_thp_notifier.py" "$WS/x.ko" --check 2>/dev/null | grep -q "already patched"; then
    ok "xiaomi_drm_panel_notifier_callback neutered"
else
    bad "THP notifier NOT patched — touch will be dead (kernel stays in raw/THP mode)"
fi
echo

echo "7. Module resolvability (a missing modules.dep entry = kernel panic in init)"
C "$WS/m.cpio" lib/modules/modules.dep > "$WS/m.dep" 2>/dev/null
C "$WS/m.cpio" lib/modules/modules.load.recovery > "$WS/m.mlr" 2>/dev/null
missing=0
while read -r k; do
    [ -n "$k" ] || continue
    grep -q "^/lib/modules/$k:" "$WS/m.dep" || { bad "$k is in modules.load.recovery but NOT in modules.dep"; missing=$((missing+1)); }
done < "$WS/m.mlr"
[ "$missing" = 0 ] && ok "all $(grep -c . "$WS/m.mlr") modules in modules.load.recovery resolve via modules.dep"
echo

echo "8. Fragment 1 device files"
for f in init.recovery.mt6993.rc system/etc/recovery.fstab \
         vendor/firmware/goodix_firmware_warhol.bin vendor/firmware/goodix_cfg_group_warhol.bin; do
    if has "$WS/r.list" "$f"; then ok "$f"; else bad "$f missing"; fi
done
if C "$WS/r.cpio" init.recovery.mt6993.rc | grep -q userdata_setup; then
    ok "dual-UFS userdata_setup present in init.recovery.mt6993.rc"
else
    bad "userdata_setup missing — /data will be invisible, and a wipe would hit one stripe only"
fi
echo

if [ "$fail" = 0 ]; then
    printf '\033[32mALL CHECKS PASSED\033[0m — safe to flash per docs/FLASHING.md\n'
else
    printf '\033[31mCHECKS FAILED\033[0m — do not flash this image.\n'
fi
exit $fail
