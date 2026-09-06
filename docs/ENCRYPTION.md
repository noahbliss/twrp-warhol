# Encryption, and what happens to the data on the phone

**Read this before doing anything to the device.**

> **Updated 2026-09-06 after confirming device state.** The phone is **already
> bootloader-unlocked and already rooted**. That resolves the worst version of
> this problem — the unlock wipe has already happened, and the data on the device
> now is post-unlock data. Section 1 below is kept because it explains why the
> ordering matters and still applies to any *second* device.
>
> What has *not* changed: **TWRP still cannot decrypt `/data`** (section 2). But
> with root on a running HyperOS that barely matters — data is backed up from the
> running OS, which is strictly more capable than TWRP would be. The live risk is
> now **flashing mistakes**, not the unlock. See `04-flashing-and-recovery.md`.

## 1. Unlocking the bootloader wipes `/data`. Unconditionally.

Xiaomi's `fastboot oem unlock` / Mi Unlock triggers a factory reset as part of
the unlock. This is enforced in the bootloader, not in Android — there is no
flag, no exploit-free bypass, and no "unlock without wipe" path. The wipe happens
before any custom image can ever run.

So the ordering is forced:

```
back the data up  ->  unlock (data is destroyed)  ->  flash TWRP  ->  restore
```

There is no ordering in which TWRP helps you rescue data that is on the device
*now*. TWRP cannot be installed before the unlock, and the unlock is what
destroys the data.

**Everything that must survive has to come off the phone first, while HyperOS is
still running and the bootloader is still locked.** Practical options:

* Xiaomi's own backup (Settings → Additional settings → Backup & reset), to a PC
  via MiPCSuite, or to Mi Cloud.
* `adb backup` is deprecated and unreliable on Android 16 — do not rely on it.
* Manual: `adb pull /sdcard/…` for DCIM, Download, WhatsApp media, etc.
* Per-app export for anything with its own backup format (Signal, Authy/2FA
  seeds, KeePass, Obsidian vaults…). **2FA authenticator apps are the classic
  thing people forget** — re-enrol them somewhere else *before* the wipe.
* Anything in an app's private `/data/data` that has no export path is
  effectively unrecoverable. Plan around that.

## 2. TWRP will not be able to decrypt `/data` afterwards either

`/data` on warhol is F2FS with **two** layers:

```
fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized   (FBE, per-file)
keydirectory=/metadata/vold/metadata_encryption                   (metadata enc,
                                                                   dm-default-key)
fsverity
```

The metadata-encryption key is wrapped by KeyMint in the TEE and **bound to the
Verified Boot Root of Trust**. The RoT is derived from what the bootloader
actually verified — so it is a different value once the bootloader is unlocked
and/or a non-stock `vendor_boot` is booted. KeyMint then refuses to unwrap the
key. You get `-33` (`ERROR_KEY_REQUIRES_UPGRADE` / RoT mismatch), not a wrong
password.

### "But TWRP used to decrypt /data with the password" — yes, and here is what changed

That memory is correct, and the distinction matters:

* **FDE era (Android 5–9).** One dm-crypt key for the whole partition, *derived
  from your PIN*. TWRP asked for the PIN, derived the key, done. This worked well.
* **Early FBE (Android 7–10).** Per-file keys, unwrapped via an auth token from
  gatekeeper. TWRP's `TW_INCLUDE_FBE` handled this on many devices. Still
  password-reachable.
* **Metadata encryption, `dm-default-key` (Android 11+, what warhol uses).** A
  layer *underneath* FBE: the entire `/data` volume is encrypted with a key that
  is **not derived from your password**. It is wrapped by KeyMint in the TEE and
  bound to hardware state. Your PIN unlocks the FBE layer — but the FBE layer
  lives *inside* the metadata-encrypted volume you cannot open yet.

So the password is no longer the blocker. The blocker is what the TEE will agree
to unwrap.

### Exactly where it fails

The metadata KEK is bound at creation time to the **Verified Boot Root of Trust**:

```
{ verifiedBootKey, deviceLocked, verifiedBootState, verifiedBootHash }
```

plus, on some MTK trustlets, a boot-image-derived `BOOT_PATCHLEVEL` folded into
the KEK. The bootloader latches these into the TEE over a secure channel **before
Android starts**, based on the image it actually booted. Boot a custom recovery
and the trustlet is presented a different RoT than the stock boot image produced,
so the KEK cannot be reproduced and the TEE rejects the blob with
`INVALID_KEY_BLOB`. Same key, same PIN — unwraps in normal boot, refused in
recovery.

This is not a missing TWRP feature. On degas the maintainer got the **entire
software chain working** inside recovery: binder context takeover, a
servicemanager bridge, hwservicemanager, KeyMint, gatekeeper, keystore2 — the TEE
even opens a session successfully (`TEEC_OpenSession -> 0x0`) and fresh-key crypto
works. The only thing that fails is unwrapping the *existing* blob. The wall is
enforced inside the secure world and is not reachable from Android; the only
theoretical bypass is patching the RoT check inside the MITEE trustlet itself.

Full engineering log (292 lines, worth reading before anyone re-attempts this):
<https://github.com/Advnirr/twrp_device_xiaomi_degas/blob/fbe-decryption-research/docs/RESEARCH.md>

