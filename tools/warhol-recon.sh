#!/usr/bin/env bash
# =============================================================================
# warhol-recon.sh — read-only device recon + backup of the irreplaceable
#                   partitions, over adb, on a rooted warhol.
#
# Does NOT write anything to the phone. Everything is streamed to the host with
# `adb exec-out`, so device storage is not touched either.
#
# Produces  out/recon/<timestamp>/
#     report.txt        everything we need to finish the device tree
#     props.txt getprop.txt byname.txt dmsetup.txt ...
#     images/           raw partition backups (see WARNING below)
#
# WARNING: images/nv* , protect* , persist , proinfo contain your IMEI, RF
# calibration and DRM keys. Keep them private — do not post them in a forum
# thread or attach them to a bug report. They are also the ONLY copy of data
# that cannot be regenerated if the partitions are ever damaged.
# =============================================================================
set -uo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$ROOT/out/recon/$STAMP}"
SKIP_IMAGES=0
[ "${1:-}" = "--no-images" ] && SKIP_IMAGES=1

mkdir -p "$OUT/images"
REPORT="$OUT/report.txt"
exec > >(tee "$REPORT") 2>&1

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }

# ── identity guard ───────────────────────────────────────────────────────────
say "Device check"
adb wait-for-device
DEV="$(adb shell getprop ro.product.device | tr -d '\r')"
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
FP="$(adb shell getprop ro.build.fingerprint | tr -d '\r')"
echo "device      : $DEV"
echo "model       : $MODEL"
echo "fingerprint : $FP"
if [ "$DEV" != "warhol" ]; then
    warn "This is NOT warhol (got '$DEV'). Refusing to continue."
    exit 1
fi

# ── root ─────────────────────────────────────────────────────────────────────
SU=""
for c in "su -c" "su 0"; do
    if adb shell "$c id" 2>/dev/null | grep -q "uid=0"; then SU="$c"; break; fi
done
if [ -z "$SU" ]; then
    warn "No root shell (tried 'su -c' and 'su 0')."
    warn "Grant the shell root in Magisk/KernelSU and re-run. Continuing unrooted;"
    warn "most of this report will be empty."
    SU=""
fi
R() { if [ -n "$SU" ]; then adb shell $SU "$*"; else adb shell "$*"; fi; }
RO() { if [ -n "$SU" ]; then adb exec-out $SU "$*"; else adb exec-out "$*"; fi; }
echo "root        : ${SU:-NONE}"

# ── 1. boot / slot / verified boot state ─────────────────────────────────────
say "Boot state"
for p in ro.boot.slot_suffix ro.boot.verifiedbootstate ro.boot.flash.locked \
         ro.boot.veritymode ro.boot.vbmeta.device_state ro.secure ro.debuggable \
         ro.build.type ro.boot.hwc ro.boot.hwlevel ro.hardware ro.board.platform \
         ro.boot.bootreason ro.vendor.mtk_ufs_stripe_size ro.crypto.state \
         ro.crypto.type ro.boot.dynamic_partitions; do
    printf '%-38s = %s\n' "$p" "$(adb shell getprop $p | tr -d '\r')"
done
adb shell getprop > "$OUT/getprop.txt" 2>/dev/null
echo "(full getprop -> getprop.txt)"

# ── 2. Dual-UFS: is this unit striped? ───────────────────────────────────────
say "Storage topology  (THE question: is /data a dm-stripe?)"
echo "--- /dev/block/by-name ---"
R "ls -l /dev/block/by-name" 2>&1 | tee "$OUT/byname.txt" | head -70
echo "... (full listing -> byname.txt)"
echo
echo "--- device-mapper tables ---"
R "dmsetup ls" 2>&1 | tee "$OUT/dmsetup.txt"
R "dmsetup table" 2>&1 | tee -a "$OUT/dmsetup.txt"
echo
echo "--- mtk_userdata specifically ---"
if R "test -e /dev/block/mapper/mtk_userdata && echo PRESENT" 2>/dev/null | grep -q PRESENT; then
    echo ">>> DUAL-UFS CONFIRMED: /dev/block/mapper/mtk_userdata exists"
    R "dmsetup table mtk_userdata" 2>&1
