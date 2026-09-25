# Axion SPSM v3.9.0 (versionCode 76)

**The daily round, measured: ON in 33s (was 67s) while doing more work, OFF in 21–24s (was 24–47s), and a journal that only claims what the phone confirmed.**

Every number below was measured on the owner's phone (RMX3430, AxionOS, Android 16) on 2026-09-25, before and after — not estimated.

| the daily round | v3.8.2 (field, 10:59 / 12:17) | v3.9.0 (field, 13:54 / 13:58) |
|---|---|---|
| turning the mode ON | **67s** with 13 knobs | **33s** with 21 knobs (the full emergency posture) |
| …of which `block_other_apps` | 41s | **7s** |
| turning the mode OFF | **24–47s** | **21–24s**, three cycles in a row |
| …of which releasing 187 force-stopped apps | 14s | **4s** |
| deep phase in (screen off) | 48s | 38s, and the freeze switches land last |
| deep phase out (wake) | 24s | 20s, thaw first |
| exit verification | — | `checked=27 drift=0 left-alone=0` on every cycle |
| journal after 187 confirmed suspensions | *"no visible change"* — false | 187 × suspended, from pm's own confirmation |

## What the field log said

The morning log was the specification for this release:

* `SPSM ON: 13 knobs applied in 67s` — and 41 of those seconds were the one knob that blocks
  background apps. Inside it: 6s building the candidate list, 9s force-stopping, **10s writing the
  record**, and two full re-reads of the package list around the whole thing.
* `revert clean in 47s` — a third of it one loop releasing 187 force-stopped packages, one `pm`
  call at a time.
* `note block_other_apps: no visible change (optional node missing?)` — logged while
  `state/blocked_by_us.tsv` held **187 packages pm had just confirmed suspended**. The after-read
  raced PackageManager's disk flush and the journal called a real change invisible.
* A progress file reading *"Idle: applying the asleep options"* still on disk 26 minutes after the
  phone woke, and 34 empty scratch directories a day in `.tmp/`.
* The home swap re-applying itself about a minute after activation, because the session tail did
  not ask the journal whether the work was already done.

## Turning ON: the same honesty, a sixth of the waiting

The block knob, 41s → 7s, culprit by culprit:

1. **One package list per run.** A single activation built the blockable list three times
   (before-snapshot, candidates, after-snapshot), each build costing the protected-role binder
   round trips plus two `pm list` calls. The build is now cached under the run's id and published
   where the run's later callers read it; the after-read does not list packages at all. The run
   even pre-warms the cache in the background at the top of the activation, so the first reader
   finds it built. (Measured on the device: build 246ms quiet, cache hit ~0ms.)
2. **The before-snapshot trusts the phone's own record.** When `package-restrictions.xml` — the
   file pm itself uses — was read and says nothing is suspended, that is the answer; the old code
   double-checked it with a `dumpsys package` per candidate, **188 binder round trips, ~8s of
   every activation**. The per-package check still runs on the phones where the record cannot be
   read at all. One awk pass replaces the loop where it is safe to.
