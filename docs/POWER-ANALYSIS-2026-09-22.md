# Why the phone still burns power with the screen off — measured, 2026-09-22

Session: RMX3430, AxionOS 2.7, kernel `4.19.325-…-Zenium-V1.5.2-sus-Even`, root over SSH tunnel.
Method: read-only collection executed **on the device** (`/data/local/tmp/powermap.sh`), because this
phone's `dumpsys`/`settings` calls can block for minutes and a host-side poller cannot tell a slow
call from a hung one. Raw output kept at `/data/local/tmp/powermap.txt`.

> **Read this first — the measurement trap that invalidates everything else.**
> `dumpsys power` showed `Wake Locks: size=1` and the single entry was
> `PARTIAL_WAKE_LOCK 'termux:service-wakelock' ACQ=-6m42s LONG (uid=10252 …)`, and
> `/sys/power/suspend_stats/success = 0` with `fail = 0` after **12 009 s of uptime**.
> A partial wake lock held by the Termux tunnel keeps the AP from suspending at all, and
> `suspend_stats` records *no attempts*, not failures. Any standby comparison taken while a tunnel
> or any agent session is running measures nothing. The reference measurements below are therefore
> from the device's own kernel/Android counters, which accumulate regardless.

---

## 1. The wakeup ledger — what actually wakes this phone

`dumpsys batterystats --charged`, "All wakeup reasons", cumulative since the stats were last reset:

| wakeup reason | count | time awake held |
|---|---|---|
| `25 SPM:122 wlan0` — **Wi-Fi** | **2451** | **45 m 34 s** |
| `25 SPM:33 CCIF_AP_DATA` — **modem data path** | 739 | 10 m 20 s |
| `25 SPM:355 mt6358-rtc:357 bat_temp_h` — RTC/battery thermal | 146 | 35 m 24 s |
| `25 SPM:138 silfp` — **fingerprint HAL** | 21 | **5 h 23 m 29 s** |
| `25 SPM:134 touchpanel` | 32 | 20 m 24 s |
| `25 SPM:174 type_c_port0-IRQ` — USB-C | 6 | 2 h 37 m 50 s |
| `Abort: Callback failed on alarmtimer in platform_pm_suspend+0x0 returned -16` | 36 | 11 m 41 s |
| `Abort: Last active Wakeup Source: eventpoll` | 97 | 57 s |
| `Abort: Last active Wakeup Source: mt635x-auxadc` | 83 | 54 s |
| `Abort: Pending Wakeup Sources: NETLINK` | 64 | 48 s |
| `Abort: Pending Wakeup Sources: ccci_imsc` | 11 | 7 s |
| `Abort: Pending: silfp_wakelock_hal silfp_wakelock` | 2 | 2 h 26 m 3 s |

Corroborating interrupt totals (`/proc/interrupts`, names resolved):

| count | irq | name |
|---|---|---|
| 40 001 364 | IPI0 | Rescheduling interrupts (scheduler IPIs — **CPU wakeups, not a device**) |
| 27 694 312 | 3 | `arch_timer` |
| 5 560 887 | 93 | `13040000.mali` (GPU) |
| 2 689 168 | 5 | `systimer@10017000` |
| 890 417 / 890 416 / 860 765 | 105 / 97 / 91 | `rdma0`, `mutex`, `mali` |
| **319 681** | **122** | **`wlan0`** |
| 342 080 / 255 731 | 51 / 50 | `SSPM_MBOX` (SCP coprocessor mailbox) |
| 119 039 | 134 | `touchpanel` |

## 2. The answer to the central question

**The phone does not stay asleep because four classes of wakeup keep pulling the AP out of idle, and
until now SPSM's standby levers were not running at all** (see the `knob_field` fix — the deep phase
applied zero knobs before today).

Ranked by what is worth changing:

1. **Wi-Fi (`wlan0`) is the single largest waker — 2 451 wakeups, ~1 in 3 of all wakeups.**
   Cause is visible in the same dump: `ScanAlwaysAvailable true`, and
   `mWifiLogProto.numScans=829` with **`numPnoScanAttempts=3` and every `…OverOffload` counter 0** —
   i.e. preferred-network scanning is *not* offloaded to the chip; the host is doing it. Each scan
   wakes the AP.
2. **Cellular data paging (`CCIF_AP_DATA`, 739 wakeups)** — the modem handing packets to the AP.
   This must improve *without* dropping registration, because calls and SMS are the one thing the
   owner will not give up.
3. **Fingerprint HAL (`silfp`) — 5 h 23 m of accumulated wake time from only 21 wakeups.** A
   wakelock held for ~15 minutes at a stretch is not a scan; it is the HAL holding the AP up. Prime
   suspect for a large, cheap win, and it is independent of everything else.
4. **Suspend aborts from `alarmtimer` (`-16`, EBUSY, 36 times)** — the kernel aborted suspend because
   an alarmtimer was due imminently. That is the signature of many short timers: exactly what Doze's
   coalescing and app restriction exist to reduce.
