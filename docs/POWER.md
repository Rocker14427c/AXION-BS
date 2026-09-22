# SPSM power architecture: what actually costs energy

This document changes SPSM's goal from *fast* to *frugal*. It is written
against one hard constraint, stated first because everything else depends on
it:

> **No measurement in this document was taken on the RMX3430.** I have no ADB
> access to the device. What follows is (a) what the v3.8.1 field log proves on
> its own, (b) what the source says, and (c) an instrument built to collect the
> numbers that are missing. Every claim is labelled with which of those it is.

---

## 1. What the field log already proves

The v3.8.1 log from the owner's phone contains a four-minute screen-off window:

```
10:14:44  screen on -> off (panel=0 via panel)
10:14:44  screen off -> deep phase
10:14:48  deep applied: little_max=1800000 big_max=2000000 governor=powersave doze=no
10:17:54  daemon alive: panel=0 state=off deep=applied caps_little=1800000 ticks=180
10:18:49  screen off -> on
```

Three facts follow from this with no further measurement required.

### 1.1 The deep phase applied nothing

`knob_apply` logs `snap <id>: <values>` for every knob it applies. The startup
sequence in the same log shows seventeen such lines. **The screen-off window
contains none.** `phase_deep apply` ran, logged its header, and applied zero
knobs.

Reproduced in the test fixture with the deep knobs enabled, the same code path
produces:

```
screen off -> deep phase
snap deep_doze: deviceidle-force  unknown
snap ged_boost_off: /sys/module/ged/parameters/enable_cpu_boost 1 ...
snap app_restrict: com.spotify.music com.example.game
snap rom_bg_off:
deep applied: ... doze=forced
```

Note `doze=forced` against the device's `doze=no`. `doze` reads `forced` if and
only if `apply_deep_doze` ran, because that function's first action is to
create the marker the report reads.

There are exactly two ways `phase_deep` applies nothing:

1. every deep knob is disabled in `/data/adb/spsm/config`; or
2. `DEEP_ONCE` suppressed them because `deep_report` already existed.

(2) is ruled out by the same log: suppression logs `idle: <knob> is already in
place from this idle period`, and no such line appears. That leaves (1).

**So: on the owner's phone, Doze is never forced, background apps are never
restricted, the ROM's background services are never stopped, and the GPU boost
hints are never cleared — because those knobs are switched off in the config.**
The `docs/OPTIMISATION.md` work made the *transitions* fast. The *savings* were
not running.

This is a configuration state, not a code bug, which is why no test caught it.
It is also the single most important thing to confirm before changing anything
else, and the profiler reports it explicitly.

### 1.2 What *was* applied is a screen-on saver, not a standby saver

The only thing the log shows changing at screen-off is the governor — and
`gov_powersave` is a **session** knob applied at startup, not a deep knob. The
caps in the report (`little_max=1800000`, `big_max=2000000`) are the phone's
*stock* maxima; nothing lowered them.

Of the 16 knobs applied at startup, by what they act on:

| acts on | knobs |
|---|---|
| **screen-on cost** | `fps_cap`, `brightness_cap`, `animations_off`, `blur_off`, `gpu_cap`, `timeout_short`, `haptic_off`, `rotate_lock` |
| **standby cost** | `scan_always_off`, `sync_off`, `location_off`, `bt_off`, `nfc_off` |
| **both** | `block_other_apps`, `gov_powersave` |
| **neither (UI)** | `home_swap`, `nav_buttons`, `statusbar_on`, `sweep_bg`, `dt2w_off` |

The heaviest standby levers Android offers — forced Doze, app standby buckets,
background execution limits — are all in the *deep* set that never ran.

### 1.3 A lower frequency is not a lower energy

The owner already made this point and the log supports it. `gov_powersave`
pins the cores to their **minimum frequency**, which is not the same as letting
them **idle**. On a modern SoC the deep idle states (`MCDI`, cluster-off,
system suspend) are where the real saving is, and a core held at 500 MHz doing
work is often *worse* than the same work done at 1.8 GHz followed by a return
to idle — the race-to-idle effect. Holding the frequency floor down while the
phone is awake anyway can extend the time to finish work and therefore the time
spent out of idle.

**This is why the profiler measures `cpuidle` residency and `time_in_state`
rather than reporting the frequency cap.** The question is not "what is the
cap" but "how many microseconds did the cores spend in their deep states".

---

## 2. Why realme's SPSM achieves 0–1% over 7–8 hours

Not from CPU frequency limits. A phone that reaches genuine suspend draws
single-digit milliamps, and at that point the CPU's frequency ceiling is
irrelevant because the CPU is *off*. The behaviours that produce that number
are:

1. **The AP is suspended almost all of the time.** Everything else follows from
   this. A suspended AP cannot run an app, service a timer, or render.
2. **The modem stays registered in paging mode.** The cellular radio keeps a
   low-duty-cycle connection to the tower so incoming calls and SMS still
   arrive, and *that path is allowed to wake the AP*. This is why calls and SMS
   keep working while everything else is throttled. This is a hardware/firmware
   behaviour — the modem holds the registration; the AP sleeps beneath it.
3. **Almost nothing else may wake the AP.** Alarms are coalesced or deferred,
   jobs are not run, most apps are frozen rather than merely restricted, Wi-Fi
   scanning stops, sensors are released.
4. **Notifications are late, not absent.** They arrive on the next permitted
   wake — the maintenance window — rather than immediately. The owner
   explicitly accepts this trade.

So the target is not "more restrictions". It is **fewer wakeups**, with one
deliberate exception carved out for the paging path.

---

## 3. What to measure, and the instrument for it

