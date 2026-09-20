# Axion SPSM v3.7.7 (versionCode 65)

**The core sleep, on time; the deep phase and the wake, parallel; universal for other phones.**

## Your cores question, answered from your own log

You asked whether cores 2–7 really went to sleep during your ~7-hour night.
They did — your v3.7.5 log shows `cores_sleep: 6 core(s) asleep - cores 0 and
1 stay awake` twice — **but they fired 63 minutes after the screen went dark,
not one minute**:

```
00:49:31  screen off
01:52:41  cores_sleep: 6 core(s) asleep
```

Root cause: the core sleep queued behind the deep phase's lock, and on your
phone that phase had spent 149 s + 889 s + 450 s in three options, one after
another. Fixed at the source:

- **The core sleep no longer queues behind anything.** One minute of sleep →
  the cores go down. The world is still re-checked first (mode on, screen
  off, nothing changed), and **if your wake lands in the exact moment the
  cores are going down, that same call puts them straight back**.
- **The deep phase now runs its slow options side by side** (wall time =
  slowest option, not the sum) **and the wake is parallel too, cores first**:
  your cores are back before anything else is even started, then everything
  else is released together instead of minutes of sequential work while you
  hold the phone.

## Universal, for the other phones

You said you'll run this on stock-OEM devices too, so:

- **The dialer, SMS and emergency apps are now protected by asking the
  phone** which apps hold those **roles** — on a stock OEM that's the
  maker's own app, with a name no static list can know. Works on
  LineageOS / AxionOS / any AOSP-based OEM ROM.
- **New option: "Restrict system apps too"** (Options → Apps, **off by
  default**). On an OEM phone the preinstalled junk is usually a *system*
  app; with this on, "Block other apps" stops it and the per-app restriction
  restricts it too. On a clean ROM leave it off — calls, SMS, dialer,
  keyboard, launcher and modem are never touched either way.
- **"Restrict the ROM's background work" was audited and is already
  universal**: it doesn't carry a fixed list of victims — it reads its
  candidates off *whichever phone it's running on*, at every screen-off
  (running system apps, minus the protected/core/exempt sets), and puts each
  back on wake.
- "Hand back background memory" and the doze option were audited too: both
  already parallel/ceilinged, both device-shaped.

## Also

- The full harness is now **578 checks, 0 failed** — including the new
  OEM-shaped cases (an OEM dialer known only through its role, OEM junk
  stopped and restricted only when you ask, and the exit freeing it again).

## Install

Mode off → flash `Axion-SPSM-v3.7.7-RMX3430.zip` → reboot.

## Harness

578 checks, 0 failed.
