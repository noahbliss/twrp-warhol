#!/usr/bin/env bash
# =============================================================================
# prune-tree.sh — reclaim disk in the synced AOSP tree.
#
#     ./docker/prune-tree.sh              show what would be freed
#     ./docker/prune-tree.sh --go         actually delete
#     ./docker/prune-tree.sh --go --aggressive
#     ./docker/prune-tree.sh --go --drop-git    the big one, see below
#
# WHY: a shallow twrp-14.1 sync lands at ~53 GB on this machine, and the Mac only
# has ~59 GiB free for the VM disk to grow into. out/ needs another 10-20 GB.
# Without pruning the build runs the disk to zero mid-link.
#
# ORDER MATTERS: run this AFTER `sync`, never before. `repo sync` checks projects
# out clean, so anything deleted here comes straight back on the next sync.
# Re-run this after any future sync.
#
# What gets removed, and why it is safe for a recovery-only target:
#
#   prebuilts/clang/host/linux-x86/clang-*   all but the version Soong actually
#                                            selects (read live from
#                                            build/soong/cc/config/global.go) and
#                                            clang-stable. AOSP ships five older
#                                            toolchains for other branches; this
#                                            build compiles with exactly one, and
#                                            TARGET_NO_KERNEL means we never build
#                                            a kernel with an older one either.
#
#   prebuilts/abi-dumps                      reference ABI dumps consumed by
#                                            header-abi-diff during VNDK ABI
#                                            checks. A TWRP recovery target does
#                                            not run them. (--aggressive only.)
#
#   prebuilts/**/darwin-x86                  macOS host toolchains. We build in a
#                                            linux/amd64 container. (--aggressive.)
#
#   .repo/project-objects                    (--drop-git) BY FAR the biggest win.
#         Measured on this tree: 57 GB of git objects backing a 29 GB working
#         tree. A build reads checked-out FILES; it never reads git history.
#         Deleting this leaves every working tree intact and fully buildable.
#
#         THE TRADE: `repo sync` can no longer work incrementally — a later sync
#         re-clones from scratch. Do this once the tree is complete and you are
#         in build-iterate mode. Verify completeness first:
#             repo sync -c -j4 --no-clone-bundle --no-tags   # must come back clean
# =============================================================================
set -euo pipefail

PROFILE=warhol
GO=0; AGGRESSIVE=0; DROPGIT=0
for a in "$@"; do
    case "$a" in
        --go) GO=1 ;;
        --aggressive) AGGRESSIVE=1 ;;
        --drop-git) DROPGIT=1 ;;
        *) echo "unknown flag: $a" >&2; exit 1 ;;
    esac
done

export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"
IMAGE=twrp-warhol-build

docker run --rm -i --platform linux/amd64 -v twrp-aosp:/aosp -w /aosp "$IMAGE" \
    bash -s -- "$GO" "$AGGRESSIVE" "$DROPGIT" <<'INNER'
set -euo pipefail
GO="$1"; AGGRESSIVE="$2"; DROPGIT="$3"
total=0

plan() {   # plan <path> <reason>
    [ -e "$1" ] || return 0
    local sz; sz=$(du -sm "$1" 2>/dev/null | cut -f1)
    total=$((total + sz))
    printf '  %6s MB  %-58s %s\n' "$sz" "$1" "$2"
    [ "$GO" = 1 ] && rm -rf "$1"
    return 0
}

echo "=== clang toolchains ==="
KEEP=$(grep -m1 'ClangDefaultVersion *=' build/soong/cc/config/global.go | sed 's/.*"\(.*\)".*/\1/')
echo "  Soong selects: $KEEP  (keeping that + clang-stable)"
for d in prebuilts/clang/host/linux-x86/clang-*; do
    b=$(basename "$d")
    [ "$b" = "$KEEP" ] && continue
    [ "$b" = "clang-stable" ] && continue
    plan "$d" "unused toolchain"
done

if [ "$AGGRESSIVE" = 1 ]; then
    echo "=== aggressive ==="
    plan prebuilts/abi-dumps "VNDK ABI reference dumps; not used by a recovery target"
    # NOT prebuilts/misc/darwin-x86: it is ~1 MB and prebuilts/misc/Android.bp's
    # license module references prebuilts/misc/darwin-x86/yasm/COPYING, so deleting
    # it fails the build with
    #   module "prebuilts_misc_license": module source path ... does not exist
    # The darwin trees worth removing are jdk/build-tools/clang-tools (hundreds of MB).
    while IFS= read -r d; do
        case "$d" in prebuilts/misc/darwin-x86) continue ;; esac
        plan "$d" "macOS host toolchain"
    done < <(find prebuilts -maxdepth 4 -type d -name 'darwin-x86' 2>/dev/null)
fi

if [ "$DROPGIT" = 1 ]; then
    echo "=== git object store ==="
    plan .repo/project-objects "git history; a build never reads it (one-way: future syncs re-clone)"
    plan .repo/TRACE_FILE "repo trace log"
fi

echo
if [ "$GO" = 1 ]; then
    echo "FREED ~${total} MB"
    echo "NOTE: prebuilts/clang and friends are now dirty working trees. That is"
    echo "      expected. A future 'repo sync' restores them — re-run this after."
else
    echo "WOULD FREE ~${total} MB   (re-run with --go to do it)"
fi
echo
echo "=== tree size now ==="; du -sh /aosp
INNER

# Deleting inside the guest does NOT shrink the VM's disk file on the host — the
# sparse file keeps every block it ever touched. fstrim hands the freed blocks
# back. Measured: 81 GB -> 43 GB host-side, i.e. 39 GiB returned, from a prune
# that had already "freed" the space inside the guest.
if [ "$GO" = 1 ]; then
    echo "=== fstrim (returns freed blocks to the host disk image) ==="
    before=$(du -sm "$HOME/.colima/_lima/_disks/colima-$PROFILE" 2>/dev/null | cut -f1)
    colima ssh -p "$PROFILE" -- sudo fstrim -v /var/lib/docker 2>&1 | tail -2
    after=$(du -sm "$HOME/.colima/_lima/_disks/colima-$PROFILE" 2>/dev/null | cut -f1)
    [ -n "$before" ] && [ -n "$after" ] && echo "  host disk image: ${before} MB -> ${after} MB"
    df -h "$HOME" | tail -1
fi
