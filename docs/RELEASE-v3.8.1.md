# Axion SPSM v3.8.1 (versionCode 72)

**The exit round: leaving the mode costs seconds, not minutes. No feature changed.**

## The evidence

The brief arrived with the owner's own v3.8.0 field log. It shows:

* activation **56 s**, of which the block apply spent **25 s** idling 186
  apps one fork at a time — apps it had *just* force-stopped — and the
  mode-on sweep spent another 5 s force-stopping the identical set again;
* exit **~117 s**, of which **`revert block_other_apps took 100s`** — the
  post-revert verify re-reading every value of every knob a second time,
  thirteen full snapshots at once, while the owner pressed home seven
  times waiting;
* two boot-time unfinished-session exits (17 s, 23 s) paying the same
  re-read tax, plus `WARN … want [0] got []` false-drift lines that were
  artefacts of that same re-read.

## What changed — the installer's method

**1. The verdict comes from the restore's own account.** Every restore
already reads each value it touches — it has to, to know what is still ours
to undo — and now records what happened as it happens: `kept` (a newer
value, not ours anymore), `failed` (the write was refused, with the value's
name and both sides), `wrote`. `knob_revert` reads that account and is done:
no second full read of every knob on the way out.

The one-round read-back **stays** where silence can hide: a knob with three
or fewer single targets (navigation, brightness, the switches) still gets
its verification read, because a ROM that accepts a `settings put` and does
nothing reports no failure — only a read catches it. That is also why the
field log's `want [0] got []` lines disappear: they were the removed
re-read misreading the world mid-exit.

**2. A blocked app is stopped once per session.** The block apply no longer
runs `am make-uid-idle` per app (suspension already implies idle to
ActivityManager) and marks the blocked set as handled, so the mode-on sweep
hunts only strays (`am kill-all`) instead of re-force-stopping 186 apps it
stopped seconds earlier. The apply fan widens from two knobs at a time to
three.

**3. The user's own values, still sacred.** A value changed since apply is
detected during the restore's own read and left alone — `keep <knob>: a
value was changed externally since we applied it` — with the small-knob
read-back confirming it independently. The apply-time silent-refusal note
(`applied, did not take, and was put back by the module`) is unchanged.

Recovery is untouched: `su -c sh /data/adb/spsm/scripts/engine.sh
six-restore`. `engine.sh verify` is untouched.

## Harness

**646 checks, 0 failed**, including the new case 89: a 40-package block is
replayed and the sweep must not re-stop it; a big-record knob's revert must
end with no read beyond the restore; a user-changed value must survive the
exit; a refused write must still be named with both sides.

## Install

Mode off → flash `Axion-SPSM-v3.8.1-RMX3430.zip` → reboot.
v3.8.0 remains published as a fallback build.
