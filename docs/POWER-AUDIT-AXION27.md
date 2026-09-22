# AxionOS 2.7 power architecture on the RMX3430 — audit, maps, and proposed policy

Measured on the device, 2026-09-22, root session. Every number below was read from this phone;
nothing is inferred from generic AOSP. Sources: `/data/local/tmp/audit1.txt`, `audit2.txt`,
`audit3.txt`, `powermap4-on.out`, `interrupts.txt`, `batterystats`.

---

## 1. AxionOS 2.7 power architecture map

### 1.1 Platform

| | |
|---|---|
| Device / platform | realme RMX3430, **MT6768**, Android **16** (SDK 36), build `BP4A.251205.006` |
| Panel | 720 × 1600 |
| Kernel | `4.19.325-cip135-st19-Zenium-V1.5.2-sus-Even` (per `/proc/version`; `uname` is spoofed by SUSFS) |
| **debugfs** | **not compiled in** — `mount -t debugfs` returns *No such device* at every mountpoint. There is no `wakeup_sources`, ever. All wakeup accounting must come from `dumpsys batterystats`, `/proc/interrupts` and `suspend_stats`. |
| `/sys/power/wakeup_count` | present but reads **empty**; unusable as a counter |
| `suspend_stats` | present: `success=0 fail=0` after 12 009 s uptime while a tunnel wakelock was held |
| `mem_sleep` | `s2idle [deep]` — deep is selected |
| cpuidle (per cluster) | only **two** states: `rgidle` (WFI, latency 1) and `mcdi` (latency 150, residency 1600). No cluster-off state is exposed. |

### 1.2 The five layers that actually exist

**Layer 1 — Android framework** (standard, permissive config):
* Doze/DeviceIdle present and **deep idle does engage**: idling history shows `deep-idle: -1h43m`, `-1h5m`, `-20m` with exits marked `(unlocked)` and `(exit-force)`.
* `idle_to=+1h`, `max_idle_to=+6h`, `min_time_to_alarm=+1h`, `wait_for_unlock=true`.
* SMS/MMS temp allowlist exists: `sms_temp_app_allowlist_duration_ms=20s`, `mms_…=1m`, `notification_…=30s` — Android already has the "let calls/SMS through, delay everything else" machinery.
* App Standby active: WhatsApp is already in bucket **45 (RESTRICTED)**; GMS and Termux are bucket 5 (exempt).
* **Doze whitelist has 37 entries**, including `com.google.android.gms`, `com.android.vending` and `com.android.providers.downloads` marked `system-excidle` — i.e. **Play services and the Play Store are allowed to wake the device during Doze**.
* Data Saver: **off** (`Restrict background: false`).

