# LineageOS hardware support — inventory and feasibility

Source: `tools/warhol-hw-inventory.sh` run against the live device (read-only),
plus the extracted `product` / `mi_ext` images. Raw output in
`out/hw-inventory/<stamp>/`.

This is groundwork, not a plan of record — LineageOS for warhol does not exist
yet. The point is to know *now* what the blob surface looks like, while the
firmware is unpacked and the phone is stock.

## The single most important structural fact

```
ro.system.build.fingerprint   = Xiaomi/missi/missi:16/...
ro.product.build.fingerprint  = Xiaomi/warhol/missi:16/...
ro.vendor.build.fingerprint   = Xiaomi/warhol_global/warhol:16/...
ro.odm.build.fingerprint      = Xiaomi/warhol_global/warhol:16/...
```

**`missi` is Xiaomi's shared system/product base**; only `vendor` and `odm` are
warhol-specific. So the device-specific blob surface is `vendor` + `odm` +
`vendor_dlkm` + `mi_ext`, and `system`/`product` are mostly Xiaomi's common HyperOS
userspace that LineageOS replaces wholesale.

Combined with the kernel being **stock GKI with everything in `vendor_dlkm`**
(see `01-device-facts.md`), this is the friendly case for a modern MTK port: reuse
the stock `vendor`/`odm` partitions and the GKI kernel largely as-is, and build
only the Lineage system side against them.

## HAL surface

150 distinct HAL interfaces declared across `/vendor/etc/vintf/manifest*` (80
fragments) and `/odm/etc/vintf/manifest/` (18 fragments). Roughly 70 are non-AOSP
— MediaTek and Xiaomi. Those are the porting work, because the framework refuses
to boot if a declared HAL is missing (or you must strip the declaration).

Broad split:

* **`vendor.mediatek.hardware.*`** (~30) — aee, atci, audio, camera.{aovservice,
  atms,bgservice,isphal,uievent}, composer_ext, engineermode, gnss{,.batching},
  gpuserv, lbs, log, mdmonitor, apuware.{aiste,apusys,utils}, dmc, …
  These come with the stock `vendor` image and mostly work if `vendor` is reused.
* **`vendor.xiaomi.hardware.*` / `vendor.xiaomi.aidl.*`** (~40) — the HyperOS-only
  surface: `displayfeature_aidl`, `fingerprintextension`, `micharge`, `mlipay`,
  `misys.{common,core}`, `mrm`, `postprocservice`, `quickcamera`, `radio`,
  `radio.cdc`, `seaaudio`, `soterservice`, `touchfeature`, `citsensorservice`, …
  **Most of these have no AOSP consumer.** For LineageOS the usual approach is to
  ship the HAL binaries so the manifest stays satisfied, and simply not use them —
  except where a feature depends on one (FOD → `fingerprintextension`,
  touch → `touchfeature`).
* **`vendor.dolby.dms` / `vendor.dolby.dvs`** — Dolby audio. Licensed; a Lineage
  build normally drops it and loses Dolby processing.

## Per subsystem

### Radios — mandatory, and the good news is it is conventional MTK
```
HALs   android.hardware.radio.{data,ims,messaging,modem,network,sap,sim,voice}-V4
       + radio.config-V4, plus vendor.xiaomi.hardware.radio{,.cdc}
blobs  libgwsd-ril.so, libgwsdv2-ril.so, libccci_util{,_sys}.so, lib_remote_simlock.so
init   ccci_mdinit (running)
data   modem_a/b (200 MiB each), md_sec, nvdata, nvcfg, protect1/2
```
This is the standard MediaTek CCCI/RIL stack. It generally works on Lineage when
the stock `vendor` partition and the modem partition are left alone.

**The thing that would be unrecoverable is calibration, and it is already
handled**: `nvdata`, `nvcfg`, `protect1`, `protect2`, `md_sec`, `nvram`, `proinfo`
are in the recon backup. IMEI and RF calibration live there. Never format them.

