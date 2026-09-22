# Clean screen-off baseline (no agent footprint) — measured 2026-09-22 19:30–19:58 IST

First measurement on this device taken with **no Termux tunnel, no SSH session and no wake lock
held**. Every earlier screen-off number was taken with a `PARTIAL_WAKE_LOCK`, which blocks suspend
outright — `suspend_stats` read `success=0 fail=0` after 12 009 s of uptime. That is why the phone
appeared never to sleep.

Method: `/data/local/tmp/cdclean.sh`, launched detached with `setsid` (so killing Termux could not
kill it), using wall-clock deadlines rather than `sleep` (this kernel's `sleep` is
`CLOCK_MONOTONIC`, which does not advance while suspended). It kills the tunnel and the wake-lock
holder, verifies `Wake Locks: size=0`, then measures two 10-minute screen-off windows.

## The result

| | window C (first 10 min) | window D (next 10 min) |
|---|---|---|
| wall window | 617 s | 617 s |
| **`sus_success`** | **+17** | **+64** |
| `sus_fail` | +6 | +10 |
| **`charge_counter` drain** | **60 000 µAh = 1.00 %** | **0 µAh (below the gauge's 1 % step)** |
| `current_now` at snapshot | −279 mA → −146 mA | −146 mA → −153 mA |
| `arch_timer` interrupts | **672 886** (1 090/s) | **20 364** (33/s) |
| `IPI0` rescheduling | 758 529 (1 229/s) | 60 106 (97/s) |
| `wlan0` interrupts | — | 208 |
| **top wakeup reasons** | wlan0 **9**, eventpoll 2, CCIF_AP_DATA 2, silfp 1 | **wlan0 60**, eventpoll 7, CCIF_AP_DATA 4 |

Final counters: `sus_success=89`, **`sus_fail=19`, `last_failed_dev=[alarmtimer] errno=-16`**.

## What this proves

1. **The phone does suspend, and it gets much deeper the longer it stays off.** Suspends went from
   1.6/min in C to 6.2/min in D; timer interrupts fell **33×** (1090/s → 33/s) and IPI0 **12×**.
   Window D drew **less than the fuel gauge can resolve**. This validates the staged-policy
   approach: the first ~10 minutes after screen-off is a settling period, and the real deep idle is
   reachable beyond it. Staging is not a guess here — it is measured.
2. **Wi-Fi is the thing that ends the sleep.** In window D, **60 of 64 wakeups were `wlan0`** — one
   every ~10 s. Of everything on the phone, Wi-Fi is the single largest blocker to long suspends,
   which confirms the earlier ledger (2451 wlan0 wakeups, 45 m 34 s of wake time).
3. **Suspend is being refused by the alarm timer** — `sus_fail=19`, `last_failed_dev=[alarmtimer]`,
   `errno=-16` (EBUSY). Named by the kernel, not inferred. Alarms still fire often enough to make
   the kernel abort suspend attempts, which is exactly what Doze's coalescing exists to fix.
4. `silfp` is **not** the problem it looked like: 1 wakeup in C, 0 in D, and its interrupt counts are
   ~30 across the whole boot. The earlier 5 h 23 m attributed to it in the cumulative ledger is
   historical and should not drive the design.
5. `CCIF_AP_DATA` (modem paging) is modest in the deep window: 4 wakeups.

## The gap to the target

Target: 0–1 % over 6–7 h ⇒ ≤ 60 000 µAh in 6.5 h ⇒ **≈9 mA average**.
Measured deep-window snapshot current: **≈150 mA** (though this is an instantaneous reading taken
while the sampler itself was running, so treat it as an upper bound rather than an average).

To close the gap, in measured order:

| # | target | evidence | mechanism |
|---|---|---|---|
| 1 | **Wi-Fi wakeups** | 60 of 64 wakeups in the deep window | scan suppression + Wi-Fi sleep/power-save policy; radio-off-in-idle as a measured alternative |
| 2 | **alarmtimer suspend failures** | `last_failed_dev=alarmtimer`, 19 failures | Doze coalescing; longer `min_time_to_alarm`; prune the GMS/Play Doze exemption so they stop setting wake-up alarms |
| 3 | **settling period** | C is 33× noisier than D | apply app/ROM restrictions immediately at screen-off, not after; shorten the path into deep idle |
| 4 | screen-on | 60 mAh per 5 min, identical active vs idle | screen-on track: 30 fps already present, plus a runaway background app (`mark.via.gp` at 60–73 % of a core) |

## Next: a controlled Wi-Fi experiment, not a guess

`tools/remote/wifiexp.sh` runs four 10-minute screen-off windows back to back on the device, with
the agent's footprint removed and the phone untouched, and reports suspend counts, per-IRQ deltas,
wakeup reasons by name and gauge drain for each:

| variant | what it changes |
|---|---|
| V0 | control: nothing (reproduces D) |
| V1 | scan-always off + Wi-Fi sleep policy = always |
| V2 | V1 + Wi-Fi radio off, cellular left registered |
| V3 | V2 + GMS and Play Store removed from the Doze whitelist |

Whichever variant actually cuts `wlan0` wakeups and raises `sus_success` becomes the shipped
mechanism; the others are not implemented. The knob follows the measurement.
