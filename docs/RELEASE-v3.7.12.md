# Axion SPSM v3.7.12 (versionCode 70)

**The built-in nav, truly built in; your launchers made sacred; the audit round.**

## "You removed the option and didn't add it by default" — you were right, and the log says why

Your v3.7.11 log shows the home coming up with `navigation_mode=2` — gestures —
and no nav line at all. The built-in bar I shipped in v3.7.11 still consulted
its own saved preference before applying, and your config carried
`knob.nav_buttons=0` left over from an older version. The option was gone; its
ghost was still deciding.

**Fixed: the built-in follows the power-saving home switch, and nothing else.**
Home on → bar on. Home off → your own navigation. No ghost values, ever.

## Your launcher was being suspended — now it is sacred

The same log named `com.android.launcher3` and `com.community.oneroom` in the
block list. While this mode's own home holds the HOME role, your real launchers
hold nothing — so the protection that looked at role holders saw only the
mode's home, and your launchers went into the block list **every session**.
That one bug was behind three things you felt:

- the drawer that never showed suspended apps properly,
- `WARN block_other_apps did not return: com.android.launcher3…` on every exit,
- **every** exit ending in "1 value(s) could not be restored — forcing the
  safety valves".

Now anything that can answer the HOME category is protected — by role *and* by
the category query — so all your launchers, current or not, are never suspended
or restricted. **Exits now end clean, no safety valves.**

## The exit's last wide-open fan, bounded

The exit's revert ran a dozen knobs side by side, each re-reading its own
values to prove the revert — your `block_other_apps` revert spent 103 seconds
losing that race against its siblings. It is bounded six at a time now, like
every other fan: seconds, not minutes, and the interface wins the CPU
throughout.

## The audit

A full pass over module and app, removing everything dead — each removal
verified unused across scripts, app and tests before cutting:

- the Low-Power mode **write** path (`set_power_mode` / `release_power_mode`)
  — the option was removed in v3.7.5 at your direction; its writer stayed
  behind. The read side stays: the governor still diagnoses with it.
- two unused journal helpers, an unused recents-component reader, and two
  dead recents wrappers the engine never called;
- in the app: a toggle-state map that was written twice and never read.

## Install

Mode off → flash `Axion-SPSM-v3.7.12-RMX3430.zip` → reboot.

## Recovery (unchanged)

```
su -c sh /data/adb/spsm/scripts/engine.sh six-restore
```

## Harness

623 checks, 0 failed — twice consecutively. New pins: a stale saved
`nav_buttons=0` cannot silence the built-in; two seeded launchers are never
suspended; the exit ends clean with the safety valves holstered; the exit fan
is bounded.
