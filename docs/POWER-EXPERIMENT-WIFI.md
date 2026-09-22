# Wi-Fi / Doze experiment — four controlled screen-off windows (2026-09-22 21:31–22:52)

Run on the device with the agent's footprint removed first (`Wake Locks: size=0` verified before
the windows), one variable per window. Source: `/data/local/tmp/wifiexp.out`, raw snapshots
`we-*.txt`. **V3's label is wrong — see below.**

Windows were requested as 600 s each; they did not all run that long, and the reason turns out to
matter more than the result did.

## Results

Rates are per minute of the window's own measured length.

| | **V0 control** | **V1 scan suppressed** | **V2 Wi-Fi radio off** | **V3 (invalid)** |
|---|---|---|---|---|
| measured window | 1182 s | 874 s | 854 s | 602 s |
| `sus_success` | +42 (**2.1/min**) | +25 (1.7/min) | +12 (**0.8/min**) | **+0** |
| `sus_fail` | +7 (0.4/min) | **+3 (0.2/min)** | +1 (0.1/min) | **+0** |
| `wlan0` interrupts | +135 (6.9/min) | **+40 (2.7/min)** | +0 (radio off) | +25 834 (42.9/min) |
| `arch_timer` interrupts | +13 528 (11.4/s) | **+8 118 (9.3/s)** | +26 200 (30.7/s) | +1 792 212 (**2977/s**) |
| `charge_counter` drain | 0 µAh | 0 µAh | **60 000 µAh = 1.00 %** | **60 000 µAh = 1.00 %** |
| current at window end | −197 mA | −75 mA | −734 mA | −400 mA |
| top wakeup reasons | wlan0 30, bat_temp_h 6, CCIF 3 | wlan0 14, **CCIF 7**, bat_temp_h 4 | **CCIF 6**, rtc 3, bat_temp_h 2 | (none recorded) |
| `wifi` state, verified | enabled | enabled | **disabled** | **enabled** |

## What the numbers say

1. **Suppressing Wi-Fi scanning is a real, measurable saving, and it now ships.** V1 cut `wlan0`'s
   interrupt rate **2.5×** (6.9 → 2.7/min), halved the suspend-failure rate, and reduced `arch_timer`
   traffic by 18 % over the control, with no extra drain. The confident signals would have been a
   rising timer rate or rising failures; both fell.
2. **Turning the radio off is worse than suppressing its searches.** V2 halved the suspend rate and
   raised the timer interrupt rate **2.7×** over the control — more wakeups with Wi-Fi off than with
   it merely not scanning — and it was the only valid window to register a full 1 % of drain. The
   work did not disappear, it moved: `CCIF_AP_DATA` (the modem data path) enters V2's top wakeups and
   `silfp` gains 5. This is the measured form of the owner's rule: *do not blindly disable radios.*
3. **The V1 saving already ships — no new code was needed.** `scan_always_off` is a session knob, on
   by default, which writes the settings key *and* issues `cmd wifi set-scan-always-available
   disabled`. It had been inert only because the engine's `knob_field` bug meant the engine applied
   nothing at all. Verified end to end on the device:
   ```
   before  : "Wifi scanning is always available"        setting=1
   activate: "only available when wifi is enabled"      setting=0
   exit    : "Wifi scanning is always available"        setting=1
   ```
4. **`alarmtimer` is still the suspend blocker** — `last_failed_dev=alarmtimer` in every valid
   window of this run and in the clean baseline (`sus_fail=19`, errno −16, EBUSY).
5. **V2's window is slightly contaminated**: `touchpanel` gained 128 interrupts, so the screen was
   touched. The direction agrees with the timer evidence, but the figure needs a clean re-run.
6. **The fuel gauge cannot resolve these windows.** 1 % = 60 000 µAh, so a 10–20 minute window can
   only report 0 % or 1 %. Suspend counts, per-IRQ rates and the timer rate are the instruments that
   work; µAh is for overnight runs only.

## V3 is void, and the reason is a harness bug

An earlier reading of the log concluded V3 never ran. **It did run** — 602 s, ending with the
`RESTORING` banner at 22:52:39. The log was read while the window was still open and a truncated
view was mistaken for a crash. Two lessons: never conclude a run died from a partial read (the
`DONE` banner and the timestamps are the test), and check a window's *state* before believing its
*label*.

V3's label says "Wi-Fi off + GMS/Play de-whitelisted". Its own opening snapshot says
`wifi_enabled=Wifi is enabled`. The radio never went off: between variants the harness woke the
screen briefly, and Android's Wi-Fi auto-enable brought the radio back up on that screen-on. Nothing
in the harness checked, so the window was measured and reported under a name that did not describe
it. Its numbers then make sense: zero suspends, a 2977/s timer rate (260× any other window), 42.9
`wlan0` interrupts a second on an interface labelled "off", and `touchpanel` at 4.2 IRQs/s (28× V2)
— a phone with the radio freshly up, working hard, and never sleeping. **It is not evidence about
the Doze whitelist either way**, and the whitelist-trim idea remains untested rather than refuted.

## Why the windows ran long, and what fixes it

Requested 600 s, measured 1182 / 874 / 854 / 602 s. Two compounding causes, both now fixed:

1. **The clock.** `sleep` here is CLOCK_MONOTONIC and stops while the phone is suspended, so a
   `sleep 20` poll loop stretches. Watching that alone would predict a small overshoot, not 582 s.
2. **The heavy calls sat inside the measured interval.** A `dumpsys` issued with the screen off makes
   progress only during wakeups, so a single call can take minutes of wall time. The window was
   timed from the start snapshot to the end snapshot, i.e. it included those calls.

`tools/remote/idleexp.sh` replaces the old harness and is built around this:

- deadlines measured against **`/proc/uptime`** (CLOCK_BOOTTIME, which counts suspended time), not
  `sleep` and not the wall clock; the report prints the boottime and wall-clock lengths side by side,
  so the discrepancy can be seen rather than guessed at;
- **nothing heavy inside the window** — captures run before the clock starts, verification dumps
  after it stops;
- every window records the **configuration it was meant to have and the one it actually had**
  (screen state, radio state, scanning state, wake-lock count) at both ends, and declares itself
  `BAD:` if they disagree;
- it **refuses to start** if anything of ours still holds a wake lock, if the phone is charging, or
  if the screen will not stay off — a 6.5-hour run that measures the wrong thing is worse than no run;
- the restore brings the radio up **first** and re-arms scanning **second**, because
  `cmd wifi set-scan-always-available enabled` silently does nothing while the radio is down — the
  bug that left scanning switched off after this run.

## A mistake worth recording

An attempt to add a `scan_suppress_idle` deep knob was written, tested and then **removed**. It
captured `scan_always_off`'s already-applied value as its own "original", so two knobs owned one
settings target and the engine's verify could not reconcile them — test 29 failed with
`left-alone=1` until the duplicate was deleted. The lesson is in the framework's own idioms: one
target, one owner; and a knob's snapshot must contain settings targets only, because a pseudo-target
line is read as a value changed externally. The final tree is unchanged apart from documentation, and
the suite is back to **657 passed, 0 failed**.

## Next measurement

`idleexp.sh shipped 23400 1800` — the shipped configuration, screen off, untouched, over 6.5 hours
with a checkpoint every 30 minutes. Every window so far has been shorter than the gauge can resolve,
and none has tested *sustainability*: Doze escalation, alarm storms and the module's own staged
knobs (which the engine applies over minutes, not seconds) only show up across hours. That run
answers the actual target — 0–1 % over a night — instead of a proxy for it, and the checkpoint
profile localises any regression in time.
