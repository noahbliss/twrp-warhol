#!/usr/bin/env bash
# Runs INSIDE the build container. See docker/fix-tree.sh for the why.
# NOTE: no `set -u`. AOSP's build/envsetup.sh references unset variables all over;
# with -u it aborts partway and never defines `m`/`lunch`, and then every round
# just logs "m: command not found" — which looks exactly like a mysterious
# non-module failure. Learned the hard way.
set -o pipefail
ROUNDS="${ROUNDS:-30}"
cd /aosp
. build/envsetup.sh >/dev/null 2>&1
if ! type -t m >/dev/null; then
    echo "FATAL: build/envsetup.sh did not define 'm' — sourcing it failed." >&2
    . build/envsetup.sh 2>&1 | tail -20 >&2
    exit 1
fi
lunch twrp_warhol-ap2a-eng >/dev/null 2>&1
if [ "$(get_build_var TARGET_PRODUCT 2>/dev/null)" != "twrp_warhol" ]; then
    echo "FATAL: lunch twrp_warhol-ap2a-eng did not take." >&2; exit 1
fi

for round in $(seq 1 "$ROUNDS"); do
    echo "===== round $round ====="
    # < /dev/null matters: soong/ninja read stdin, and without this they eat the
    # rest of a piped script (the bug that made the first version silently no-op).
    if m nothing < /dev/null > /tmp/boot.log 2>&1; then
        echo "BOOTSTRAP CLEAN after $((round-1)) rounds of removals"
        exit 0
    fi
    grep -oE '^error: [^ ]+/Android\.bp:' /tmp/boot.log \
        | sed 's/^error: //; s/:$//' | sort -u > /tmp/bad.txt
    if [ ! -s /tmp/bad.txt ]; then
        echo "bootstrap failed, but not on an undefined module. Last 30 lines:"
        tail -30 /tmp/boot.log
        exit 1
    fi
    n=0
    while read -r bp; do
        d="$(dirname "$bp")"
        case "$d" in
            .|build|build/*|device/*|bootable/*|system/core|system/core/*|external/lz4|external/lz4/*)
                echo "  REFUSING to remove build-critical path: $d"; exit 1 ;;
        esac
        undef=$(grep -m1 -F "$bp" /tmp/boot.log | grep -oE 'undefined module "[^"]+"')
        rm -rf "$d"
        echo "  removed  $d   (${undef:-?})"
        n=$((n+1))
    done < /tmp/bad.txt
    echo "  -- $n path(s) removed this round --"
done
echo "still failing after $ROUNDS rounds:"
grep -E "^error:" /tmp/boot.log | head -20
exit 1