else
    echo ">>> single-UFS: no /dev/block/mapper/mtk_userdata"
    echo "    (init.recovery.mt6993.rc still runs userdata_setup; it is a no-op here)"
fi
echo
echo "--- UFS hosts ---"
R "ls -d /sys/devices/platform/soc/*.ufshci 2>/dev/null" 2>&1
R "ls /sys/class/scsi_host" 2>&1
echo
echo "--- mounts / partitions ---"
R "cat /proc/partitions" > "$OUT/partitions.txt" 2>&1
R "df -h" 2>&1 | head -30
R "cat /proc/mounts" > "$OUT/mounts.txt" 2>&1
echo "(-> partitions.txt, mounts.txt)"

# ── 3. Values my BoardConfig.mk still has TODO(device) on ────────────────────
say "BoardConfig TODOs"
echo "--- backlight ---"
for n in lcd-backlight lcd-backlight1; do
    printf '%-16s max_brightness = %s   current = %s\n' "$n" \
      "$(R "cat /sys/class/leds/$n/max_brightness 2>/dev/null" | tr -d '\r')" \
      "$(R "cat /sys/class/leds/$n/brightness 2>/dev/null" | tr -d '\r')"
done
echo
echo "--- power_supply nodes ---"
R "ls /sys/class/power_supply" 2>&1
echo "battery capacity = $(R "cat /sys/class/power_supply/battery/capacity 2>/dev/null" | tr -d '\r')"
echo
echo "--- input devices (touch shows up here) ---"
R "cat /proc/bus/input/devices" 2>&1 | tee "$OUT/input_devices.txt" | grep -E "^(N|H|P):" | head -40
echo
echo "--- touch sysfs (does the neuter target exist?) ---"
R "ls -l /sys/class/touch/touch_dev/ 2>/dev/null" 2>&1 | head -30
echo "enable_touch_raw = $(R "cat /sys/class/touch/touch_dev/enable_touch_raw 2>/dev/null" | tr -d '\r')"
echo "panel_display    = $(R "cat /sys/class/touch/touch_dev/panel_display 2>/dev/null" | tr -d '\r')"
echo "/dev/xiaomi-touch: $(R "ls -l /dev/xiaomi-touch 2>/dev/null" | tr -d '\r')"
echo
echo "--- loaded touch modules ---"
R "lsmod" > "$OUT/lsmod.txt" 2>&1
grep -iE "touch|goodix|gt98" "$OUT/lsmod.txt" || echo "(none matched)"
echo
echo "--- CPU ---"
R "cat /proc/cpuinfo" > "$OUT/cpuinfo.txt" 2>&1
grep -m1 "CPU part" "$OUT/cpuinfo.txt" 2>/dev/null
echo "cores: $(grep -c ^processor "$OUT/cpuinfo.txt" 2>/dev/null)"
echo
echo "--- framebuffer / DRM resolution ---"
R "cat /sys/class/graphics/fb0/modes 2>/dev/null" 2>&1
adb shell wm size 2>&1 | tr -d '\r'
adb shell wm density 2>&1 | tr -d '\r'
echo
echo "--- USB controller ---"
echo "sys.usb.controller = $(adb shell getprop sys.usb.controller | tr -d '\r')"
R "ls /sys/class/udc" 2>&1

# ── 4. logical partitions, live ──────────────────────────────────────────────
say "Logical partitions (live lpdump)"
R "lpdump" > "$OUT/lpdump.txt" 2>&1 && head -40 "$OUT/lpdump.txt" || echo "(lpdump unavailable)"
echo "(-> lpdump.txt)"

# ── 5. Backups ───────────────────────────────────────────────────────────────
if [ "$SKIP_IMAGES" = 1 ]; then
    say "Image backup skipped (--no-images)"
