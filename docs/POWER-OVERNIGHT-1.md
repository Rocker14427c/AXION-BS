# First honest night — the shipped configuration, screen-off, untouched (2026-09-22 23:59 → 09-23 06:42)

Everything before this was measured in windows of 10–20 minutes, which the fuel gauge cannot even
resolve (1 % = 60 mAh). This is the first full night: 6.7 hours, SPSM armed with its default knobs,
nothing touching the phone. Source: `/data/local/tmp/ie.out`, `ie-chk.tsv`, `ie-history.txt`
(267 184 lines, pulled and analysed offline).

## Validity first

- screen-on events in the whole window: **0**; `touchpanel` interrupt delta: **0** — the phone was
  never touched or woken by a person.
- `doze=IDLE` at every one of the 13 checkpoints.
- SPSM applied **18 knobs**; scan suppression read back as *"only available when wifi is enabled"* at
  both the start and the end of the window.
- The only wake locks present were the modem's own (`MwiRIL`, `IMS_RILA`) — and 523 suspends prove
  they do not hold the phone awake.

## The result

| | |
|---|---|
| window | **6.71 h** (23:59:48 → 06:42:10), harness span 23 872 s |
| charge used | 3060 → 2880 mAh = **180 mAh = 3.00 %** (gauge: 1 % = 60 mAh) |
| average current | **26.8 mA** = 0.45 %/h → **~2.9 % per 6.5 h** |
| suspended | **98.1 %** of the window (23 677 s) |
| awake | 1.9 % (441 s total) |
| wakes | 523 sleeps, 522 resumes = **78/h**; awake episode **median 0.74 s**, mean 0.84 s |
| longest uninterrupted sleep | 599 s (10 min) |
| suspend failures | 83 (12.5/h), `last_failed_dev=alarmtimer`, errno −16 |

**The target is 0–1 % over 6.5 h. This night was 2.9 % — about 3× the top of the target band.**
That is still the best number the phone has produced, and it is the first one that means anything:
the 10-minute windows implied 4–6 %/h, i.e. 26–39 % a night, because they were measuring the phone
still settling after the screen went off.

## The shape of the night matters more than the total

From the gauge's own 1 % steps (`charge=` in the history):

| period | consumed | rate |
|---|---|---|
| 23:53 → 00:34 (first 41 min after screen-off) | 60 mAh = 1 % | **88 mA** |
| 00:34 → 03:00 | 60 mAh | **25 mA** |
| 03:00 → 05:16 | 60 mAh | **26 mA** |
| 05:16 → 06:42 | below the gauge's resolution | — |

And per hour, from the kernel's own suspend/resume transitions:

| hour | suspended | resumes/h | mean sleep |
|---|---|---|---|
| 1st | 92.6 % | **301** | 11 s |
| 2nd | 96.2 % | 132 | 26 s |
| 3rd | 99.1 % | 22 | 162 s |
| 4th–7th | 97.9–99.3 % | 8–22 | 160–315 s |

Two things follow. **A third of the night's energy goes in the first 41 minutes** (88 mA while the
phone finishes settling) — that is a bigger, more tractable target than anything in the steady
state. And **the steady state is already deep**: 98.5 % suspended, ~16 wakes an hour, one every
4 minutes, each lasting under a second.

## Where the energy actually goes

522 wakes × 0.84 s × ~200–250 mA ≈ **25–30 mAh** — call it 15 % of the 180 mAh. So the AP's wakeups
are *not* the problem. The other ~150 mAh was spent with the AP **suspended**: over 6.6 h, that is
**22–24 mA still flowing while the phone is asleep**. That current is hardware that keeps running
when the AP stops: the modem camping on LTE, the Wi-Fi chip holding its association, the PMIC and
fuel gauge, DRAM self-refresh, SoC retention, panel bias.

That reframes the target honestly. 0–1 %/6.5 h is ≤ 60 mAh ≈ **9 mA average**. Even a night with
*zero* wakeups would still spend ~150 mAh (2.5 %) at the measured suspended current. **Wakeup
reduction alone cannot reach the target — the suspended floor itself has to fall.**

Wakeup attribution (522 wakes):

| count | reason |
|---|---|
| **402 (77 %)** | `wlan0` — every one of them in the first two hours (277 + 125) |
| 55 | `CCIF_AP_DATA` — modem data path |
| ~60 | `mt6358-rtc` / `bat_temp_h` / `fg_bat1_l` — RTC and fuel-gauge sampling |

Suspend aborts (83): 27 `eventpoll`, 15 `ttyC0` (the modem's AT channel), 12 `NETLINK`,
16 `mt635x-auxadc` (gauge ADC), and only **5 explicit `alarmtimer`** (`−16`). The alarm track is
much smaller than the earlier clean windows suggested: **23 wakeup alarms in the whole night**, the
largest being `com.android.settings.battery.PERIODIC_JOB_UPDATE` at 15.

## The radio environment sets a floor we cannot code around

`RSRP = −104 dBm, RSRQ = −13, RSSNR = 4 dB, level 3/4`, and the modem reported
`cellular_high_tx_power` 20 times overnight. That is a weak, noisy LTE cell. A modem camping on a
cell like that draws several times what it does on a good one, and it does so *while the AP is
suspended* — which is exactly where 22–24 mA of unexplained current sits. Part of the gap to the
target is this RF environment, not the ROM. Any honest report has to say so.

## What this says to do next

1. **The settling phase** — 41 minutes, 88 mA, 60 mAh, a third of the night. SPSM's own log shows the
   apply itself took 174 s (with `block_other_apps` alone at 133 s) and Doze needs ~30 min to reach
   IDLE. This is the best-understood, most tractable target we have.
2. **The suspended floor** — needs a decomposition, not a tweak: platform alone, platform + Wi-Fi,
   platform + cellular. The Wi-Fi half can be measured safely overnight (cellular stays up, so calls
   and SMS keep working). The radio-free floor needs airplane mode, which disables calls — a
   *diagnostic*, and not something to run unattended without the owner saying so.

## Bug found and fixed while checking the phone

Checking the phone afterwards, not everything SPSM did had been undone. `app_restrict` is genuinely
working (suspensions, standby bucket, background-op — all confirmed on WhatsApp, Gmail Lite,
LocalSend). But the force-stop that `block_other_apps` performs has **no automatic inverse**: a
suspended app is woken by a push the moment it is unsuspended, while a **stopped** app is not woken
at all — the phone will not start it again until somebody opens it. Measured with the mode off:
**173 packages still stopped, WhatsApp and the mail client among them**, and 254 stopped
system-wide. The module's own comment said an app "simply starts again when it is next opened";
for a messaging app that is exactly wrong.

- Restored on the phone by hand: `pm unstop` for all 173, and the standby buckets of WhatsApp and the
  mail client back to normal (they had been left at *restricted*).
- Fixed in the module: the force-stopped set is now recorded (`state/stopped_by_us.tsv`) and released
  with `pm unstop` on exit **and** in `six-restore`, so a crash cannot leave the phone silently unable
  to receive messages. A test asserts that every package it stopped is un-stopped on the way out.
