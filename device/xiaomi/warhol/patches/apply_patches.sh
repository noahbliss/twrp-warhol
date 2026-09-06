#!/usr/bin/env bash
# =============================================================================
# apply_patches.sh — apply the build-tree patches warhol needs.
#
# Run from the AOSP build top AFTER `repo sync`, BEFORE `lunch`:
#     ./device/xiaomi/warhol/patches/apply_patches.sh
#
# Layout: patches/<repo/path>/NNNN-*.patch  ->  applied to  <repo/path>
# Idempotent — already-applied patches are detected and skipped.
#
# Carried patches:
#   bootable/recovery/0001-Set_Active_Slot-...
#       Replaces TWRP's IBootControl::getService() slot switch with a direct
#       write of the misc bootloader_control struct. On warhol this is REQUIRED,
#       not merely a workaround: the device ships only the AIDL boot HAL
#       (android.hardware.boot-service.mtk) and no bootctrl blob, so the HIDL
#       path TWRP uses cannot resolve at all. Origin: the degas tree, where the
#       same code was validated on MT6897.
# =============================================================================
set -euo pipefail

PATCHES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="${TOP:-$PWD}"

if [ ! -d "$TOP/bootable/recovery" ] && [ ! -d "$TOP/build/make" ]; then
    echo "ERROR: '$TOP' does not look like an AOSP build top." >&2
    echo "       cd to the build top first, or set TOP=/path/to/top." >&2
    exit 1
fi
cd "$TOP"

rc=0
while IFS= read -r abs; do
    rel="${abs#"$PATCHES"/}"        # bootable/recovery/0001-....patch
    repo="$(dirname "$rel")"
    if [ ! -d "$repo" ]; then
        echo "SKIP   $rel  (target '$repo' not present)"; continue
    fi
    if git -C "$repo" apply --reverse --check "$abs" 2>/dev/null; then
        echo "OK     $rel  (already applied)"
    elif git -C "$repo" apply --check "$abs" 2>/dev/null; then
        git -C "$repo" apply "$abs"
        echo "APPLY  $rel"
    else
        echo "FAIL   $rel  (does not apply cleanly to '$repo')" >&2; rc=1
    fi
done < <(find "$PATCHES" -type f -name '*.patch' | sort)

exit $rc
