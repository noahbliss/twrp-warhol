#!/usr/bin/env bash
# =============================================================================
# extract-blobs.sh — regenerate device/xiaomi/warhol/prebuilt/ and stock/ from a
#                    stock firmware package.
#
# WHY THIS EXISTS INSTEAD OF COMMITTED BINARIES:
# The files this produces are proprietary Xiaomi / MediaTek / Goodix binaries —
# the stock boot and vendor_boot images, the board DTB, the Goodix touch kernel
# modules and their firmware. They are not ours to redistribute, so they are
# .gitignore'd and rebuilt locally by anyone who has the firmware for their own
# device. Nothing here is device-tree source; it is all extracted, byte for byte,
# from the vendor's own package.
#
#   ./tools/extract-blobs.sh /path/to/warhol_global_images_OS3.0.x_16.0
#
# Get the firmware from Xiaomi's own release channels (or a mirror such as
# xiaomirom.com). Match the build you intend to run: the vendor_boot this
# produces must be the one on your device, or the grafted module ramdisk will not
# match your kernel.
# =============================================================================
set -euo pipefail

FW="${1:-}"
[ -n "$FW" ] && [ -d "$FW" ] || { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -d "$FW/images" ] || { echo "ERROR: $FW/images not found — point me at the extracted firmware dir" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/device/xiaomi/warhol"
TOOLS="$ROOT/tools"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

for t in lz4 python3; do command -v $t >/dev/null || { echo "ERROR: $t not installed" >&2; exit 1; }; done
command -v fsck.erofs >/dev/null || { echo "ERROR: erofs-utils not installed (brew install erofs-utils / apt install erofs-utils)" >&2; exit 1; }

mkdir -p "$D/prebuilt/dtb" "$D/prebuilt/touch_modules" "$D/prebuilt/touch_firmware" \
         "$D/recovery/root/vendor/firmware" "$D/recovery/root/lib/firmware" "$D/stock"

echo "=== stock images ==="
cp "$FW/images/boot.img"        "$D/prebuilt/boot.img"
cp "$FW/images/dtbo.img"        "$D/prebuilt/dtbo.img"
cp "$FW/images/vendor_boot.img" "$D/stock/vendor_boot.stock.img"
echo "  boot.img, dtbo.img, vendor_boot.stock.img"

echo "=== board DTB (from vendor_boot; MTK dt_table, packed as-is) ==="
python3 "$TOOLS/mkbootimg/unpack_bootimg.py" --boot_img "$FW/images/vendor_boot.img" --out "$WORK/vb" >/dev/null
cp "$WORK/vb/dtb" "$D/prebuilt/dtb/warhol.dtb"
echo "  warhol.dtb ($(wc -c < "$D/prebuilt/dtb/warhol.dtb") bytes)"

echo "=== stock fstabs + recovery rc (reference) ==="
lz4 -d -f "$WORK/vb/vendor_ramdisk01" "$WORK/vr01.cpio" >/dev/null 2>&1
for f in system/etc/recovery.fstab first_stage_ramdisk/fstab.emmc first_stage_ramdisk/fstab.raid init.recovery.mt6993.rc; do
    python3 "$TOOLS/cpiotool.py" extract "$WORK/vr01.cpio" "$f" "$D/stock/$(basename "$f")" >/dev/null 2>&1 || true
done
mv "$D/stock/recovery.fstab" "$D/stock/recovery.fstab.stock" 2>/dev/null || true
echo "  $(ls "$D/stock" | tr '\n' ' ')"

echo "=== touch modules (vendor_dlkm inside super.img) ==="
python3 "$TOOLS/simg2img.py" "$FW/images/super.img" "$WORK/super.raw"
python3 "$TOOLS/lpunpack.py" "$WORK/super.raw" "$WORK/parts" vendor_dlkm_a odm_a >/dev/null
fsck.erofs --extract="$WORK/vdlkm" --overwrite "$WORK/parts/vendor_dlkm_a.img" >/dev/null 2>&1
fsck.erofs --extract="$WORK/odm"   --overwrite "$WORK/parts/odm_a.img"        >/dev/null 2>&1
for k in xiaomi_touch_warhol.ko goodix_core_warhol.ko gt9895.ko touch_boost.ko \
         mtk_ioctl_touch_boost.ko xiaomi_spi_tee.ko tui-common.ko; do
    src="$WORK/vdlkm/lib/modules/$k"
    [ -f "$src" ] && cp "$src" "$D/prebuilt/touch_modules/$k" && echo "  + $k"
done

echo "=== touch firmware (odm) ==="
for f in goodix_firmware_warhol.bin goodix_cfg_group_warhol.bin warhol_gtp_thp_config.ini; do
    src="$WORK/odm/firmware/$f"
    [ -f "$src" ] && cp "$src" "$D/prebuilt/touch_firmware/$f" && echo "  + $f"
done
for f in goodix_firmware_warhol.bin goodix_cfg_group_warhol.bin; do
    cp "$D/prebuilt/touch_firmware/$f" "$D/recovery/root/vendor/firmware/$f"
    cp "$D/prebuilt/touch_firmware/$f" "$D/recovery/root/lib/firmware/$f"
done

echo
echo "Done. $(find "$D/prebuilt" "$D/stock" -type f | wc -l | tr -d ' ') files extracted."
echo "These are vendor binaries and are gitignored — they are never committed."