### Fingerprint — Goodix FOD, and the tree values are already known
```
persist.vendor.sys.fp.vendor            goodix_fod
ro.hardware.fp.fod                      true         (location "low")
persist.vendor.sys.fp.fod.location.X_Y  535,2413
persist.vendor.sys.fp.fod.size.width_height  210,210
ro.hardware.fp.fod.touch.ctl.version    2.0
HAL   /odm/lib64/hw/fingerprint.goodix_fod.so
      android.hardware.biometrics.fingerprint-V4-ndk
ext   vendor.xiaomi.hardware.fingerprintextension (V1 + @1.0)
```
Those four numbers are exactly what a Lineage device tree needs for the FOD
overlay, so that part is already answered. In-display FOD on Lineage also needs
the display-side dimming path (`vendor.xiaomi.hardware.displayfeature_aidl`) — the
usual sticking point, not the sensor itself.

Note `com.fingerprints.*` (FPC) and `vendor.qti.hardware.fingerprint` libs are
also present; those are `missi` common-image leftovers for other devices, not used
here.

### IR blaster — confirmed present, and easy
```
ro.hardware.consumerir = common
/vendor/lib64/hw/consumerir.common.so
/vendor/bin/hw/android.hardware.ir-service.example
feature:android.hardware.consumerir
```
Ship the `.so`, the AIDL service and the feature XML. This is the lowest-effort
item on the list.

### Camera — the hard one
```
/product/priv-app/MiuiCamera     145 MB
/odm/etc/camera                  348 MB   (tuning + ML models)
/vendor/etc/camera                86 MB   (Vega_*.model, af_*.minn NN models)
/odm/lib64/camera                 18 MB   (plugins/, dynamicplugins/, preloadplugins/)
                                 ------
                                 ~600 MB
HAL   camerahalserver (MTK) + vendor.xiaomi.hardware.dynamiccameraserver
      vendor.xiaomi.hardware.camera.{mivimessage,synthetic}, quickcamera
      vendor.mediatek.hardware.camera.{isphal,bgservice,aovservice,atms,uievent}
```
See the dedicated section below.

### Connectivity and flashlight — all four confirmed present

```
Bluetooth  android.hardware.bluetooth-service-mediatek
           + bluetooth.finder-service-mediatek, bluetooth.ranging-service.mediatek
           features: bluetooth, bluetooth_le
Wi-Fi      android.hardware.wifi-service-lazy
           features: wifi, wifi.aware, wifi.direct, wifi.passpoint
combo chip MT6653  (shared BT+Wi-Fi firmware in /vendor/firmware:
           BT_RAM_CODE_MT6653_*, WIFI_MT6653_PATCH_MCU_*, WIFI_MT6653_PHY_RAM_CODE_*)
kernel     wmt_chrdev_wifi_connac3, conninfra, connadp, connfem, uarthub_drv
NFC        NXP SN100U — android.hardware.nqnfc-service.nxp
           /vendor/etc/libnfc-nxp-pnscr.conf, sn100u_nfcon.pnscr
           features: nfc, nfc.any, nfc.hce, nfc.hcef, nfc.ese, nfc.uicc
eSE        android.hardware.secure_element@1.2-service-mediatek
           + vendor.xiaomi.hardware.secure_element-service
Flashlight feature:android.hardware.camera.flash; camera HAL: "Has a flash unit: true"
           kernel: flashlight, dual_leds_mt6379pmic, leds_mt6379, v4l2_flash_led_class
           dual-LED via the MT6379 PMIC, exposed through V4L2 + the camera HAL
           (no /sys/class/leds/flash* node — that is the modern path, not a problem)
```

All conventional MediaTek/NXP, all satisfied by reusing the stock `vendor` partition.
NFC having `hce` + `hcef` + `ese` means the hardware is Google-Wallet capable — whether
Wallet *works* is a Play Integrity question, not a hardware one (see `09`).

### GPU — Arm Immortalis, Mali blob + MediaTek wrapper

