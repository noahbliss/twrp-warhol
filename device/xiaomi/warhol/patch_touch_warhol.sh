#!/usr/bin/env bash
# =============================================================================
# patch_touch_warhol.sh — assemble a flashable TWRP vendor_boot for warhol
#                         (Xiaomi 17T Pro, MediaTek Dimensity 9500 / mt6993)
#
# WHY THIS EXISTS
#   The device tree builds with TARGET_NO_KERNEL, so `mka vendorbootimage`
#   produces a vendor_boot whose *module* ramdisk fragment is empty — none of the
#   295 vendor kernel modules (display, UFS, SPI, touch) are in it, so recovery
#   black-screens. Those modules live in the stock vendor_boot's first ramdisk
#   fragment. This script combines:
#
#     fragment 0 ("")         stock module ramdisk + the Goodix touch modules
#                             from vendor_dlkm + the THP notifier neuter
#     fragment 1 ("recovery") the freshly built TWRP ramdisk + touch firmware
#                             + init.recovery.mt6993.rc + recovery.fstab
#
#   and repacks them with the stock header geometry.
#
# WHY IT EDITS THE CPIO IN MEMORY (tools/cpiotool.py) rather than extracting:
#   extracting a ramdisk to a filesystem as non-root loses uid/gid and cannot
#   create device nodes at all on macOS. Editing the archive keeps every entry
#   byte-exact except the ones we deliberately change, and runs identically on
#   macOS and Linux.
#
# NORMAL HYPEROS BOOT IS NOT AFFECTED: the touch modules are appended only to
# modules.load.recovery (never modules.load), and init.recovery.mt6993.rc lives
# only in the recovery fragment.
#
# Requires: python3, lz4.  (mkbootimg/unpack_bootimg are vendored under tools/.)
# =============================================================================
set -euo pipefail

DEVICE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$DEVICE_PATH/../../.." && pwd)}"   # repo root (…/git/android)
TOOLS="${TOOLS:-$ROOT/tools}"

STOCK_VB="${STOCK_VB:-$DEVICE_PATH/stock/vendor_boot.stock.img}"
TWRP_VB="${TWRP_VB:-$ROOT/out/target/product/warhol/vendor_boot.img}"
TWRP_RD=""                       # optional: a raw TWRP ramdisk (cpio or .lz4)
OUT="${OUT:-$ROOT/out/twrp_warhol-vendor_boot.img}"
SLIM=0
DO_TOUCH_PATCH=1
PART_SIZE=67108864               # 64 MiB — scatter vendor_boot_a/_b partition_size

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF
Options:
  --stock <img>       stock vendor_boot.img          [$STOCK_VB]
  --twrp  <img>       freshly built TWRP vendor_boot [$TWRP_VB]
  --twrp-ramdisk <f>  use this ramdisk (cpio or .lz4) instead of --twrp
  --out   <img>       output image                   [$OUT]
  --slim              drop modules not listed in modules.load.recovery
  --no-touch-patch    skip the xiaomi_touch_warhol.ko THP neuter
  -h|--help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stock)         STOCK_VB="$2"; shift 2 ;;
        --twrp)          TWRP_VB="$2";  shift 2 ;;
        --twrp-ramdisk)  TWRP_RD="$2";  shift 2 ;;
        --out)           OUT="$2";      shift 2 ;;
        --slim)          SLIM=1;        shift ;;
        --no-touch-patch) DO_TOUCH_PATCH=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

UNPACK="$TOOLS/mkbootimg/unpack_bootimg.py"
MKBOOT="$TOOLS/mkbootimg/mkbootimg.py"
CPIO="$TOOLS/cpiotool.py"
KOPATCH="$TOOLS/patch_thp_notifier.py"
for f in "$UNPACK" "$MKBOOT" "$CPIO" "$KOPATCH"; do
    [ -f "$f" ] || { echo "ERROR: missing helper $f" >&2; exit 1; }
done
command -v lz4 >/dev/null || { echo "ERROR: lz4 not installed (brew install lz4 / apt install lz4)" >&2; exit 1; }
[ -f "$STOCK_VB" ] || { echo "ERROR: stock vendor_boot not found: $STOCK_VB" >&2; exit 1; }

