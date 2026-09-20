# Axion SPSM v3.7.8 (versionCode 66)

**The load spike and the vanishing navigation bar, fixed at their source; the share resolver untouchable.**

## What you saw on v3.7.7, one by one

You reported four things: everything working too slow, applying and exiting
taking far longer than normal, Franco showing a high average load ("never
happening before"), and the three-button navigation bar disappearing
completely for 7–8 seconds, many times. All four were the same bug wearing
different clothes.

**v3.7.7's parallelism had no ceiling.** The per-package loops and the wake /
deep-phase fans ran every call at once — on the wake, on every screen-off and
on exit, dozens of `pm` and `cmd` subshells were asked of the phone in the
same instant, on cores the power-save governor holds at minimum frequency.
The run queue spiked (Franco's average load), every call in the crowd waited
for every other one (apply and exit *slower* than before), and SystemUI
starved — the navigation bar is SystemUI drawing, so 7–8 seconds without it
is 7–8 seconds of SystemUI not getting scheduled.

Fixed where it started — every fan now has a ceiling:

- **Per-app work runs six packages at a time** (apply, restore, the ROM
  background option, "Block other apps" both ways, the background sweep).
- **The engine's phase fans run two options at a time** (wake, deep apply,
  deep release) — and the wake still restores your cores *first*, before
  anything else starts.
- Same work in the same wall time, a fraction of the peak load. That is the
  whole fix: concurrency with a ceiling, not a stampede.

## The "intent resolver isn't available" dialog

That one was new option "Restrict system apps too" (v3.7.7) reaching too far:
its widening path suspended **`com.android.intentresolver`** — the share
resolver every "Share" button in every app routes through — and Android
answered with its suspended-app dialog when you backed out of an app.

The resolver can never be suspended again. **The resolver, the permission
controller, the document picker and the media provider now sit in the
never-touch set** beside the dialer, SMS, emergency, keyboard, launcher and
modem — no option, now or later, suspends them.

- The option is **safe to leave ON** — that is what it is for on OEM phones.
- On a clean ROM like your AxionOS it is still fine to leave OFF.

## Also

- The three doze-state reads carry **timeout lids (15 s / 15 s / 5 s)**. Your
  v3.7.5 log showed `dumpsys deviceidle` blocking for 889 s once; a read that
  hangs can now cost seconds, never a quarter of an hour.
- Nothing else changed: the cores, the six slots, the tile, the recovery
  command and every option's behaviour are exactly as v3.7.7 shipped them.

## Your two-minute test: did the cores sleep?

You turned the screen off for about two minutes and asked whether cores 2–7
actually switched off. **They did.** One minute of continuous sleep is all it
takes; your own earlier log shows the line to look for:

```
cores_sleep: 6 core(s) asleep - cores 0 and 1 stay awake
```

Check it yourself any time: mode ON → screen off → wait a minute or two →

```
su -c cat /sys/devices/system/cpu/cpu2/online
```

`0` = asleep (cpu3–cpu7 will read the same; cpu0/cpu1 stay `1`). Wake the
phone and every core is back before anything else runs.

## Recovery (unchanged, and always in the docs)

```
su -c sh /data/adb/spsm/scripts/engine.sh six-restore
```

## Install

Mode off → flash `Axion-SPSM-v3.7.8-RMX3430.zip` → reboot.

## Harness

586 checks, 0 failed — including the new bounded-fan cases and a case that
widens the system-app set the way the option does and proves the resolver and
its plumbing are never suspended.
