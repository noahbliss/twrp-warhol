# `recovery_userspace/` — FALLBACK: running the Goodix THP HAL inside TWRP

**Status: untested on warhol.** Ported from
[`chagall`](https://github.com/Advnirr/twrp_device_xiaomi_chagall) (Xiaomi 17T,
Novatek NT38771). Try the *primary* path first — see below.

## Two ways to get touch, in order of preference

### 1. Primary: keep the IC out of THP mode (cheap, no userspace HAL)

warhol's panel is THP: `goodix_core_warhol.ko` normally only ships raw
capacitance frames and a userspace HAL on `odm`
(`vendor.xiaomi.hw.touchfeature-service` + `libtouchreport_alg` +
`libtensorflowlite_touch_c`, driven by `/odm/firmware/warhol_gtp_thp_config.ini`)
computes the finger coordinates. That HAL does not exist in a standalone TWRP.

But the Xiaomi touch framework can be told to stay out of raw mode, and then the
kernel driver reports input events itself. Two things are needed *together*:

* `echo 0 > /sys/class/touch/touch_dev/enable_touch_raw` — done by
  `init.recovery.mt6993.rc`.
* neutering `xiaomi_drm_panel_notifier_callback` in `xiaomi_touch_warhol.ko`, so
  the display driver cannot switch the IC back into THP/doze mode behind our
  back — done by `tools/patch_thp_notifier.py`, invoked from
  `patch_touch_warhol.sh`.

On degas (Xiaomi 14T, also Goodix) and chagall this combination produced working
touch. warhol uses the same `xiaomi_touch_*` framework — the symbol is present at
`.text+0x4940` in `xiaomi_touch_warhol.ko` and the patcher finds it by symbol, so
it survives a module rebuild.

**Verify on device:** `adb shell getevent -lt` while swiping. If `ABS_MT_POSITION_X/Y`
events appear, you are done and this directory is not needed.

### 2. Fallback: run the stock THP HAL inside recovery

If the primary path yields no events, bring the stock HAL up in recovery. The
core coordinate path uses no binder — the service reads raw frames from
`/dev/xiaomi-touch` and injects on `/dev/input`; its binder dependencies are
auxiliary features that get NULL-stubbed:

| Binder dep | Feature | In recovery |
|---|---|---|
| `android.frameworks.sensorservice`, `android.hardware.sensors` | proximity / palm reject | NULL-stub |
| `vendor.xiaomi.hardware.framecapturemanager` | raw frame capture / diagnostics | NULL-stub |
| `vendor.xiaomi.hardware.fingerprintextension` | FOD | NULL-stub |
| `vendor.mediatek.hardware.mtkpower` | touch boost | NULL-stub |
| `vendor.xiaomi.hw.touchfeature` (its own) | the ITouchFeature it registers | real SM |

### Layout

```
shims/
  sm_stab3.c     servicemanager LD_PRELOAD shim (become context manager)
  bind_mount.c   static MS_BIND helper
  touch_shim.c   LD_PRELOAD for touchfeature-service: NULL-stub the aux HALs,
                 pass VINTF stability, abort -> thread-exit, trace the hw nodes
touch_init.sh    on-device bring-up: mount system/vendor/odm, fix the APEX
                 linker, start servicemanager + the HAL under the shims
```

To use it, cross-compile the shims to `/thp/*.so` in the ramdisk and add to
`init.recovery.mt6993.rc`:

```
on boot
    start thp-touch

service thp-touch /system/bin/sh /thp/touch_init.sh
    class late_start
    user root
    group root system
    seclabel u:r:recovery:s0
    # NOT oneshot — touch_init.sh exec's the HAL as its last step, so this
    # process *becomes* the HAL and must stay alive.
```

### warhol-specific notes vs chagall

* Touch IC is **Goodix GT9895**, driver `goodix_core_warhol.ko` (matches DT
  `compatible = "xiaomi,touch-spi"`), framework `xiaomi_touch_warhol.ko`.
  `gt9895.ko` in `vendor_dlkm` is the legacy `mtk-tpd3` path and is *not* used.
* THP config: `/odm/firmware/warhol_gtp_thp_config.ini`.
* Touch firmware: `goodix_firmware_warhol.bin`, `goodix_cfg_group_warhol.bin`
  (already baked into the ramdisk at `/vendor/firmware` and `/lib/firmware`,
  which are the two paths in the stock `firmware_class.path` cmdline).
* Panel is 1280 x 2772 (`goodix,panel-max-x` 0x1f3ff / `panel-max-y` 0x43acf with
  `super-resolution-factor` 100).
