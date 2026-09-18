# Axion Super Power Saving v3.6.5 (versionCode 57)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot (the reboot is what arms the frame-rate cap).

v3.6.4 used the owner's verified command for the frame rate — and the owner
then found the missing half of the story: **after a reboot the phone starts
with its frame-rate override OFF** (`ro.surface_flinger.enable_frame_rate_override=false`),
and the 30 fps command issued in that state **crashes SurfaceFlinger and
soft-reboots the phone**. The command was right; the phone was not armed for
it.

### The fix: the module arms the phone at boot

The module now ships its own `system.prop`:

```
ro.surface_flinger.enable_frame_rate_override=true
```

The module manager applies that at every boot — **before the screen's
compositor starts** — so after one normal reboot the override is on for good
and SurfaceFlinger reports `enableFrameRateOverride=true`. Exactly as required:

* SPSM never writes the property itself (no `resetprop` at runtime);
* SPSM never restarts SurfaceFlinger;
* **ON** → the verified 30 command (`service call SurfaceFlinger 1035 i32 0 i64 0 f 30 f 30`);
* **OFF** → the verified 60 command (`... f 60 f 60`) puts the phone's own
  default back.

### And if the phone is not armed yet

Switching the option on before that first reboot does **nothing** — on purpose.
The knob reads the override first, and with it off it refuses honestly ("one
more reboot after installing arms it"), logs why, and records nothing to undo.
The crash path can never be reached through SPSM.

### Everything else

Unchanged from v3.6.4's clean reset: the Recents button is the phone's own,
SPSM's recents list is one tap of Home away, and the harness passes
**520 checks, 0 failed** — including the new ones: the armed phone gets the
exact 30 command, the unarmed phone gets nothing and an honest note, and a
phone where nothing was applied restores nothing on exit.

### Install

1. Switch the mode off (door → Exit).
2. Install the zip in ResukiSU.
3. **Reboot once** — this is what arms the frame-rate override.
4. Turn the mode on; turn "Cap the frame rate (30 fps)" on.
