#!/usr/bin/env bash
# =============================================================================
# build-env.sh — bring up the linux/amd64 TWRP build environment on this Mac.
#
#   ./docker/build-env.sh up      start colima (vz + Rosetta) and build the image
#   ./docker/build-env.sh shell   drop into the container
#   ./docker/build-env.sh sync    repo init + sync twrp-14.1  (~25 GB, slow, once)
#   ./docker/build-env.sh build   lunch + mka vendorbootimage + repack
#   ./docker/build-env.sh df      disk accounting (watch this — it is the risk)
#   ./docker/build-env.sh down    stop colima
#
# DESIGN NOTE — where the AOSP tree lives.
#   It lives INSIDE the colima VM disk, not on a virtiofs bind mount. A repo sync
#   is ~500k small files and ninja stats all of them every build; over virtiofs
#   that is unusably slow. Two things ARE bind-mounted from the Mac, read-write:
#     device/xiaomi/warhol  so edits here are live in the build (a symlink would
#                           NOT work: build/make finds AndroidProducts.mk with
#                           `find`, which does not descend into symlinked dirs)
#   out/ deliberately stays INSIDE the VM volume — an AOSP out/ is write-heavy and
#   virtiofs would throttle the whole build. cmd_build copies the one artifact we
#   need back to the Mac afterwards.
#
# DISK — the real constraint on this machine.
#   host free right now is ~61 GiB. Budget:
#       twrp-14.1 shallow checkout   ~25 GB
#       out/ for a recovery target   ~15 GB
#       container image + ccache      ~8 GB
#       ------------------------------------
#       total                        ~48 GB
#   That fits, with roughly 13 GB of margin. `build-env.sh df` prints it.
# =============================================================================
set -euo pipefail

PROFILE=warhol
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=twrp-warhol-build
CPUS="${CPUS:-6}"
MEM="${MEM:-22}"        # GiB. Getting this right took two attempts in both directions:
                        #   20 GiB -> soong_build OOM-killed mid-analysis; the log
                        #             says only "Killed". ALLOW_MISSING_DEPENDENCIES
                        #             makes it worse (more modules stay live).
                        #   28 GiB -> analysis fits, but only 8 GiB left for macOS on
                        #             a 36 GiB host, and the HOST hit memory pressure.
                        # 22 GiB + a 16 GiB swapfile inside the VM (see cmd_up) is the
                        # balance: analysis can spill instead of dying, and macOS keeps
                        # 14 GiB.
DISK="${DISK:-90}"      # GiB — sparse, grows on demand

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }

cmd_up() {
    need colima
    if colima status -p "$PROFILE" >/dev/null 2>&1; then
        echo "colima profile '$PROFILE' already running"
    else
        echo "=== starting colima ($CPUS cpu / ${MEM}G / ${DISK}G disk, vz + Rosetta) ==="
        colima start -p "$PROFILE" \
            --vm-type vz --vz-rosetta \
            --cpu "$CPUS" --memory "$MEM" --disk "$DISK" \
            --mount-type virtiofs \
            --mount "$REPO_ROOT:w"
    fi
    # Swap: soong_build's analysis peak exceeds 20 GiB. Rather than commit more
    # host RAM, let it spill. swappiness=10 keeps it in RAM until genuinely tight.
    colima ssh -p "$PROFILE" -- sudo sh -c '
        if [ ! -f /var/lib/swapfile ]; then
            fallocate -l 16G /var/lib/swapfile 2>/dev/null || \
              dd if=/dev/zero of=/var/lib/swapfile bs=1M count=16384 status=none
            chmod 600 /var/lib/swapfile; mkswap /var/lib/swapfile >/dev/null 2>&1
        fi
        swapon /var/lib/swapfile 2>/dev/null; sysctl -w vm.swappiness=10 >/dev/null' 2>/dev/null || true

    export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"
    echo "=== verifying Rosetta (not QEMU) ==="
    if docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m | grep -q x86_64; then
        echo "  linux/amd64 containers run: OK"
    else
        echo "  WARNING: amd64 containers not working"; exit 1
    fi
    echo "=== building image ==="
    docker build --platform linux/amd64 -t "$IMAGE" "$REPO_ROOT/docker"
    echo
    echo "Ready. Next:  ./docker/build-env.sh sync"
}

