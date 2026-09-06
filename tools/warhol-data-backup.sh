#!/usr/bin/env bash
# =============================================================================
# warhol-data-backup.sh — pull the irreplaceable parts of /data off the phone,
#                         from the RUNNING, ROOTED OS.
#
# WHY FROM THE RUNNING OS AND NOT TWRP:
#   /data is F2FS + FBE + metadata encryption (dm-default-key). The metadata key
#   is bound to the Verified Boot Root of Trust, so a custom recovery cannot
#   unwrap it — TWRP will never read this data, with or without your PIN.
#   A booted, rooted HyperOS reads it decrypted natively. See docs/ENCRYPTION.md.
#
# WHAT THIS IS AND IS NOT:
#   IS      a rollback safety net for THIS HyperOS install, and a source you can
#           cherry-pick files out of later.
#   IS NOT  a migration tool to LineageOS. Restoring /data/data onto a different
#           ROM does not work properly (UIDs, SELinux contexts, app versions all
#           differ). For that, use per-app tooling, and RE-ENROL 2FA rather than
#           restoring authenticator data.
#
#   Streams over `adb exec-out` — nothing is written to the phone.
#   tar runs with --selinux --numeric-owner --sparse so labels and ownership
#   survive, which is what makes a same-ROM restore viable at all.
#
#     ./tools/warhol-data-backup.sh                 # default set (~12.5 GB)
#     ./tools/warhol-data-backup.sh --with-apps     # adds /data/app (+24 GB)
#     ./tools/warhol-data-backup.sh --media-only    # just internal storage
# =============================================================================
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${OUT:-$ROOT/out/data-backup/$(date +%Y%m%d-%H%M%S)}"
MODE=default
case "${1:-}" in
    --with-apps) MODE=with-apps ;;
    --media-only) MODE=media-only ;;
    "") ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
esac
mkdir -p "$OUT"

adb wait-for-device
DEV="$(adb shell getprop ro.product.device | tr -d '\r')"
[ "$DEV" = "warhol" ] || { echo "not warhol (got '$DEV'), refusing" >&2; exit 1; }
adb shell "su -c id" 2>/dev/null | grep -q "uid=0" || { echo "no root shell; grant shell root in Magisk" >&2; exit 1; }

free_gb() { df -g "$ROOT" 2>/dev/null | awk 'NR==2{print $4}'; }
echo "host free: $(free_gb) GB"
echo "output   : $OUT"
echo
echo "NOTE: apps are running, so files can change mid-read and tar may warn about"
echo "      a few. That is expected for a live backup. Avoid using the phone now."
echo

# name : path : extra tar args
SETS=(
  "data_data:/data/data:--exclude=cache --exclude=code_cache --exclude=no_backup"
  "user_de:/data/user_de:--exclude=cache --exclude=code_cache"
  "media0:/data/media/0:--exclude=Android/data --exclude=Android/obb"
  "system:/data/system:"
  "misc:/data/misc:"
  "adb_magisk:/data/adb:--exclude=magisk.db"
)
[ "$MODE" = "media-only" ] && SETS=( "media0:/data/media/0:" )
[ "$MODE" = "with-apps" ] && SETS+=( "app:/data/app:" )

# Package inventory — what was installed, for rebuilding later.
adb shell 'pm list packages -f' 2>/dev/null | tr -d '\r' | sort > "$OUT/packages.txt"
adb shell 'pm list packages -s' 2>/dev/null | tr -d '\r' | sort > "$OUT/packages-system.txt"
adb shell 'pm list packages -3' 2>/dev/null | tr -d '\r' | sort > "$OUT/packages-user.txt"
echo "package inventory: $(wc -l < "$OUT/packages-user.txt") user apps, $(wc -l < "$OUT/packages.txt") total"
echo

fail=0
for entry in "${SETS[@]}"; do
    name="${entry%%:*}"; rest="${entry#*:}"
    path="${rest%%:*}"; extra="${rest#*:}"
    dst="$OUT/$name.tar"
    printf '  %-12s %-18s ' "$name" "$path"
    # shellcheck disable=SC2086
    adb exec-out "su -c 'tar -c --selinux --numeric-owner --sparse $extra -C $path . 2>/dev/null'" > "$dst"
    sz=$(stat -f%z "$dst" 2>/dev/null || stat -c%s "$dst")
    if [ "${sz:-0}" -lt 10240 ]; then
        echo "FAILED / empty ($sz B)"; rm -f "$dst"; fail=1
    else
        printf '%8.2f GB\n' "$(echo "$sz" | awk '{print $1/1073741824}')"
    fi
done

echo
echo "verifying (sha256)…"
( cd "$OUT" && shasum -a256 ./*.tar > SHA256SUMS 2>/dev/null )
echo "spot-checking archive integrity…"
for t in "$OUT"/*.tar; do
    n=$(tar -tf "$t" 2>/dev/null | wc -l | tr -d ' ')
    printf '  %-20s %s entries\n' "$(basename "$t")" "$n"
done

cat > "$OUT/README.txt" <<EOF
warhol /data backup — $(date)
Device: $DEV  fingerprint: $(adb shell getprop ro.build.fingerprint | tr -d '\r')
Slot:   $(adb shell getprop ro.boot.slot_suffix | tr -d '\r')

Created with tar --selinux --numeric-owner --sparse, streamed over adb exec-out.
Caches excluded. /data/app excluded unless --with-apps was used (re-downloadable).

RESTORE (same HyperOS install only), from TWRP or a rooted shell, e.g.:
    adb push data_data.tar /tmp/
    su -c 'tar -x --selinux --numeric-owner -f /tmp/data_data.tar -C /data/data'
Restoring onto LineageOS will NOT work correctly — different UIDs and SELinux
contexts. Use per-app tooling for that, and re-enrol 2FA rather than restoring it.

CONTAINS PERSONAL DATA. Keep it private.
EOF

echo
echo "total: $(du -sh "$OUT" | cut -f1)   host free now: $(free_gb) GB"
echo "$OUT"
[ "$fail" = 0 ] || echo "WARNING: at least one set failed — see above"
exit $fail
