#!/usr/bin/env bash
# Runs INSIDE the container after sync. Removes a SHORT, EXPLICIT, JUSTIFIED list
# of subdirectories whose Android.bp depends on modules that TWRP's manifest
# removes the providers for.
#
# This replaces the blind fix-tree.sh loop for the residual cases. That loop was
# the wrong tool: once it starts deleting directories it also deletes module
# *definitions*, and then cascades on its own damage — one run turned 13 real
# errors into 86 deletions. Everything below is named deliberately and checked.
#
# Each entry: <path>  # <missing module>  (<provider TWRP removes>)
set -euo pipefail
cd /aosp

PRUNE=(
  # NNAPI HAL. Provider packages/modules/NeuralNetworks is removed by TWRP's
  # remove-minimal.xml. A recovery image has no NNAPI consumer.
  "hardware/interfaces/neuralnetworks            neuralnetworks_utils_defaults"
  # BPF loader daemon. No BPF networking in recovery.
  "packages/modules/Connectivity/netbpfload      bpf_defaults"
  # BPF header test lib — same missing bpf_defaults provider.
  "packages/modules/Connectivity/staticlibs/native/bpf_headers   bpf_defaults"
  # Berberis binary translation (x86 apps on ARM). Provider
  # frameworks/libs/native_bridge_support is removed by TWRP. Irrelevant to recovery.
  "frameworks/libs/binary_translation           native_bridge_proxy_libc_defaults"
  # Automotive HALs — vhalclient_defaults comes from packages/services/Car, which
  # TWRP removes and which cannot be restored cheaply (it pulls an unbounded chain).
  # This is a phone; nothing in a recovery image touches the vehicle HAL.
  "hardware/interfaces/automotive                vhalclient_defaults"
  # The one CTS car test, orphaned by the same missing Car project. Leaf target.
  "cts/tests/tests/car                           car-framework-aconfig-libraries"
  "cts/tests/tests/car_permission_tests          car-framework-aconfig-libraries"
  "cts/tests/tests/car_builtin                   car-framework-aconfig-libraries"
  # A single leaf CVE regression test needing sts_defaults from test/sts, which is
  # not in the TWRP manifest at all (no provider to restore). Verified to be the
  # ONLY Android.bp under cts/ referencing sts_defaults, so removing it cannot
  # cascade — unlike the 184 sibling CVE dirs, which are untouched.
  "cts/hostsidetests/securitybulletin/securityPatch/CVE-2023-40114   sts_defaults"
  # NOTE: hardware/interfaces/automotive was in this list and has been REMOVED
  # from it. It failed only because packages/services/Car was missing; Car is now
  # added back (see gen-local-manifest.sh ADD_BACK), and the two satisfy each
  # other — Car's vhalclient_defaults needs automotive's VehicleHalInterfaceDefaults
  # and vice versa. Pruning either one breaks the other.
  # Secretkeeper VTS. Needs rdroidtest.defaults from packages/modules/Virtualization,
  # which TWRP removes. VTS is never built for a recovery target.
  "hardware/interfaces/security/secretkeeper/aidl/vts   rdroidtest.defaults"
)

for entry in "${PRUNE[@]}"; do
    set -- $entry
    path="$1"; why="${2:-}"
    if [ -e "$path" ]; then
        rm -rf "$path"
        echo "  pruned  $path   (missing: $why)"
    else
        echo "  absent  $path"
    fi
done