fsize() { if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi; }
hr()    { python3 -c "import sys;n=int(sys.argv[1]);print(f'{n:,} B ({n/2**20:.2f} MiB)')" "$1"; }

WS="$ROOT/out/warhol_repack"
rm -rf "$WS"; mkdir -p "$WS/stock" "$WS/twrp"
mkdir -p "$(dirname "$OUT")"

# ── 1. Unpack the stock image: gives geometry + both ramdisk fragments ───────
echo "=== [1/6] Unpacking stock vendor_boot ==="
python3 "$UNPACK" --boot_img "$STOCK_VB" --out "$WS/stock" --format=mkbootimg > "$WS/mkbootimg.args"
echo "  args: $(cat "$WS/mkbootimg.args")"
MODS_LZ4="$WS/stock/vendor_ramdisk00"
[ -f "$MODS_LZ4" ] || { echo "ERROR: stock image has no vendor_ramdisk00" >&2; exit 1; }

# ── 2. Module ramdisk: add the Goodix touch stack, patch the THP notifier ────
echo "=== [2/6] Building module ramdisk (fragment 0) ==="
lz4 -d -f "$MODS_LZ4" "$WS/mods.cpio" >/dev/null 2>&1
echo "  stock module ramdisk: $(hr "$(fsize "$WS/mods.cpio")") uncompressed"

STAGE="$WS/ko"; mkdir -p "$STAGE"
# goodix_core_warhol matches the DT node compatible "xiaomi,touch-spi" and
# depends on xiaomi_touch_warhol. gt9895.ko is the legacy mtk-tpd3 path and is
# NOT used by this board's DT, so it is deliberately left out.
TOUCH_KOS=(xiaomi_touch_warhol.ko goodix_core_warhol.ko)
for k in "${TOUCH_KOS[@]}"; do
    cp "$DEVICE_PATH/prebuilt/touch_modules/$k" "$STAGE/$k"
done
if [ "$DO_TOUCH_PATCH" = 1 ]; then
    echo "  patching THP notifier:"
    python3 "$KOPATCH" "$STAGE/xiaomi_touch_warhol.ko"
else
    echo "  --no-touch-patch: leaving xiaomi_touch_warhol.ko stock"
fi

# Append to modules.load.recovery ONLY (dependency order: framework, then driver).
python3 "$CPIO" cat "$WS/mods.cpio" lib/modules/modules.load.recovery > "$WS/mlr.txt"
for k in "${TOUCH_KOS[@]}"; do
    grep -qx "$k" "$WS/mlr.txt" || echo "$k" >> "$WS/mlr.txt"
done
echo "  modules.load.recovery: $(wc -l < "$WS/mlr.txt") entries"

# modules.dep MUST also gain entries. Appending to modules.load.recovery alone
# is not enough: init resolves every module through libmodprobe/modules.dep, and
# an unresolvable module is FATAL —
#   init: LoadWithAliases was unable to load xiaomi_touch_warhol
#   init: Failed to load kernel modules
#   Kernel panic - not syncing: Attempted to kill init!
# which bootloops the device. (Observed on the first flash, 2026-09-06.)
python3 "$CPIO" cat "$WS/mods.cpio" lib/modules/modules.dep > "$WS/dep.in"
python3 "$TOOLS/modules_dep_add.py" "$WS/dep.in" "$WS/dep.out" \
    $(for k in "${TOUCH_KOS[@]}"; do printf '%s ' "$STAGE/$k"; done)

EDIT_ARGS=(--add "lib/modules/modules.load.recovery=$WS/mlr.txt:644"
           --add "lib/modules/modules.dep=$WS/dep.out:644")
for k in "${TOUCH_KOS[@]}"; do
    EDIT_ARGS+=(--add "lib/modules/$k=$STAGE/$k:644")
done

if [ "$SLIM" = 1 ]; then
    echo "  --slim: pruning modules not in modules.load.recovery"
    python3 - "$WS/mods.cpio" "$WS/mlr.txt" "$CPIO" > "$WS/slim.args" <<'PY'
