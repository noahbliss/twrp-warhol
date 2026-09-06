#!/system/bin/sh
# ============================================================================
# touch_init.sh — on-device, PC-free bring-up of the Xiaomi THP touch HAL
#                 inside TWRP. Baked into the recovery ramdisk at /thp/ and
#                 launched by init.recovery.mt6993.rc (recovery-only).
#
# This is the self-contained version of recovery_userspace/touch_bringup.sh:
# it mounts the stock system/vendor/odm partitions, fixes up the APEX linker,
# and starts servicemanager + vendor.xiaomi.hw.touchfeature-service under the
# LD_PRELOAD shims so the Goodix GT9895 THP HAL computes finger coordinates and
# injects them on /dev/input. See recovery_userspace/README.md for the theory.
#
# Everything here mirrors the proven manual recipe (2026-06-13). Robust against
# init timing: it waits for the touch IC node and the dynamic-partition mapper
# devices before proceeding.
# ============================================================================
THP=/thp
LOG=/tmp/touch_init.log
exec >>"$LOG" 2>&1
echo "=== touch_init start ==="

SLOT="$(getprop ro.boot.slot_suffix)"
[ -z "$SLOT" ] && SLOT=_a
ODM=/dev/block/mapper/odm$SLOT
VENDOR=/dev/block/mapper/vendor$SLOT
SYSTEM=/dev/block/mapper/system$SLOT
echo "slot=$SLOT"

# Wait for the dynamic-partition mapper nodes (TWRP sets these up) and the touch
# IC char node (created when goodix_core_warhol loads via modules.load.recovery).
i=0
while [ $i -lt 100 ]; do
    [ -e "$SYSTEM" ] && [ -e "$VENDOR" ] && [ -e "$ODM" ] && break
    sleep 1; i=$((i+1))
done
i=0
while [ ! -e /dev/xiaomi-touch ] && [ $i -lt 100 ]; do sleep 1; i=$((i+1)); done
echo "mapper+IC ready (xiaomi-touch: $([ -e /dev/xiaomi-touch ] && echo yes || echo NO))"

# Mount the stock partitions. odm goes to the REAL /odm path (the HAL hardcodes
# /odm/bin, /odm/lib64, /odm/firmware, /odm/etc); system/vendor are reached via
# LD_LIBRARY_PATH only (do NOT overmount TWRP's live /vendor).
mkdir -p /mnt_sys /mnt_vendor /odm
mountpoint -q /mnt_sys    || mount -t erofs -o ro "$SYSTEM" /mnt_sys    || echo "WARN mount system"
mountpoint -q /mnt_vendor || mount -t erofs -o ro "$VENDOR" /mnt_vendor || echo "WARN mount vendor"
mountpoint -q /odm        || mount -t erofs -o ro "$ODM" /odm           || echo "WARN mount odm"

# APEX linker symlink -> TWRP's REAL linker64 (NOT /mnt_sys's, which loops back
# into /apex => ELOOP). Mandatory for the stock binaries to exec.
mkdir -p /apex/com.android.runtime/bin /system/bin/bootstrap /apex/com.android.vintf/etc/vintf
ln -sf /system/bin/linker64 /apex/com.android.runtime/bin/linker64
ln -sf /system/bin/linker64 /system/bin/bootstrap/linker64
cp /mnt_vendor/etc/vintf/manifest.xml /apex/com.android.vintf/etc/vintf/ 2>/dev/null

# binder context for our servicemanager.
mountpoint -q /dev/binderfs || { mkdir -p /dev/binderfs; mount -t binder binder /dev/binderfs; }
[ -e /dev/binder ] || ln -sf /dev/binderfs/binder /dev/binder

# System libs FIRST so the system libbinder_ndk resolves against the system
# libbinder (get_trace_enabled_tags); then vendor-only libs; then odm.
LLP=/mnt_sys/system/lib64:/mnt_vendor/lib64:/odm/lib64

# servicemanager (from system_a) under sm_stab3 -> become context manager.
kill -9 $(pidof servicemanager) 2>/dev/null
LD_PRELOAD=$THP/sm_stab3.so LD_LIBRARY_PATH=$LLP /mnt_sys/system/bin/servicemanager >/tmp/sm_touch.log 2>&1 &
i=0
while [ $i -lt 25 ]; do
    grep -q "became CM" /tmp/sm_touch.log 2>/dev/null && break
    sleep 1; i=$((i+1))
done
echo "SM became CM: $(grep -q 'became CM' /tmp/sm_touch.log 2>/dev/null && echo yes || echo NO) (waited ${i}s)"
setprop servicemanager.ready true
setprop sys.boot_completed 1

# the THP touch HAL under touch_shim (NULL-stubs the absent aux HALs).
# EXEC it (do NOT background + exit): this replaces the shell, so the init
# service's main process BECOMES the HAL and stays alive. If the script merely
# backgrounded it and then exited, init would tear down the whole service
# process group (oneshot/stop semantics) — killing both the HAL and the
# backgrounded servicemanager, leaving no touch (exactly the failure we hit).
# servicemanager keeps running as a child of this exec'd process.
kill -9 $(pidof vendor.xiaomi.hw.touchfeature-service) 2>/dev/null
echo "=== touch_init: exec HAL (keeps the service alive) ==="
exec env LD_PRELOAD=$THP/touch_shim.so LD_LIBRARY_PATH=$LLP \
    /odm/bin/hw/vendor.xiaomi.hw.touchfeature-service >>/tmp/touch.log 2>&1