dockerenv() { export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"; }

run() {
    dockerenv
    # -t only when stdout is a terminal: with it, running under a non-TTY (CI,
    # background job, `> log 2>&1`) fails with "cannot attach stdin to a
    # TTY-enabled container".
    local TTY=(-i); [ -t 1 ] && TTY=(-it)
    docker run --rm "${TTY[@]}" --platform linux/amd64 \
        -v twrp-aosp:/aosp \
        -v twrp-ccache:/ccache \
        -v "$REPO_ROOT:/warhol" \
        -v "$REPO_ROOT/device/xiaomi/warhol:/aosp/device/xiaomi/warhol" \
        -v "$REPO_ROOT/docker/scripts:/scripts:ro" \
        -w /aosp "$IMAGE" bash -lc "$1"
}

cmd_shell() { run "exec bash"; }

cmd_sync() {
    run '
set -e
if [ ! -d .repo ]; then
  repo init --depth=1 -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-14.1
fi
# Curate BEFORE syncing: skips several GB of download and avoids the Soong
# bootstrap failures that come from the manifest keeping consumers of projects
# it removes. See BUILDING.md.
bash /scripts/gen-local-manifest.sh
# -j4, not $(nproc): android.googlesource.com refuses connections under high
# concurrency and repo reports "Connection refused after 15s" for a scattered
# handful of projects. Retry in a loop — repo skips what is already synced, so
# each pass only fetches what actually failed.
for attempt in 1 2 3 4; do
  echo "=== repo sync attempt $attempt ==="
  if repo sync -c -j4 --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune; then
    echo "=== sync clean on attempt $attempt ==="; break
  fi
  echo "=== attempt $attempt had failures, retrying in 20s ==="; sleep 20
done
# Fail loudly rather than letting a half-synced tree reach the build.
if ! repo sync -c -j4 --no-clone-bundle --no-tags --optimized-fetch >/dev/null 2>&1; then
  echo "!!! sync STILL incomplete after retries" >&2; exit 1
fi
echo; echo "=== tree size ==="; du -sh /aosp
echo "=== device tree (bind-mounted from the Mac) ==="; ls device/xiaomi/warhol
'
}

cmd_build() {
    dockerenv
    docker rm -f warhol-build >/dev/null 2>&1 || true
    docker run --name warhol-build --platform linux/amd64 \
        -v twrp-aosp:/aosp -v twrp-ccache:/ccache \
        -v "$REPO_ROOT:/warhol" \
        -v "$REPO_ROOT/device/xiaomi/warhol:/aosp/device/xiaomi/warhol" \
        -v "$REPO_ROOT/docker/scripts:/scripts:ro" \
        -w /aosp "$IMAGE" bash -lc '
set -e
bash /scripts/prune-subdirs.sh
# ALLOW_MISSING_DEPENDENCIES is the mechanism AOSP provides for exactly this
# situation: a manifest that deliberately omits projects. Soong then tolerates
# references to absent modules instead of failing bootstrap. Without it, the TWRP
# twrp-14.1 tree does not bootstrap at all. Found in
# system/sepolicy/build/soong/validate_bindings.go, which checks
# ctx.Config().AllowMissingDependencies() before panicking. Should have been the
# FIRST thing tried — it removes most of the need to delete anything.
export ALLOW_MISSING_DEPENDENCIES=true
./device/xiaomi/warhol/patches/apply_patches.sh
. build/envsetup.sh
lunch twrp_warhol-ap2a-eng
# -j4, not $(nproc): under Rosetta, individual clang processes die SILENTLY at
# higher parallelism — a bare "FAILED:" line with no compiler diagnostic, no OOM
# in dmesg, no segfault, and the same file compiles fine when run by hand. Two
# builds died that way at -j8 (BatteryChargingPolicy.o, fiat_p256_adx_sqr.o).
# Lower concurrency trades wall-clock for not having to babysit retries.
# task_profiles.json must be built EXPLICITLY first. It is a prebuilt_etc that
# installs to system/etc/, and `mka vendorbootimage` never builds the system
# install set — so bootable/recovery/Android.mk fails copying it into the recovery
# root with "cp: bad .../system/etc/task_profiles.json: No such file or directory".
# Putting it in PRODUCT_PACKAGES is NOT enough for the same reason.
mka task_profiles.json -j4
mka vendorbootimage -j4
echo "=== built ==="; ls -la out/target/product/warhol/vendor_boot.img
'
    echo "=== copying the built vendor_boot out of the VM ==="
    mkdir -p "$REPO_ROOT/out/build"
    docker cp warhol-build:/aosp/out/target/product/warhol/vendor_boot.img \
              "$REPO_ROOT/out/build/vendor_boot-fresh.img"
    docker rm -f warhol-build >/dev/null 2>&1 || true
    ls -la "$REPO_ROOT/out/build/vendor_boot-fresh.img"

    echo "=== repacking on the host (grafts modules + touch fix) ==="
    "$REPO_ROOT/device/xiaomi/warhol/patch_touch_warhol.sh" \
        --twrp "$REPO_ROOT/out/build/vendor_boot-fresh.img" \
        --out  "$REPO_ROOT/out/twrp_warhol-vendor_boot.img"
}

cmd_df() {
    dockerenv
    echo "=== host ==="; df -h /Users/local | tail -1
    echo "=== colima VM ==="
    colima ssh -p "$PROFILE" -- df -h / 2>/dev/null | tail -2 || true
    echo "=== docker volumes ==="
    docker system df -v 2>/dev/null | sed -n '/VOLUME NAME/,/^$/p' || true
}

cmd_down() { colima stop -p "$PROFILE"; }

case "${1:-}" in
    up) cmd_up ;; shell) cmd_shell ;; sync) cmd_sync ;;
    build) cmd_build ;; df) cmd_df ;; down) cmd_down ;;
    *) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
