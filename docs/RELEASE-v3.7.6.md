# Axion SPSM v3.7.6 (versionCode 64)

**The six slots, fixed for good — found in your log, and it was mine to own.**

## What your log showed, and what it meant

Your v3.7.5 log was the whole story:

- `allow … : it is in the six slots, so it is no longer blocked` — with **no
  unsuspend behind it**. v3.7.5 asked the phone "is this app really
  suspended?" before every release, and your phone does not answer that
  question in the words the code expected. So the app you **added** stayed
  suspended, the app you **removed** was re-blocked.
- `keep block_other_apps: a value was changed externally since we applied it`
  — the exit using that same broken reading as its excuse to skip **every**
  release it still owed you.
- And that is why the re-flash and the **reboot** changed nothing: Android
  keeps app suspensions across reboots. Only an explicit unsuspend clears
  them — and nothing was unsuspending.

## The fix, at every layer

- **An app added to a slot is freed at once** — no questions asked. Our own
  record of what we suspended is the only permission needed.
- **An app removed from a slot is blocked at once** — screen on or off.
- **The exit releases the whole record first** — before anything can skip it.
  Whatever any journal verdict says, every package this mode suspended comes
  back.
- **After every slot change the journal is re-recorded**, so the exit always
  compares against the world as it is now, never as it was at turn-on.

## Your recovery command (keep this one)

In Termux:

```
su -c sh /data/adb/spsm/scripts/engine.sh six-restore
```

It releases everything in the six slots and everything the record still
names, at any time. It also runs **by itself at boot** if a dead session ever
leaves apps suspended with the mode off.

## One app, one slot

The picker now refuses an app that is already in another slot — and tells you
which slot it is in. The module's own list writer de-duplicates on top of
that.

## The Check button

It now shows **which option it is on** and how many are done, and every
option is checked under a 90-second lid — one slow option (deep sleep once
took 889 seconds) can never again make the button look dead.

## The icon

Still your original battery — now as a **true adaptive icon**: your battery
as the foreground, **pure black** as the background. No white plate on any
launcher, on any shape. Old launchers keep the black square.

## Install

Mode off → flash `Axion-SPSM-v3.7.6-RMX3430.zip` → reboot. If anything is
still suspended after the update, run the six-restore command once.

## Harness

565 checks, 0 failed.