**Layer 2 — Axion additions** (the ROM's own work):
* `persist.sys.axion_cpu_*` properties defining CPU partitions: `bg=0-2`, `limit_bg=0-1`, `limit_ui=0-2`, `svp=6-7`, `audio=0-5`, `big=6,7`, boost targets `boost_small=1800000`, `boost_big=1710000`.
* **Extra cpuset classes the stock ROM does not have** — measured live:

| cpuset | cores | `cpu.uclamp.max` | tasks (screen on) |
|---|---|---|---|
| `l-background` | **0-1** | **25** | 0 |
| `h-background` | 0-2 | 50 | 7 |
| `systemui` | **4-7** (pinned to big cluster) | max | 50 |
| `restricted` | 0-3 | max | 1 |
| `ax_foreground` | 0-7 | max | 0 |
| `foreground_window` | 0-5 | max | 0 |
| `svp` | 6-7 | max | — |

  This is a ready-made "reduce work" mechanism: a process demoted to `l-background` runs only on two little cores with a 25 % utilisation ceiling.
* zram (lz4) with `swappiness=100`; `page-cluster=0`.
* Axion apps: `AxionParts`, `AxionFx`, `AxionWidgets` (priv-app), and **`AxionSPSM`** (`/system/app/AxionSPSM/AxionSPSM.apk`).
* ROM overlays include **`OplusDozeOverlayEven.apk`** and `OplusDoze__ax_even__…` — the OPPO/realme doze overlay is in this ROM.

**Layer 3 — MTK vendor stack** (the real vendor power manager):
* **PPM** at `/proc/ppm` — enabled, with policies `PTPOD, UT, FORCE_LIMIT, PWR_THRO, THERMAL, DLPT, SYS_BOOST, HARD_USER_LIMIT, USER_LIMIT` on and **`LCM_OFF` off**. Policy knobs that are live and settable:
  * `forcelimit_cpu_core` — `cl0/cl1 min_core_num / max_core_num` (force active core counts)
  * `userlimit_max_cpu_freq`, `hard_userlimit_max_cpu_freq` — per-cluster freq limits
  * `lcmoff_min_freq` = `0 KHz` (unused because LCM_OFF is disabled)
  * `dlpt_limit` — `limited power = 0`, inactive
  * `thermal_cur_power` — **current power = 1427 mW, min = 816 mW, max = 3122 mW**
  * `dump_power_table` — a **measured power model**: `(L_core, L_opp, B_core, B_opp) = mW`, running from `3122` (all cores, top OPP) down to **`816` mW at the lowest OPP with all 8 cores active**.
* Thermal: `thermal@2.0-service.mtk`, `thermal_manager`, `thermalloadalgod`, ~100 cooling devices, `/vendor/etc/.tp/*.conf` (encrypted, not readable).
* MTK power HAL: `vendor.mediatek.hardware.mtkpower@1.2-service.stub`, `power.default.so`.
* `init.mt6768.power.rc`: `performance` governor until `boot_completed` then `schedutil`; `up_rate_limit_us 500/1000`, `down_rate_limit_us 20000/10000`; `pm_async=0`; `pm_freeze_timeout`; UFS `clkgate_enable=1` after boot; GED DVFS margins 120/700-step 4; uclamp defaults (system-background 40, background 50, top-app min 45).

**Layer 4 — libperfmgr power HAL** (`android.hardware.power-service.lineage-libperfmgr` + `/vendor/etc/powerhint.json`, 29 nodes / 35 actions):
* Hints defined: `SUSTAINED_PERFORMANCE`, **`INTERACTION`**, `LAUNCH` (+ others).
* **`INTERACTION` raises a frequency *floor* on every touch**: `CPULittleClusterMinFreq=1450000`, `CPUBigClusterMinFreq=1800000`, plus `TASchedtuneBoost=50`, `DRAMOppMin=1`, `UclampMin=75`, `FGUclampMin=75`, `TAUclampMin=75`. `LAUNCH` adds 3-second bursts at full clock.
* **But most of its target nodes do not exist on this kernel.** Verified missing: `/sys/devices/system/cpu/cpufreq/mtk/{l,b}cluster_{min,max}_freq`, `/dev/stune/top-app/schedtune.boost`, every `/proc/perfmgr/boost_ctrl/...` node, `fbt_cpu`/`fpsgo` nodes. Verified present: `/proc/touchpanel/double_tap_enable` (=1), the mali `js_*` nodes, GED nodes.
* **Conclusion: the power HAL is largely decorative on this build** — it was configured for a different kernel interface than the one shipped. Its only live levers are double-tap-to-wake and the GPU/GED nodes.

**Layer 5 — kernel interfaces that do work**: GED (`enable_cpu_boost=1`, `enable_gpu_boost=1`, `dvfs_margin_value=120`, `timer_base_dvfs_margin=99`), mali (`js_ctx_scheduling_mode=1`, `js_scheduling_period=75`, `dvfs_period=50`), `/proc/touchpanel/double_tap_enable`, `schedutil` rate limits, PPM as above.

---

## 2. Current SPSM control map — what it does, duplicates, conflicts with, and misses

32 knobs, of which **7 are deep** (`deep_doze`, `app_restrict`, `rom_bg_off`, `cores_sleep`,
`ged_boost_off`, `freeze_google`, `data_saver_idle`). Mapping onto the layers above:

| SPSM knob | acts on | verdict |
|---|---|---|
| `deep_doze` | `dumpsys deviceidle force-idle deep` | **duplicates DeviceIdle**, but forces it ~1 h early. Complementary, uses Android's own machinery. |
| `app_restrict` | App Standby buckets | **duplicates Adaptive Battery**, applied aggressively and at once. |
| `rom_bg_off` | 13 Axion/Lineage background packages | Axion-specific; nothing else does this. |
| `data_saver_idle` | `netpolicy restrict-background` | Uses Android's own mechanism; no duplication. |
| `freeze_google` | package suspend of GMS/Play | **conflicts with the Doze whitelist**: GMS and Vending are `system-excidle`-whitelisted, so Doze lets them wake the device even while SPSM suspends them. |
| `cores_sleep` | CPU hotplug of cores 2-7 after 1 min | overlaps **PPM `forcelimit_cpu_core`**, which does the same job in the vendor's own manager, and hotplug has a real transition cost. |
| `ged_boost_off` | GED `enable_cpu_boost`/`enable_gpu_boost` | Addresses a real screen-off cost; GED ships with both enabled. |
| `fps_cap` (30 fps), `brightness_cap`, `animations_off`, `blur_off`, `gpu_cap`, `timeout_short`, `haptic_off`, `rotate_lock` | screen-on rendering | **screen-on only.** Correctly identified in `POWER.md` §1.2; not standby levers. |
| `scan_always_off`, `sync_off`, `location_off`, `bt_off`, `nfc_off`, `wifi_off`, `data_off` | radios and sync | session-scope; `wifi_off`/`data_off` are exactly the "switch the radio off" approach the owner ruled out. |
| `gov_powersave` | pins the governor to `powersave` | **conflicts** with PPM and thermal management (two DVFs fighting) and with the owner's standing rule. Left **off** by decision. |

**Not controlled by SPSM at all today** (the actual design space):
1. the **Doze whitelist** (37 entries; GMS/Play exempt),
2. the **MTK PPM** interfaces (`forcelimit_cpu_core`, `userlimit_max_cpu_freq`, `lcmoff_min_freq`, `dlpt_limit`),
3. **Axion's own cpuset classes** (`l-background` etc.) for demoting background work,
4. **sensor/location gating** beyond the location toggle (three sensor handles were active with periods of 1.0 ms, 80 ms and 66.7 ms),
5. **fingerprint HAL (`silfp`) wakelocks** — 5 h 23 m of accumulated wake time,
6. **alarm/job deferral beyond Doze** (no use of `min_time_to_alarm` tuning, no `use_window_alarms` review),
7. **Wi-Fi power-save / DTIM / metered-network policy** (the AP is `Metered hint: true`),
8. **GED margin tuning** (dvfs_margin 120 is aggressive; `enable_cpu_boost=1`).

---

## 3. Real-device power map

### 3.1 States measured so far

Method: `/data/local/tmp/powermap4.sh on` — snapshot before/after each window, deltas only.
Caveat, stated plainly: the tunnel and this SSH session were live, and the foreground app
(`mark.via.gp`) was burning 60–73 % of a core, so these are "screen on, phone busy" numbers.

| state | window | suspend | drained | idle behaviour | top consumers |
|---|---|---|---|---|---|
| **A** screen ON + active | 301 s | +0 | **60 000 µAh (60 mAh)** | rgidle 127 s + mcdi 73 s on cpu0 | browser 60 %, a servic process 63 %, surfaceflinger 14 %, composer 8.8 % |
| **B** screen ON + idle | 301 s | +0 | **60 000 µAh (60 mAh)** | rgidle 124 s + mcdi 76 s on cpu0 | browser **73 %**, servic 70 %, surfaceflinger 14 % |

Two facts fall out of this immediately:

* **Screen-on drain is ~12 mAh/min (≈720 mA, ≈2.7 W) and is identical whether the user is
  interacting or not.** Touching the screen is not what costs the power; the display plus
  whatever is running behind it is. `mali` interrupts in state B (616 963) were *higher* than in
  state A (362 224) with no interaction at all.
* **An app is running away in the background.** `mark.via.gp` held 60–73 % of a core in both
  windows with the screen on and untouched. That is a screen-on problem, not a standby one, but it
  is worth 5 minutes to fix separately.

### 3.2 The arithmetic that decides the architecture

* Battery ≈ 5000 mAh ≈ **19.3 Wh**.
* Target 0–1 % over 6–7 h ⇒ 50 mAh ≈ 0.19 Wh over 6.5 h ⇒ **≈29 mW average**.
* MTK's own power model says the CPU domain alone draws **816 mW** with all eight cores at their
  lowest OPP — i.e. *awake at minimum frequency*.
* 816 mW ÷ 29 mW ≈ **28×.** So a phone that merely runs at low frequency can never reach the
  target: it must be **suspended for roughly 96 %+ of the window**.
* Meanwhile the measured screen-on draw is ~2.7 W, ~93× the standby target.

**This is the quantitative proof of the owner's rule**: the goal is fewer wakeups and more true
suspend, not a lower frequency ceiling. It also explains realme's 0–1 %: their SPSM keeps the AP
suspended, and the modem's paging path is the only thing allowed to wake it.

### 3.3 States C and D (screen off) — to be measured

Not yet measured under valid conditions, because the tunnel's `termux:service-wakelock` prevents
suspend outright (`sus_success` stays 0). Command for the owner, with the tunnel down:

```sh
termux-wake-unlock
su -c 'nohup sh /data/local/tmp/powermap4.sh off </dev/null >/dev/null 2>&1 &'
# leave the phone COMPLETELY alone for ~22 minutes, then:
termux-wake-lock && su -c 'cat /data/local/tmp/powermap4-off.out'
```

It reports, for a first 10-minute screen-off window (C) and a second (D): suspend success/fail,
`charge_counter` drain in µAh, per-cluster rgidle/mcdi residency, the interrupts that fired
(wlan0 / ccci / silfp / touchpanel), and thermal power. C vs D shows whether the phone gets
*deeper* the longer it stays off — which is the whole point of a staged policy.

---

## 4. Biggest measured energy leaks (ranked, with source)

| rank | leak | evidence |
|---|---|---|
| 1 | **Wi-Fi** | 2451 wakeups / 45 m 34 s of wake time; `wlan0` 319 681 interrupts; `scan_always` available; PNO not offloaded (all `…OverOffload` counters 0); AP is metered 2.4 GHz |
| 2 | **Cellular data paging** | `CCIF_AP_DATA` 739 wakeups / 10 m 20 s (must be reduced *without* touching registration) |
| 3 | **Fingerprint HAL `silfp`** | 5 h 23 m wake time from 21 events (~15 min held per event) — the largest single wake-time consumer found |
| 4 | **RTC / battery housekeeping** | `bat_temp_h` 146 wakeups / 35 m 24 s; `mt635x-auxadc` 83; `fg_bat1_l` 16 |
| 5 | **Timer churn** | `alarmtimer … returned -16` aborts ×36, `eventpoll` 97, `NETLINK` 64 — too many short timers for the kernel to consolidate a suspend |
| 6 | **GMS/Play exempt from Doze** | `system-excidle` whitelist entries for `com.google.android.gms` and `com.android.vending` |
| 7 | **Screen-on runaway app** | `mark.via.gp` 60–73 % of a core with the screen on and idle |
| 8 | **Rendering floor** | surfaceflinger 14 % + composer 8.8 % + mali 362–617 k interrupts per 5 min, even at 30 fps cap |

---

## 5. realme-style behaviour → mechanism mapping

Behaviour to reproduce, and the mechanism on *this* device that can produce it — no proprietary
code involved, only platform facilities that already exist here:

| realme behaviour | what it does in practice | equivalent here |
|---|---|---|
| Super Power Saving Mode (restricted active-app model) | only a handful of apps stay live; everything else is frozen | `cmd package suspend` on a computed list + App Standby `RESTRICTED` + the Axion `l-background` cpuset |
| **App Quick Freeze** | cached/background apps are frozen on a timer after screen-off | Android's Cached App Freezer + `am set-standby-bucket … restricted`, staged by idle duration |
| **Sleep Standby Optimization** | background network paused, Wi-Fi scanning stopped, wakeups coalesced overnight | `netpolicy restrict-background` (our `data_saver_idle`) + scan suppression + `deep_doze` + pruning the GMS/Play Doze exemption |
| **Screen Battery Optimization** | display/refresh/brightness reduced while on | already covered by the 30 fps cap, `blur_off`, `brightness_cap` |
| Calls/SMS still arrive; other notifications late | modem stays registered, alarms/jobs deferred, SMS/MMS get a short allowlist | Doze already ships `sms_temp_app_allowlist=20s`, `mms=1m`; the modem's paging path is never touched by any SPSM knob. This is why "don't disable cellular" is right. |

---

## 6. Proposed SPSM power-state architecture

Five states, each reversible from the one above, each chosen *from measurements* rather than
intuition. Everything below already exists on this device — nothing needs to be invented.

| state | entry condition | policy | mechanisms |
|---|---|---|---|
| **S1 ACTIVE** | screen on, input < 30 s | screen-on economy only: 30 fps, blur off, no frequency clamp | existing screen-on knobs; leave `gov_powersave` off |
| **S2 SCREEN-ON IDLE** | screen on, no input ≥ 30 s | drop GPU/CPU boost hints; cap background classes | `ged_boost_off`, `gpu_cap`, Axion `l-background` for cached apps |
| **S3 SHORT IDLE** | screen off < 60 s | release nothing — a glance must not pay a transition | existing behaviour in `phase_deep` |
| **S4 LONG IDLE** | screen off ≥ 60 s | force Doze, restrict apps, pause background data, stop ROM background services, park cores, **suppress scans**, **prune the Doze exemption for GMS/Play** | `deep_doze`, `app_restrict`, `rom_bg_off`, `cores_sleep`, `data_saver_idle`, new: scan suppression + whitelist trim |
| **S5 EXTREME** | long idle + battery low | strongest safe set: freeze non-essential apps outright, widest alarm coalescing | `freeze_google` + `restricted` bucket for everything not essential + PPM `forcelimit_cpu_core` |

Invariants: telephony registration is never touched; every state restores the previous value it
changed; the user's explicitly allowed apps keep their allowlist.

**What decides each threshold** is state C vs D: if D shows the same drain as C, the staging is
doing nothing and the problem is a specific waker; if D is much better, staging works and the
thresholds should be tightened.

---

## 7. Where each mechanism belongs

| job | right layer | why |
|---|---|---|
| screen/input state detection | **native** (`spsm-screenmon`, already built) | epoll on uevents; no polling |
| forcing Doze, app standby buckets, data saver, app suspension | **shell → Android system APIs** | one binder call each; the engine already batches them |
| Doze whitelist trim | **shell → `dumpsys deviceidle whitelist`** | must record and restore the prior list; no public API |
| background-work demotion to Axion cpusets | **shell → `/dev/cpuset/*/tasks`** | Axion's classes already exist; moving a pid is one write |
| PPM core/freq limits, `lcmoff_min_freq` | **sysfs/kernel via `/proc/ppm/policy/*`** | vendor's own manager; safer than fighting it |
| Wi-Fi scan suppression, DTIM/power-save | **shell → `cmd wifi` / `settings`** | platform-supported knobs |
| GED / mali boost and DVFS margins | **sysfs** | the nodes exist and are already used by `ged_boost_off` |
| **measuring wake events over hours** | **small native helper, or the shell sampler that exists** | with debugfs absent, the cheapest robust source is `dumpsys batterystats` + `/proc/interrupts` deltas; a polling shell loop is acceptable at 10-minute intervals but would be self-defeating at 10-second intervals, so any high-frequency sampler must be native and event-driven |
| Java/framework | **not needed for anything on this list** | every mechanism above is reachable from root shell; a framework patch would add a build, a flash and a risk for no gain |

---

## 8. Next steps, in the order the evidence supports

1. **Measure C and D** (command in §3.3) — the single most valuable missing number.
2. **Prune the Doze exemption for Play services and the Play Store** while SPSM is in long idle
   (undo on wake). Evidence: rank 6; they are the only third-party-scale workloads that Doze
   currently *permits* to wake the SoC.
3. **Attack `silfp`** (rank 3, 5 h 23 m of wake time): identify what arms the fingerprint HAL and
   whether screen-off fingerprint can be suspended in long idle.
4. **Suppress Wi-Fi scanning and background network in long idle** (rank 1, partially covered by
   `data_saver_idle`).
5. Re-measure with `tools/remote/ab.sh` after each single change; keep only what wins.