5. Battery/RTC housekeeping (`bat_temp_h` 146, `mt635x-auxadc` 83, `fg_bat1_l`) — kernel-side
   charger/thermal polling. Not shell-tunable; recorded so nobody "fixes" it by accident.

## 3. Platform state that shapes the fix

| item | value |
|---|---|
| Doze state | `ACTIVE` (never in IDLE at sample time); `mDeviceIdleMode=false` |
| Doze config | light idle after 4 min, deep `inactive_to` 15 s, flex 1 min — Android defaults present |
| Doze whitelist | **37 entries**, including `com.google.android.gms`, `com.android.vending`, `com.android.providers.downloads` (system-excidle) |
| Standby buckets | WhatsApp **45 (RESTRICTED)**, GMS 5 (exempt), Termux 5 (exempt) |
| Data Saver | `Restrict background: false` — **off** |
| Wi-Fi | connected to a **2.4 GHz** AP at −47 dBm, link 78 Mbps, **`Metered hint: true`** |
| CPU idle | only two exposed states: `rgidle`, `mcdi`; 8 cores online; governor `schedutil` (500 MHz–1.8 GHz little, 850 MHz–2.0 GHz big) |
| SPSM | deep phase now applies: `app_restrict`, `rom_bg_off`, `ged_boost_off`, `deep_doze`, `cores_sleep` — verified `doze=forced` in the log |

## 4. Architecture: states, not switches

Matches `docs/POWER.md` §4 and the owner's request, now with measured priorities attached.

| state | entry | policy |
|---|---|---|
| **ACTIVE** | screen on + input | 30 fps cap (existing, keep), brightness/animation caps. **No frequency clamp.** |
| **SCREEN-ON IDLE** | screen on, no input ~30 s | GPU boost hints off, backlight cap. Still no work restriction. |
| **SHORT IDLE** | screen off < 1 min | nothing released yet — a screen-off that ends in seconds must not pay a transition |
| **LONG IDLE** | screen off > 1 min | force Doze (`deep_doze`, verified working), `app_restrict`, `rom_bg_off`, cores_sleep, **Wi-Fi scan suppress**, background-data restriction, fingerprint-wake suppression |
| **EXTREME** | long idle + low battery | add `freeze_google`, wider alarm coalescing, keep only the paging path |

Two invariants preserved from `POWER.md`: **the modem stays registered in every state**, and every
state is reversible from the one above it.

## 5. Change plan, in order of measured impact

Each item is a single change with a measurement after it. Nothing here needs new C code except where
noted; the goal is to make Android's own machinery do the work.

| # | change | targets | how | risk |
|---|---|---|---|---|
| 1 | **Wi-Fi scan suppression in LONG IDLE** — set `wifi_scan_always_enabled 0` (and the scan throttle) while the screen is off, restore on wake | 2 451 `wlan0` wakeups | new deep knob, snapshot/restore of the prior value | low; the connection stays up, only scanning stops |
| 2 | **Background-data restriction in LONG IDLE** via Data Saver (`cmd netpolicy set restrict-background true`), restored on wake; per-uid allowlist keeps WhatsApp/Telegram able to fetch on their maintenance window | 739 `CCIF_AP_DATA` wakeups | new deep knob | medium — verify SMS/MMS and calls first, then leave in place only if paging still works |
| 3 | **Fingerprint HAL wake behaviour** — audit `silfp` wakelocks, and in LONG IDLE suppress screen-off fingerprint wake so a screen-off does not enable the sensor | 5 h 23 m wake time | inspect the HAL's settings/uevent; disable fingerprint-wake in long idle only | low-medium; unlock still works after pressing power |
| 4 | **Alarm/timer coalescing** — the `deep_doze` knob now works; confirm it actually reaches `IDLE` and measure the abort count dropping | 36 `alarmtimer -16` aborts | already implemented; needs measurement | none |
| 5 | **Doze whitelist hygiene** — review the 37 system-excidle entries; GMS/Play in the whitelist can wake at will | shared with #2 | `dumpsys deviceidle whitelist -<pkg>` for anything not needed | medium; test notifications after |
| 6 | **Move to a 5 GHz AP if available** — the current AP is 2.4 GHz with `Metered hint`, where scan and beacon costs are higher | general | user action, not code | none |

Explicitly **not** doing, per the owner's constraints: CPU frequency clamps (`gov_powersave` is
now off in config for this reason — the `knob_field` fix had silently turned it *on* by restoring
its default), disabling cellular, or any change to `susfs4ksu` / `tricky_store` / `playintegrityfix`.

## 6. How every change gets measured

`tools/remote/ab.sh` (installed on the device by the session) runs two windows and prints deltas:

* Window A — SPSM **off**, screen off, untouched
* Window B — SPSM **on**, screen off, untouched

and for each window reports `uptime` (so an interrupted window is still interpretable), `sus_success`,
`sus_fail`, `wakeup_count`, `charge_counter` in µAh, cpuidle usage/time, and the top wakeup reasons
from `dumpsys batterystats`. Because the counters are cumulative, only the differences are read.

**Precondition that is not optional:** no wake lock may be held during a window, and the tunnel must
be down. `termux-wake-unlock` before starting, or the whole exercise measures the tunnel.
