# Power overnight #2 — AIRPLANE (radio-free platform floor) — 2026-09-23/24

## Setup
arm-tonight.sh armed 13:49, fired 23:45:08 exactly on the RTC. idleexp variant
`airplane`, window 23400s requested / 24590s measured (23:59:45 → 06:49:51),
checkpoint 1800s. Airplane ON read-back 1 at 23:49. Touches through the window:
0 (touchpanel_total frozen). Owner unplugged before 23:30 as agreed.

## Results (charge_counter is quantized to 60 000 uAh = 1%; step timing is fine)

| metric | night-1 (shipped, radios on) | night-2 (airplane) |
|---|---|---|
| window | 00:04-06:59 (6.9 h) | 23:59-06:49 (6.83 h) |
| drained | 3.00% (180 000 uAh) | 3.00% (180 000 uAh) |
| average | 26.1 mA | 26.4 mA |
| radio wake IRQs | 402 wlan0 + 55 CCIF | **wlan0 +0, ccci +0** |
| suspends | 524 (78/h) | 159 (23/h, longer periods) |
| suspend fails | 77 | 13 |
| IPI0 rate | 160/min | 110/min |

Percent-step timing (night-2): 50→49% ~00:50, 49→48% ~02:50, 48→47% ~05:20
— about one percent per 2h20m ≈ 25 mA steady after the first ~40 min.

## Verdict

**Radios are not the overnight cost. With every radio dead the drain is
identical to radios-on: 3.00% in ~6.8 h ≈ 26 mA. The cost is the platform
floor.** The goal math: 1% per 6.5 h allows ~7.7 mA average. The current floor
(24-26 mA) makes 0-1% physically impossible — 3%/night is physics at this
floor. Getting there needs a ~3x floor reduction: deeper suspend residency,
the constant IPI0 chatter (~110/min), and the alarmtimer wakes that end every
suspend (sus_last_dev=alarmtimer). Wakeup-hunting cannot deliver it — night-2
had zero radio wakeups and lost exactly the same 3.00%.

The queued Wi-Fi-off-vs-on experiment is CANCELLED by this data (and V2 already
showed Wi-Fi radio-off is worse than suppressing searches).

## Next (platform floor programme, SPSM focus)
1. Suspend residency from ie-history (batterystats history also carries
   modemRailChargemAh/wifiRailChargemAh rail counters - per-rail attribution).
2. IPI0 sources (110/min even with radios dead) - kernel-side trace.
3. alarmtimer wake cadence and who arms those alarms (alarm dump 794 lines).
4. Settling: both nights show an elevated first ~40-60 min after screen-off.

## Operational notes
- The whole run + report is in /data/local/tmp/arm-tonight.log (ie.out kept
  night-1 content this time - the report landed in the arm log).
- ie-orig.env writer does not quote values: a captured `Failed transaction
  (2147483646)` paren string broke sourcing (syntax error at 23:45:08). The
  restore still worked from in-memory ORIG_* values. Fix: quote on write.
- idleexp validity check flags `wifi at end: BAD` from the stale `Wifi is
  enabled` text; the honest test is wlan0 IRQ delta (=+0 = radio dead). Cosmetic.
- 06:55 publisher relaunch printed FAILED (owner had to open Termux); owner did,
  tunnel healthy at 07:21.