import sys, importlib.util
src = open(sys.argv[3]).read().replace('\nmain()\n', '\n')
ns = {'__name__': 'c'}; exec(src, ns)
entries = ns['read'](open(sys.argv[1], 'rb').read())
keep = set(l.strip() for l in open(sys.argv[2]) if l.strip())
for e in entries:
    n = e.name
    if n.startswith('lib/modules/') and n.endswith('.ko'):
        if n.rsplit('/', 1)[1] not in keep:
            print('--rm'); print(n)
PY
    while read -r op && read -r val; do EDIT_ARGS+=("$op" "$val"); done < "$WS/slim.args"
fi

python3 "$CPIO" edit "$WS/mods.cpio" "$WS/mods.new.cpio" "${EDIT_ARGS[@]}"
lz4 -l -12 --favor-decSpeed -f "$WS/mods.new.cpio" "$MODS_LZ4" >/dev/null 2>&1
echo "  fragment 0 compressed: $(hr "$(fsize "$MODS_LZ4")")"

# ── 3. Obtain the TWRP recovery ramdisk ─────────────────────────────────────
echo "=== [3/6] Obtaining TWRP recovery ramdisk (fragment 1) ==="
if [ -n "$TWRP_RD" ]; then
    [ -f "$TWRP_RD" ] || { echo "ERROR: --twrp-ramdisk not found: $TWRP_RD" >&2; exit 1; }
    if head -c4 "$TWRP_RD" | od -An -tx1 | tr -d ' \n' | grep -qi '^0221 *4c18\|^02214c18'; then
        lz4 -d -f "$TWRP_RD" "$WS/twrp.cpio" >/dev/null 2>&1
    else
        cp "$TWRP_RD" "$WS/twrp.cpio"
    fi
    echo "  using $TWRP_RD"