`tools/POWER-PROFILE.sh`, also shipped as `scripts/power-profile.sh` and
reachable as `engine.sh power`. It is **read-only**; it changes no setting.

Two design decisions matter:

**Deltas, not absolutes.** Every counter here is cumulative since boot.
`wakeup_count = 48213` says nothing; the same counter read twice across ten
minutes says "the phone left suspend 214 times", which is actionable.

**Work, not percentage.** On a 5000 mAh cell one percent is 50 mAh — a ten
minute test can differ threefold in real draw and still show 0%. The profiler
reads `charge_counter` (microampere-hours) for a true drain figure and counts
*work* everywhere else.

What it collects, mapped to the chain the owner listed:

| link | source | the question it answers |
|---|---|---|
| suspend | `/sys/power/suspend_stats`, `wakeup_count` | did the phone sleep at all, and what stopped it |
| wakeup sources | `/sys/kernel/debug/wakeup_sources` | **what woke it**, ranked |
| CPU idle | `cpuidle/state*/{usage,time}` | did the cores reach deep states, or only run slowly |
| CPU freq | `stats/time_in_state` | where the cores actually spent the window |
| interrupts | `/proc/interrupts` | which *hardware* woke the SoC (modem, touch, sensor hub) |
| Doze | `dumpsys deviceidle` | `mState` — is Doze engaging at all |
| Doze exemptions | `deviceidle whitelist` | who is allowed to ignore it |
| wakelocks | `dumpsys power` | which app holds the CPU awake |
| alarms | `dumpsys alarm` | the classic standby drain, ranked |
| jobs | `dumpsys jobscheduler` | what is queued to run |
| Wi-Fi | `dumpsys wifi` | scan throttling, state |
| modem | `dumpsys telephony.registry` | service/data state — the calls-and-SMS guarantee |
| sensors | `dumpsys sensorservice` | what is registered |
| GPU/display | `ged` params, backlight | screen-on cost |
| SPSM itself | `state/`, `config` | **which deep knobs are actually enabled** |

### How to run it

```sh
# SPSM ON, screen off, phone untouched for 10 minutes
su -c 'sh /data/adb/spsm/scripts/power-profile.sh window 600 spsm-on'

# SPSM off, same conditions
su -c 'sh /data/adb/spsm/scripts/power-profile.sh window 600 normal'

su -c 'sh /data/adb/spsm/scripts/power-profile.sh compare spsm-on normal'
```

Reports land in `/data/local/tmp/spsm-power/`. Ten minutes is the minimum that
survives Doze's own timing; an overnight run (`window 28800`) is the one that
answers the 7–8 hour question.

---

## 4. Proposed architecture: states, not a pile of switches

The owner asked for power *states* rather than one permanent collection of
tweaks. The daemon already tracks screen on/off and already has a one-minute
timer, so the scaffolding exists.

| state | entry | policy intent |
|---|---|---|
| **ACTIVE** | screen on, recent input | cheap rendering only: fps/brightness/animation caps. No CPU ceiling — race to idle. |
| **SCREEN-ON IDLE** | screen on, no input ~30 s | add GPU floor, drop boost hints. Still no work restriction. |
| **SHORT IDLE** | screen off < 1 min | release nothing yet; a screen-off that ends in seconds must not pay a transition. |
| **LONG IDLE** | screen off > 1 min | the real standby state: force Doze, restrict apps, stop ROM background services, park cores, stop scans. |
| **EXTREME** | long idle + low battery | freeze non-essential apps outright; widen alarm coalescing; keep only the paging path. |

Two properties this must preserve:

- **The paging path is never touched.** Cellular registration stays up in every
  state. Restrict *background data and jobs*, never the modem's registration.
  `data_off` must remain opt-in and clearly marked, because on many networks
  SMS-over-IMS rides the data bearer.
- **Every state is reversible from the state above it**, which the journal
  already guarantees.

### Where each mechanism belongs

This is the "don't optimise for language" part. The right technology per job:

| job | right layer | why |
|---|---|---|
| detecting screen/input state | **native, already done** (`spsm-screenmon`) | epoll on uevent; zero CPU idle |
| forcing Doze | shell → `dumpsys deviceidle` | one binder call, correct as-is |
| app standby buckets | shell → `am set-standby-bucket` | already batched |
| **counting wakeups over hours** | **native daemon or C helper** | reading `wakeup_sources` every few minutes from shell is itself a wakeup |
| freezing apps | `cmd package suspend` batched | already 5 round trips for 187 apps |
| alarm coalescing | framework-level; **not reachable without a system app** | flag honestly rather than fake it |

The one place native code clearly earns its place *next* is the wakeup-source
sampler: any polling loop that watches for wakeups while the phone is trying to
sleep is self-defeating unless it is cheap and event-driven.

---

## 5. What I will not do

- **Add CPU frequency restrictions.** Explicitly ruled out by the owner, and
  section 1.3 explains why they can be counterproductive.
- **Disable cellular.** It breaks the calls/SMS requirement.
- **Change a dozen settings and hope.** The next change is chosen by the
  profiler's ranked wakeup list, not by this document.

---

## 6. Immediate next step

Run the profiler. The first report will answer, in order:

1. Are the deep knobs even enabled? (Section 1.1 predicts: no.)
2. Does the phone reach suspend at all, and how often does it leave?
3. Which wakeup source, alarm, or IRQ is top of the list?

Only after that does it make sense to change anything. If (1) is confirmed, the
fix is a configuration change and costs nothing — and it may well be most of
the gap on its own, because it would mean the owner has never actually run
SPSM's standby savings.