else
say "Backing up partitions"
# Two classes:
#   restore-point : lets us undo anything we flash
#   irreplaceable : IMEI / RF cal / DRM. Cannot be regenerated. Back up ONCE and keep safe.
RESTORE="boot_a boot_b init_boot_a init_boot_b vendor_boot_a vendor_boot_b dtbo_a dtbo_b \
         vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b vbmeta_vendor_a vbmeta_vendor_b misc"
IRREPLACEABLE="nvdata nvcfg protect1 protect2 persist md_sec nvram proinfo"

pull_part() {
    local name="$1" dest="$OUT/images/$1.img"
    local node="/dev/block/by-name/$name"
    if ! R "test -e $node && echo ok" 2>/dev/null | grep -q ok; then
        printf '  %-20s -- absent, skipped\n' "$name"; return
    fi
    RO "dd if=$node bs=1048576 2>/dev/null" > "$dest"
    local sz; sz=$(stat -f%z "$dest" 2>/dev/null || stat -c%s "$dest")
    if [ "$sz" -gt 0 ]; then
        printf '  %-20s %10d B  %s\n' "$name" "$sz" "$(shasum -a256 "$dest" | cut -c1-16)"
    else
        printf '  %-20s FAILED (0 bytes)\n' "$name"; rm -f "$dest"
    fi
}
echo "--- restore point (undo anything we flash) ---"
for p in $RESTORE; do pull_part "$p"; done
echo
echo "--- irreplaceable (IMEI / RF calibration / DRM keys) ---"
for p in $IRREPLACEABLE; do pull_part "$p"; done
( cd "$OUT/images" && shasum -a256 ./*.img > SHA256SUMS 2>/dev/null )
fi

# ── 5b. Magisk ───────────────────────────────────────────────────────────────
say "Magisk / root"
echo "magisk version : $(adb shell su -c 'magisk -c' 2>/dev/null | tr -d '\r')"
echo "magisk path    : $(R 'which magisk' 2>/dev/null | tr -d '\r')"
echo "manager pkg    : $(adb shell pm list packages 2>/dev/null | grep -iE 'magisk|kernelsu|apatch' | tr -d '\r' | tr '\n' ' ')"
echo
echo "--- which partition carries the patch? (expect init_boot) ---"
# Check BOTH slots. An earlier version hardcoded _a and reported "clean" on a
# device running slot B — the patch was there all along, in the slot not checked.
SLOT="$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')"
echo "  active slot: ${SLOT:-unknown}"
for p in init_boot_a init_boot_b boot_a boot_b vendor_boot_a vendor_boot_b; do
    f="$OUT/images/$p.img"
    if [ -f "$f" ]; then
        if strings -a "$f" 2>/dev/null | grep -qm1 -iE "magisk"; then
            echo "  $p : MAGISK-PATCHED$([ "$p" = "init_boot$SLOT" ] && echo "   <-- active slot")"
        else
            echo "  $p : clean (no magisk strings)"
        fi
    fi
done
echo
echo "NOTE: images/init_boot${SLOT}.img IS your Magisk installation. It is the only"
echo "      copy. We flash vendor_boot only, so root is not at risk — but if TWRP"
echo "      fails to boot, stock fw/images/init_boot.img lets you rule Magisk out,"
echo "      and this backup puts root back afterwards."

# ── 6. THP HAL presence ──────────────────────────────────────────────────────
say "THP touch HAL (fallback path inputs)"
R "ls -l /odm/bin/hw/vendor.xiaomi.hw.touchfeature-service /odm/lib64/libtouchreport*.so /odm/firmware/warhol_gtp_thp_config.ini 2>/dev/null" 2>&1

say "Done"
echo "Output: $OUT"
du -sh "$OUT" 2>/dev/null
cat <<EOF

Next: send me report.txt (it has no secrets — the IMEI lives in images/, not here).
Keep $OUT/images/ private and copy it somewhere safe; nv*/protect*/persist are
the only copy of data that cannot be regenerated.
EOF
