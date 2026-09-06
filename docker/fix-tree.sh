#!/usr/bin/env bash
# =============================================================================
# ⚠️  DEPRECATED — DO NOT USE. Kept only because BUILDING.md refers to it.
#
# This loop deletes the directory containing each offending Android.bp and
# repeats. That is the WRONG approach: once it starts deleting directories it
# also deletes module *definitions* other projects need, and it cascades on its
# own damage. Measured here: it turned 13 real errors into 86 deletions, twice.
#
# Use instead:
#   1. ALLOW_MISSING_DEPENDENCIES=true   (AOSP's own mechanism; fixes nearly all
#                                         of it — see BUILDING.md)
#   2. docker/scripts/prune-subdirs.sh   (a short, explicit, justified list)
#
# fix-tree.sh — converge the synced tree to a state where Soong can bootstrap.
#
# THE PROBLEM (not something you did wrong):
#   TWRP's minimal manifest removes projects that projects it *keeps* still
#   depend on. Soong validates every Android.bp in the tree during bootstrap, so
#   the build dies with a pile of
#       "X" depends on undefined module "Y"
#   before it ever looks at the recovery target. Example: system/secretkeeper is
#   kept but needs avf_build_flags_rust from packages/modules/Virtualization,
#   which remove-minimal.xml drops entirely.
#
# THE FIX:
#   Delete the directory containing each offending Android.bp and re-run. All of
#   them are test harnesses, VTS suites, emulator or mainline bits that a
#   recovery image never touches. This loops until bootstrap is clean, logging
#   every removal so the result is auditable rather than magic.
#
#   Removals are recorded to device/xiaomi/warhol/local_manifest/ so a future
#   clean sync can drop the same projects up front via <remove-project>.
#
#     ./docker/fix-tree.sh            # up to 12 rounds
#     ROUNDS=20 ./docker/fix-tree.sh
# =============================================================================
set -euo pipefail

PROFILE=warhol
IMAGE=twrp-warhol-build
ROUNDS="${ROUNDS:-30}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO_ROOT/out/fix-tree.log"
mkdir -p "$REPO_ROOT/out"
export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"

docker run --rm -i --platform linux/amd64 \
    -v twrp-aosp:/aosp -v twrp-ccache:/ccache \
    -v "$REPO_ROOT/device/xiaomi/warhol:/aosp/device/xiaomi/warhol" \
    -v "$REPO_ROOT/docker/scripts:/scripts:ro" \
    -e ROUNDS="$ROUNDS" \
    -w /aosp "$IMAGE" bash /scripts/fix-tree-inner.sh 2>&1 | tee "$LOG"