```
renderer   Mali-G1-Ultra MC12, OpenGL ES 3.2, driver v1.r54p1
props      ro.hardware.egl=mali   ro.hardware.vulkan=mali   ro.opengles.version=196610
blobs      /vendor/lib64/egl/libGLES_mali.so
           libGLES_meow.so + libMEOW_{data,gift,mfrc_ext,qt,trace}.so   (MTK wrapper layer)
           arm.mali.platform-V2-ndk.so, libmtk_mali_user.so, libarm_mali_config_sysprops.so
           per-SoC dirs: mt6789 mt6881 mt6895 mt6991 mt6993
kernel     mali_kbase in vendor_dlkm
```

Self-contained userspace blob set + kernel module. Reuse `vendor` and it works —
the usual, low-risk case. MEOW is MediaTek's GPU wrapper (frame pacing / memory);
it rides along with the vendor image.

### NPU / APU — MediaTek NeuroPilot

```
HAL     vendor.mediatek.hardware.neuropilot.neuronservice.neuronservice.mediatek
        + vendor.mediatek.hardware.apuware.{aiste,apusys,utils}  (IAisteService,
          INeuronApusys, IApuwareUtils in VINTF)
libs    libapusys.so, libapu_mdw{,_batch}.so, libapudcutils.so, libaiste.so,
        libmdla_ut.so (MDLA = MTK deep-learning accelerator),
        libmvpu_* (MVPU = MTK vector processing unit), libarmnn_ndk.mtk.vndk.so
        APUWare{Aiste,Apusys,Utils}AidlServer.so
dev     /dev/apusys, /dev/apuext, /dev/apusys_apummu
fw      apusys_a/b and mvpu_algo_a/b partitions
```

Matters more than it looks: **the camera pipeline leans on it.** `/vendor/etc/camera`
carries `.minn` / `.model` neural nets (`af_class_*.minn`, `Vega_*.model`) that run on
the APU. So NPU bring-up is a prerequisite for full camera quality, not an optional
extra. NNAPI-using apps also land here.

### Dolby — spans vendor AND system, which is what makes it awkward

```
vendor half (comes free if stock vendor is reused)
  /vendor/bin/hw/vendor.dolby.dms.service
  /vendor/bin/hw/vendor.dolby.media.c2-default-service-dax     (Atmos / DAX audio)
  /vendor/bin/hw/vendor.dolby.media.c2-service-vision          (Dolby Vision)
  /vendor/etc/dolby/dax-default{,-spatializer}.xml, /vendor/etc/dolby_vision.cfg
  /vendor/etc/media_codecs_dolby_audio.xml
  /vendor/etc/audio_effects_config.xml   <- where the DAX effect is registered
  VINTF: vendor.dolby.dms, vendor.dolby.dvs
system / system_ext half (LineageOS will NOT have these)
  /system_ext/lib64/libdolbyeffect.so, libdolbyacse_jni.so
  /system/lib64/libdolbyui.so, libdolbyproxyandroid.so
```

There is **no Dolby settings APK** — the UI is baked into MIUI's sound settings, so a
Lineage build gets no Dolby control panel even if the audio path works.

As a Magisk module this is plausible but narrower than the camera one: the vendor half
already exists, so the module supplies the `system`/`system_ext` libs and the effect
registration. The realistic result is **Atmos/DAX audio processing with no UI** (or a
third-party control app), and **Dolby Vision video probably not working** — DV needs
the display pipeline plus licensing, and is the first thing to break off-stock.

Licensing note: Dolby is proprietary and licensed per-device. Redistributing the blobs
publicly is not appropriate; a personal-use module is a different matter.

### Others, briefly
* **Audio** — MTK audio HAL + `vendor.mediatek.hardware.audio`, plus
  `vendor.xiaomi.hardware.seaaudio` and two `speaker_amp` I2C devices in the dtbo.
  Dolby will be lost.
* **Sensors** — MTK SCP-based, plus `vendor.xiaomi.sensor.citsensorservice`.
  Sensor calibration lives in `persist`/`nvdata` (backed up).
