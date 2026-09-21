# Axion SPSM v3.7.11 (versionCode 69)

**The log's seven minutes, paid back — smoothness on minimum-speed cores, your tip on the caps, the tile blue at last.**

## What your v3.7.10 log said, and what each number got

**1. The navigation bar, fixed where it actually breaks.** Every fan worker
now runs at **background priority** (`renice 19`): on cores the governor
holds at minimum, your phone's own interface — the bar is SystemUI drawing —
always wins the race for the CPU. No more disappearing bar while the mode
works, and everything feels smoother in daily use, which was the point.

**2. Turning on and off, fast again.** Three changes, one of them yours:

- The asleep options run **six at a time** instead of two (your log: the
  screen-off deep phase held the phone for **seven minutes** — app_restrict
  175 s, rom_bg_off 243 s).
- **Your tip, implemented exactly**: the processor and graphics caps are
  applied **last** on the way in and lifted **first** on the way out. Your
  log showed why that is right — under the governor, the 188-app release
  alone took 100 s; uncapped it is a fraction of that.
- The daemon **no longer waits on the deep phase**. It hands the work its
  own process and keeps ticking: the core timer fires on schedule (it fired
  17 minutes late in your log), and a wake is answered instantly — the wake
  waits its turn behind a running deep phase instead of giving up.

**3. The tile, blue at last — and the button fixed by the same bug.** The
app was reading the mode's switch file from a path nothing writes
(`/data/adb/spsm/active` instead of `state/active`), so it always believed
the mode was off: the tile never went active/blue, and the button stayed
"Turn on". One wrong path, both symptoms. The tile also carries its icon now,
which is what the system tints when a tile is active.

**4. Three-button navigation is built into "Power-saving home".** One
switch, as you asked — the separate option is gone from the list. The bar
applies while the mode's home is up, and both come back on exit, exactly as
before.

**5. Suspended apps visible in your drawer.** With the mode's home off, your
launcher (Pulse) is refreshed once on activation, so blocked apps show as
suspended immediately instead of keeping full-colour icons.

## Install

Mode off → flash `Axion-SPSM-v3.7.11-RMX3430.zip` → reboot.

## Recovery (unchanged)

```
su -c sh /data/adb/spsm/scripts/engine.sh six-restore
```

## Harness

615 checks, 0 failed — twice consecutively. New pins: the caps-last/caps-first
order, every worker reniced, the detached screen-off with the retrying wake,
navigation hidden from the list but ordered after the home, and the launcher
refresh on activation with the home off.