else
    [ -f "$TWRP_VB" ] || { echo "ERROR: built TWRP vendor_boot not found: $TWRP_VB
       Build it first (mka vendorbootimage) or pass --twrp / --twrp-ramdisk." >&2; exit 1; }
    python3 "$UNPACK" --boot_img "$TWRP_VB" --out "$WS/twrp" >/dev/null
    SRC=""
    for cand in "$WS/twrp/vendor-ramdisk-by-name/ramdisk_recovery" \
                "$WS/twrp/vendor_ramdisk01" "$WS/twrp/vendor_ramdisk00"; do
        [ -e "$cand" ] && { SRC="$cand"; break; }
    done
    [ -n "$SRC" ] || { echo "ERROR: no ramdisk fragment found in $TWRP_VB" >&2; exit 1; }
    echo "  using $(basename "$SRC") from the build"
    lz4 -d -f "$SRC" "$WS/twrp.cpio" >/dev/null 2>&1
fi
echo "  TWRP ramdisk: $(hr "$(fsize "$WS/twrp.cpio")") uncompressed"

# ── 4. Bake device files into the TWRP ramdisk ──────────────────────────────
echo "=== [4/6] Baking device files into the TWRP ramdisk ==="
RR="$DEVICE_PATH/recovery/root"

# If the ramdisk came from another device's build (the --twrp-ramdisk port path),
# strip that device's recovery init and touch bring-up. init picks its rc by
# ro.hardware, which is mt6993 here, so a foreign init.recovery.mt68xx.rc would
# never be read — but leaving it in is confusing and wastes the 64 MiB budget.
# /thp is chagall's Novatek THP HAL harness; warhol's Goodix path does not use it.
# List once to a file rather than piping into `grep -q`: cpiotool restores the
# default SIGPIPE, so an early-exiting `grep -q` makes the pipeline return 141,
# and `set -o pipefail` then swallows the match.
python3 "$CPIO" list "$WS/twrp.cpio" > "$WS/twrp.list"
FOREIGN=()
for f in init.recovery.mt6899.rc init.recovery.mt6897.rc; do
    grep -q " $f\$" "$WS/twrp.list" && FOREIGN+=(--rm "$f") || true
done
grep -q " thp/" "$WS/twrp.list" && FOREIGN+=(--rmdir thp) || true
[ ${#FOREIGN[@]} -gt 0 ] && echo "  stripping foreign device artifacts: ${FOREIGN[*]}"

python3 "$CPIO" edit "$WS/twrp.cpio" "$WS/twrp.new.cpio" \
    ${FOREIGN[@]+"${FOREIGN[@]}"} \
    --add "init.recovery.mt6993.rc=$RR/init.recovery.mt6993.rc:750" \
    --add "system/etc/recovery.fstab=$DEVICE_PATH/recovery.fstab:644" \
    --add "vendor/firmware/goodix_firmware_warhol.bin=$RR/vendor/firmware/goodix_firmware_warhol.bin:644" \
    --add "vendor/firmware/goodix_cfg_group_warhol.bin=$RR/vendor/firmware/goodix_cfg_group_warhol.bin:644" \
    --add "lib/firmware/goodix_firmware_warhol.bin=$RR/lib/firmware/goodix_firmware_warhol.bin:644" \
    --add "lib/firmware/goodix_cfg_group_warhol.bin=$RR/lib/firmware/goodix_cfg_group_warhol.bin:644"
# If the userspace came from another device's build, make it identify as warhol.
# Provenance stays credited in README.md / README.md — this only fixes what the
# DEVICE reports about itself (and what TWRP names its backup folders).
if [ ${#FOREIGN[@]} -gt 0 ] || grep -q " prop.default\$" "$WS/twrp.list"; then
    python3 "$TOOLS/rebrand_ramdisk.py" "$WS/twrp.new.cpio" "$WS/twrp.branded.cpio" warhol warhol \
        && mv "$WS/twrp.branded.cpio" "$WS/twrp.new.cpio"
fi
lz4 -l -12 --favor-decSpeed -f "$WS/twrp.new.cpio" "$WS/stock/vendor_ramdisk01" >/dev/null 2>&1
echo "  fragment 1 compressed: $(hr "$(fsize "$WS/stock/vendor_ramdisk01")")"

# ── 5. Repack with the stock geometry, SELinux permissive ───────────────────
echo "=== [5/6] Repacking ==="
python3 - "$WS/mkbootimg.args" "$MKBOOT" "$OUT" <<'PY'
import shlex, subprocess, sys
args = shlex.split(open(sys.argv[1]).read().strip())
mkboot, out = sys.argv[2], sys.argv[3]
# TWRP's recovery policy does not cover this vendor; degas and chagall both
# black-screened until they ran permissive. Append, do not replace: the stock
# 'bootopt=64S3,32N2,64N2 bootconfig' is required by the MTK bootloader.
for i, a in enumerate(args):
    if a == '--vendor_cmdline':
        if 'androidboot.selinux=permissive' not in args[i+1]:
            args[i+1] = args[i+1] + ' androidboot.selinux=permissive'
        break
cmd = [sys.executable, mkboot] + args + ['--vendor_boot', out]
print('  ' + ' '.join(shlex.quote(c) for c in cmd))
sys.exit(subprocess.call(cmd))
PY

# ── 6. Report ────────────────────────────────────────────────────────────────
echo "=== [6/6] Result ==="
SZ=$(fsize "$OUT")
echo "  $OUT"
echo "  size: $(hr "$SZ")   partition limit: $(hr "$PART_SIZE")"
if [ "$SZ" -le "$PART_SIZE" ]; then
    echo "  FITS ✓  ($(( (PART_SIZE - SZ) / 1048576 )) MiB headroom)"
else
    echo "  OVER BY $(( (SZ - PART_SIZE) / 1048576 )) MiB — re-run with --slim, or drop"
    echo "     packages from device.mk (fastbootd / update_engine)."
    exit 1
fi
cat <<EOF

Flash (bootloader unlocked, verification disabled):
    fastboot flash vendor_boot_a $OUT
    fastboot flash vendor_boot_b $OUT      # keep both slots consistent
    fastboot reboot recovery

This image has no AVB footer; it must be flashed to a device whose vbmeta was
flashed with --disable-verity --disable-verification.
EOF