One might hope that an *already-unlocked* device escapes this, since
`deviceLocked`/`verifiedBootState` are then the same in both modes. That hope does
not survive contact with the degas result: that device was also unlocked and
running TWRP when it failed, so the differing input has to be `verifiedBootHash`
or the boot patchlevel — i.e. something that changes when a custom `vendor_boot`
is booted. Expect the same here.

### What this means in practice for us

**We already have something strictly better than TWRP decryption: root on the
running OS.** A rooted, booted HyperOS reads `/data` decrypted natively — that is
the capability people remember from the TWRP FDE days, just reached a different
way. Back up from there, not from recovery.

warhol uses the identical Xiaomi/MTK HyperOS 3 stack as degas and chagall. See
<https://github.com/Advnirr/twrp_device_xiaomi_degas/tree/fbe-decryption-research>.

**Consequences for how TWRP gets used here:**

* TWRP shows `/data` as encrypted. It cannot browse it, cannot back up files from
  it, cannot restore files into it.
* "Format Data" works (it destroys the keys and makes a fresh filesystem) — that
  is the *only* useful `/data` operation.
* Backups are therefore raw-image backups of the *other* partitions:
  `boot`, `init_boot`, `vendor_boot`, `dtbo`, `vbmeta*`, `super`, and the MTK NV
  partitions (`nvdata`, `nvcfg`, `protect1/2`, `persist`, `md_sec`). Our
  `recovery.fstab` marks exactly those `backup=1`.
* Once the phone is unlocked and running, user data is backed up the normal
  Android way, not by TWRP. **With root already available this is the right tool
  anyway** — a root backup from the running OS can read `/data` decrypted, which
  TWRP fundamentally cannot. Use Neo Backup / Swift Backup, or
  `adb exec-out su -c 'tar -C /data -cf - .' > data.tar` for a blunt full copy.
  Do this *before* the first flash, not after.

`BoardConfig.mk` therefore leaves `TW_INCLUDE_CRYPTO` / `TW_INCLUDE_FBE` off, and
`device.mk` omits `vold`/`keymaster`/`gatekeeper`. That also buys back space in
the 64 MiB `vendor_boot` budget.

## 3. Things that are irreversible or brick-adjacent

| Action | Consequence |
|---|---|
| Unlocking the bootloader | `/data` wiped. Widevine L1 → L3 (Netflix/Prime HD gone). Some banking/health apps stop working (Play Integrity). |
| Erasing/reformatting `metadata` | `/data` becomes unreadable **even to stock HyperOS**. `recovery.fstab` marks it `backup=0` and keeps it out of the wipe UI on purpose. |
| Losing `nvdata` / `nvcfg` / `protect1` / `protect2` | IMEI and RF calibration gone → no cellular, not recoverable without a service tool. **Back these up in the very first TWRP session.** |
| Flashing an image built for `chagall` or `degas` | Wrong DTB and wrong load addresses → hard brick risk. Only flash images built from *this* tree with *this* device's geometry. |
| Anti-rollback | `images/anti_version.txt` = `1`. Never flash a package whose anti version is **lower** than the device's — it is a one-way fuse. |
| Locking the bootloader again with a custom `vendor_boot` flashed | Instant hard brick. Restore every stock image *first*, then lock. |

## 4. What the recovery flow actually looks like once unlocked

```
fastboot --disable-verity --disable-verification flash vbmeta        vbmeta.img
fastboot flash vendor_boot_a  twrp_warhol-vendor_boot.img
fastboot flash vendor_boot_b  twrp_warhol-vendor_boot.img
fastboot reboot recovery
```

`vbmeta` must be flashed with verification disabled, because our repacked
`vendor_boot` has no valid AVB footer. Keeping both slots consistent avoids a
surprise when the OTA or a slot switch moves you to B.

Recovery is entered as a *boot mode*, not a partition: the bootloader loads
`boot` (kernel) + `init_boot` (generic ramdisk) + `vendor_boot` fragment 0 +
fragment 1, and init stays in the ramdisk because `androidboot.force_normal_boot`
is absent.

## 5. Dual boot — reality check

The eventual goal is dual-boot HyperOS + LineageOS. Worth knowing up front:

* This is an A/B device, but the two slots are **not** two independent OSes.
  `super` holds one set of logical partitions per slot and slot B is currently
  *empty* (every `*_b` partition is 0 bytes). Populating slot B with a second OS
  is possible in principle but there is only 12.5 GB of `super` total, and
  `main_a` already has ~9 GB in it. Two full OSes do not fit without repartitioning.
* `/data` is shared. Two Androids sharing one FBE-encrypted `/data` will fight
  over it.
* The realistic dual-boot mechanisms on modern Android are **DSU / dynamic system
  updates** (a GSI in a temporary logical partition, `/data` isolated in
  `userdata_gsi` — note `userdata_setup` already knows that name) or a
  MultiROM-style patched boot chain, which does not exist for MTK Android 16.
* **DSU is by far the most likely path** and needs an unlocked bootloader but not
  TWRP. Worth testing a GSI via DSU *before* investing in a MultiROM-style setup.

None of this blocks the TWRP work — TWRP is the right first milestone either way
— but "dual boot" should be scoped as "DSU + GSI" until proven otherwise.