* **NFC** — NXP (`nxp@28` in the dtbo), plus `android.se.omapi` for the secure
  element. Conventional.
* **Wi-Fi / BT** — MTK `connsys` / `conninfra` / `wmt_chrdev_wifi_connac3`,
  firmware in `connsys_*` partitions. Conventional MTK.
* **GPU/display** — `mediatek-drm`, `vendor.mediatek.hardware.composer_ext`,
  `vendor.xiaomi.hardware.display.mihwcextension`. The Xiaomi display extension is
  where FOD dimming and HDR/brightness features hang.
* **Vibrator** — `aw8697_haptic` (Awinic), rich effect tables in the dtbo. Lineage
  usually ends up with a simpler effect set.

## MiuiCamera on LineageOS, honestly

A Magisk module is the right delivery mechanism — systemless, reversible, and it
keeps the camera stack out of the ROM. But the module is the easy half.

**What makes it hard is not packaging, it is that MiuiCamera is not a normal app.**
It calls into `miui.*` framework classes that exist in HyperOS's patched
`framework.jar`/`services.jar` and simply are not in LineageOS. That is why
community MiuiCamera ports are per-device, fragile, and usually ship a shim.

Realistic outcomes, best to worst:

1. **Port works with reduced features.** Basic capture and video work; Night mode,
   HDR, portrait and the AI scene stuff — the parts that live in the `mialgo` /
   `/odm/lib64/camera/plugins` path behind `camerahalserver` — degrade or fail.
   This is the common result.
2. **Port needs a `miui-framework` shim** to satisfy the missing classes. Doable,
   ongoing maintenance burden against every Lineage update.
3. **Does not work; fall back to a third-party camera.** Note GCam ports are
   historically weak on MediaTek because they lean on Camera2 features MTK
   under-implements. An Open Camera / stock AOSP camera against the MTK HAL is the
   dependable floor, with noticeably worse output.

**This is a strong argument for the dual-boot goal.** If MiuiCamera cannot be made
to work well on Lineage, dual-boot lets HyperOS stay on the device purely as the
camera OS. Worth treating camera parity and dual-boot as one decision rather than
two.

Suggested order when the time comes: get the MTK camera HAL working under Lineage
with a plain camera app **first** (proves `camerahalserver`, sensors, tuning), and
only then attempt MiuiCamera on top. Attempting MiuiCamera before the underlying
HAL is proven conflates two very different failures.

## Strategy: this device is fully Treble-compliant, which changes the approach

Measured on the device 2026-09-06:

```
ro.treble.enabled                 true          <- the thing that matters
ro.boot.dynamic_partitions        true
ro.virtual_ab.enabled             true  (+ compression)
ro.product.first_api_level        36            (Android 16)
ro.board.api_level                202504
gsi_tool / gsid / com.android.dynsystem   all present, status "normal"
```

Two consequences:

**1. A GSI can be booted with zero risk, via DSU.** Dynamic System Updates
installs a generic system image into temporary logical partitions, boots it with
its own isolated `/data`, and reverts on the next reboot. Nothing existing is
modified. That makes it the cheapest possible way to answer the only question that
matters up front — *does generic Android 16 run on warhol's vendor partition, and
what breaks?* — before any device-tree work is done.

Target for testing: **LineageOS 23.2 GSI** (Android 16 QPR2, arm64 a/b). Note
phhusson's GSI wiki is stale (nothing past Lineage 22); the maintained Android 16
Lineage GSIs are at
<https://github.com/MisterZtr/LineageOS_gsi/releases> (images hosted on
SourceForge). Google's own AOSP Android 16 GSI is an alternative smoke test but is
delivered through the browser-based Android Flash Tool.

**2. Extracting 1647 vendor blobs is probably the wrong plan.** The stock
`vendor` / `odm` / `vendor_dlkm` partitions already satisfy all 150 declared HALs,
and the device is Treble-compliant with vendor API level 202504. Building only
`system` / `product` / `system_ext` against the **stock vendor** is far less work
and far less fragile than a full blob extraction — and it is what most modern MTK
Lineage ports do. `lineage/warhol/proprietary-files.txt` (generated by
`tools/gen-proprietary-files.sh`) is therefore best treated as an **inventory** —
a map of what exists and what each piece is for — rather than a copy list.