3. **The candidate filter became a copy.** With nothing already suspended, every blockable package
   is a candidate — the per-package shell pass (2s quiet, 5s under the activation's own fan) was
   a filter that filtered nothing. It is a straight redirect now.
4. **The record writes in one pass** (was 10s of 187 individual file appends through SELinux and
   f2fs).
5. **The after-read is built from what pm confirmed.** The suspensions that pm answered yes to are
   journalled as suspended, whatever the disk's flush lag says — the false *no visible change* is
   gone, and with it the 7s second read.
6. **The force-stop fan widened to twelve.** The work per package is one binder call to AMS, which
   keeps far more threads than twelve: 5s → ~3s in the field.

The settings-shaped knobs (aod, timeout, animations, haptics, rotate lock, blur, statusbar, scan,
location, sync, battery saver — and now double-tap-to-wake with its proc nodes) write in a parallel
fan that logs **every write the phone confirmed**, and their after-read is synthesised from that
log instead of a second full sweep. The synthesis is deliberately paranoid: one FAILED line, one
missing target, an empty log — any of them refuses it and the knob falls back to the real read.
A journal entry is a claim about the phone; the claims now come from confirmations.

## Turning OFF: 47s → 21s

* The 187-package release loop is a twelve-wide fan of `pm unstop` (was sequential: 14s → 4s).
* The caps go off **first**, so the rest of the exit runs at full speed (4s invested, everything
  after it faster).
* Everything reverts side by side, and the exit ends where it always did: `verify` comparing the
  phone against the journal — `checked=27 drift=0 left-alone=0` across three measured cycles,
  including one that had slept (the deep knobs journalled and reverted too).

## Sleeping: the freeze switches land last

The deep phase ran all six knobs at once — including `deep_doze`'s force-idle and Data Saver's
restrict-background, which freeze the very system the other four knobs were still writing to.
Field, 13:14: `app_restrict` took **43s** applying appops into a frozen system (and 20s reverting
on the way back), and the whole phase kept the CPU busy for 48s after the screen went dark.

Now the phase applies in two waves — the restriction knobs first on a responsive system, the
freeze switches last — and reverts mirrored: thaw first, then the per-app work. Field, 13:54:
`app_restrict` 30s, deep phase total 38s, release 20s with the thaw done in 3s. The remaining
seconds are binder latency under a power-save governor, and they happen while the screen is off;
they are the next target, documented honestly rather than hidden.

The core-sleep timer is untouched: cores 2–7 still go down one minute after the screen goes dark
(the wake at ~50s in the final field cycle kept preempting it; the morning's v3.8.2 run and the
test suite cover it).

## The small honesties

* The screen-off progress file is removed when the transition ends — the app no longer reports
  *"Idle: applying"* for the rest of the sleep period.
* The session tail asks the journal first: an applied home swap is not applied again a minute later.
* `j_reset` takes the writes scratch with the records of a finished session.
* `tmp_sweep` removes the empty scratch directories (34/day observed).
* The drain line stays quiet when the level came back **up** — a charging phone "draining" −60%/h
  was noise, not a measurement.

## Device-side resolutions (not code changes)

* **The sticky battery saver was Android's own.** `low_power_sticky=1` survived exits and re-armed
  `low_power` — and with it the platform's power throttling (PPM PWR_THRO), which is what capped
  the little cluster at 850MHz and put `powersave` on the big cluster while the mode was OFF. No
  module code wrote either. Cleared on the device; `knob.battery_saver=1` now journals the saver
  per session (ON at activation, OFF at exit, `low_power=0 sticky=0` verified after every exit),
  so it cannot go sticky again. No blind CPU-frequency writes were added.
* **The tunnel deaths during sleep were Data Saver.** `data_saver_idle`'s restrict-background
  blocks Termux's sockets at screen-off, which killed the SSH tunnel mid-sleep. Termux is now
  whitelisted on the device in both lists that matter (`dumpsys deviceidle whitelist +com.termux`
  and `cmd netpolicy add restrict-background-whitelist 10252`). Verified: two full deep-phase
  cycles with force-idle and restrict-background active, tunnel alive throughout.

## The posture configured on the phone

The maximum-emergency set, all of it journalled and revertible: governor power-save, Wi-Fi/BT/NFC
off, brightness cap, 15s screen timeout, AOD off, animations off, blur off, FPS cap 30, battery
saver, home swap + nav buttons, app blocking, location/sync off, scan-always off. The retired
`cpu_offline_big` / `cap_always` lines were removed from the config (the code paths are gone; the
deep phase and governor do that work honestly).

## Tests

966 checks green: main suite 687 (including the new section 91 — writes journaled, synthesis
refuses on any doubt, the block hook honours pm's record, one list per run, progress cleaned,
scratch swept), codec 252, install 22, daemon 5. Section 70 additionally isolates itself from the
rig's stub screen monitor, which was fabricating the occasional spurious wake between assertions.
