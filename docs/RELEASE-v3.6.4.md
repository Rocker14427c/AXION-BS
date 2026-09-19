# Axion Super Power Saving v3.6.4 (versionCode 56)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

v3.6.3's device test found the Recents button still dead after three rounds of
watchers, and the frame-rate cap still not capping. This release stops trying to
outsmart the phone on both counts: everything that did not work is **removed**,
and the frame rate now uses the command the owner proved on the device.

### The clean reset: the Recents button is the phone's own again

Across v3.6.1–v3.6.3 this mode watched for the Recents press three different
ways — the launcher's recents animation on the event log, the touchscreen tap
inside the button's region, each rewritten and each proven correct in the test
rig — and on the phone the press still never arrived. The v3.6.3 log shows the
watchers alive and not one press seen. Enough: **all of it is deleted.**

* the daemon no longer reads the phone's event log for any recents line;
* nothing reads the touchscreen — `getevent`, the region probe, the tap state
  machine, all gone;
* the app no longer consumes the Recents key. The owner's constraint is
  explicit — *do not intercept `KEYCODE_APP_SWITCH`* — and now the app doesn't;
* the dead "switch the launcher's recents off" option (this ROM refuses it) is
  gone from the option list.

What remains is exactly what the owner asked the mode to be: **the Recents
button behaves as the phone built it** — Quickstep's own recents, untouched by
SPSM, on or off. SPSM's own recents list is still there, one tap of Home away,
with the same task data, switching, per-task close, and Clear all as before.

### The frame rate: the owner's own command

The owner found the lever that works on this phone and verified it in Termux:

```
30 fps:  su -c 'service call SurfaceFlinger 1035 i32 0 i64 0 f 30 f 30'
60 fps:  su -c 'service call SurfaceFlinger 1035 i32 0 i64 0 f 60 f 60'  (his default)
```

Transaction 1035 is SurfaceFlinger's frame-rate override — below the panel's
modes, below settings keys, below the ROM's Game Mode setting that never
answered. The option now runs exactly that:

* ON: the whole screen — every app, this mode's home, everything — held to
  **30** while the mode is on;
* EXIT: the owner's **60** command puts the phone's own default back;
* there is no getter for this setting, so the log claims only what was set and
  what was restored, and Check answers *works — set by the owner-verified
  command; the phone cannot read it back*;
* the panel-modes path and the Game Mode path are deleted. 40 remains
  impossible: a rate must divide the panel's refresh, and 40 does not divide 60.

### Proven before shipping

The harness — the real engine scripts against a fake device tree — passes
**517 checks, 0 failed**, including the new frame-rate assertions: the exact
30 command while on, the exact 60 command on exit, a clean verify, Check's
wording, and no `service` call at all when the option is off. The removed
machinery's tests are removed with it.

### If the Recents button should ever do more again

The module-safe options are now down to two, and both start with evidence, not
code: one `logcat` capture made *while pressing the button* would say whether
any single, reliable trigger line exists on this ROM. Until then the button is
the phone's, as it should be.