For scale, that inventory breaks down as:

| subsystem | files | | subsystem | files |
|---|---|---|---|---|
| Camera | 784 | | Wi-Fi / BT | 101 |
| Firmware | 289 | | Audio | 88 |
| Power / thermal | 112 | | NPU / APU | 77 |
| Radio / modem | 55 | | GPU / display | 49 |
| NFC / SE | 34 | | Sensors | 26 |
| Fingerprint | 15 | | Vibrator | 10 |
| IR blaster | 7 | | | |

Camera being 784 of 1647 is the single clearest argument for keeping stock vendor.

## GSI smoke test — run 2026-09-06, result: does not boot

DSU install works end to end on this device. Both LineageOS 23.2 GSI variants
(VANILLA-EXT4 and VANILLA-EROFS, Android 16 QPR2, arm64 `lineage_arm64_bv`)
installed cleanly and then **failed to boot**, hanging at the splash screen.

Cause, from `/sys/fs/pstore/console-ramoops-0` after recovering:

```
init: Service 'odsign' (pid ...) exited with status 1        x77 occurrences
init: process with updatable components 'odsign' exited 4 times before boot completed
zygote: never started
```

`odsign` (On-Device Signing, which signs the ART artifacts at boot) crash-looped
from ~222 s to ~662 s across at least 8 restarts, and init gave up. The system
never reached zygote — hence a hang rather than a bootloop.

**What did NOT appear in the log is the interesting part**: no VINTF failures, no
missing-HAL errors, no SELinux denials, no keymint errors. warhol's vendor
interface does not appear to reject a generic system. The failure is one named
userspace service.

Practical notes for anyone repeating this:

* The DSU installer rejects a raw `.img` (`UnsupportedFormatException`). Gzip it.
* Do not stage the image in `/data/local/tmp` — it gets the `shell_data_file`
  label and `gsid` is denied read (`avc: denied { read } ... scontext=u:r:gsid:s0
  tcontext=u:object_r:shell_data_file:s0`). Put it on shared storage instead.
* Use the official intent, not raw `gsi_tool`:
  `am start-activity -n com.android.dynsystem/.VerificationActivity -a
  android.os.image.action.START_INSTALL -d file:///storage/emulated/0/... --el
  KEY_SYSTEM_SIZE <bytes> --el KEY_USERDATA_SIZE 8589934592`
* Recovery from a failed GSI boot is just: force power off (hold Power 15-20 s),
  boot normally. DSU is one-shot. Then `gsi_tool disable && gsi_tool wipe`.
* Google's own Android 16 GSI is **not** a drop-in alternative: that page offers
  only the browser Flash Tool, which *flashes* the system partition permanently
  rather than using DSU. Much higher risk; not a like-for-like test.

Swapping ext4 for EROFS was a wasted attempt — the evidence pointed at a
system-side service, and the filesystem was never implicated.

## What to do next (not now — after TWRP)

1. Extract a `proprietary-files.txt` from the `vendor`/`odm` images. The inventory
   output is the input to that.
2. Decide `vendor` strategy: reuse stock `vendor`+`odm` partitions (fastest, what
   most modern MTK Lineage ports do) vs. a full blob extraction.
3. Watch for `MiCode/Xiaomi_Kernel_OpenSource` to publish a `warhol-*-oss` branch.
   Not needed for TWRP (GKI), but wanted for a real Lineage kernel. As of
   2026-09-06 only `bsp-chagall-w-oss` (the 17T) exists.

---

# Google Apps and Play — making it painless

Baseline measured on the stock ROM (2026-09-06):

```
GMS         26.34.33   Play Store  52.9.21-34
96 com.google.android.* packages installed
GMS/Play run from /data/app (self-updated over the shipped versions)
NFC hardware: hce + hcef + ese  -> Wallet-capable hardware
```

## The short version

Painless is achievable for **Play Store, Google account, app installs, Play
Protect** — that is the normal LineageOS + GApps experience and it is well-trodden.

Two things are **not** fully fixable and should be expected rather than fought:

1. **Widevine L1 → L3** the moment the bootloader is unlocked. Netflix / Prime /
   Disney+ drop to SD. This is already true today on this device and no GApps
   choice changes it.
2. **Play Integrity `DEVICE` verdict** fails on an unlocked bootloader. That is
   what gates Google Wallet tap-to-pay and the stricter banking apps.

Everything else is a solved problem.

## Which GApps package

**MindTheGapps.** It is what LineageOS officially recommends and builds against,
it is the minimum viable set, and it does not fight the ROM. NikGapps offers more
variants and more knobs; more knobs is the opposite of painless, and its larger
packages have a habit of colliding with Lineage's own apps.

Match **arm64 + the Android version of the Lineage build**, not the HyperOS version.

If Google is not actually wanted: LineageOS for microG is a separate ROM build, not
an add-on. Decide that up front — it is not a switch you flip later.

## The one gotcha that causes 90% of the pain

**GApps must be flashed in the same session as the ROM, before the first boot.**

Boot LineageOS once without GApps and then flash them, and you must factory reset —
because the packages need to be present when the framework first assigns
permissions and priv-app whitelists. That is the single most common way people end
up wiping twice.

Order, all in TWRP, one session:

```
1. wipe system / data / cache      (clean flash)
2. flash LineageOS zip
3. flash MindTheGapps zip           <- SAME session, BEFORE first boot
4. flash Magisk                     (root, and the vehicle for PIF/Dolby/Camera)
5. reboot -> first boot (slow, expect several minutes)
6. only after a successful boot: flash the add-on modules
```

**Do not deliver GApps as a Magisk module.** GMS needs to be a priv-app present at
first boot; systemless GMS is fragile and a known source of "Play Services keeps
stopping". Magisk is the right vehicle for PIF, Dolby and MiuiCamera — not for GMS
itself.

## Play Integrity — what to expect and what helps

| verdict | unlocked + Lineage | effect |
|---|---|---|
| `MEETS_BASIC_INTEGRITY` | passes | most apps fine |
| `MEETS_DEVICE_INTEGRITY` | **fails** | Wallet tap-to-pay, stricter banking apps |
| `MEETS_STRONG_INTEGRITY` | fails | hardware-attested; not realistically obtainable |

Mitigation is a **Play Integrity Fix (PIF)**-style Magisk module, which spoofs the
build fingerprint and verified-boot properties. This device is **already doing
exactly this today** — recon found Android reporting
`ro.boot.flash.locked=1`, `verifiedbootstate=green`, `veritymode=enforcing` while
the bootloader itself reports `unlocked: yes` / `secure: no`. So the technique is
already in play here and will carry over.

Getting `DEVICE` to pass generally needs a valid keybox (TrickyStore and similar).
That space is a moving target — Google revokes leaked keyboxes periodically — so
**do not design anything around STRONG passing**. Treat Wallet as "may work, may
stop working after a Play update".

## Practical recommendation

Assemble a single flashable set and keep it versioned alongside the device tree:

```
lineage-<ver>-warhol.zip
MindTheGapps-<ver>-arm64.zip
Magisk-<ver>.apk (renamed .zip)
PlayIntegrityFix-<ver>.zip     ) post-first-boot
DolbyPort-warhol.zip           ) Magisk modules
MiuiCameraPort-warhol.zip      )
```

so a reflash is one TWRP session with a fixed order rather than a research project
each time. That, plus the pre-first-boot rule above, is most of what "painless"
means in practice.

## Sequencing note

None of this is actionable until a LineageOS build for warhol exists. It is written
down now because the *decisions* — MindTheGapps vs NikGapps vs microG, and accepting
the L1/Integrity losses — are cheaper to make before the ROM work than during it.
