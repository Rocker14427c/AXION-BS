# SPSM v4 plan — maximum power saving, screen off *and* screen on

Written after reading the v3.0.12 log and the phone's own diagnostic dump, and
corrected once already (the display is 60 Hz, and the process work is user apps
only). SPSM is an emergency mode: the goal is the longest possible runtime,
whether the screen is on or off, without ever leaving the phone damaged.

---

## 1. What the phone actually is (from the device, not from a spec sheet)

| | |
|---|---|
| Device | realme **narzo 50A** (the module is labelled RMX3430; the ROM identifies as build `BP4A.251205.006`) |
| Android | **16**, kernel **5.15.220-android16** |
| ROM | **AxionOS 2.7** — LineageOS + ProtonAOSP, AOSP-flavoured. Launcher `com.android.launcher3` ("Pulse") |
| Display | **720 × 1600 IPS, 60 Hz only** — `supportedRefreshRates [60.0]`, one display mode. There is no refresh-rate saving to be had |
| Battery | 6000 mAh (charge counter 3,540,000 µAh at 59%) |
| CPU | MediaTek 8-core, 2 big + 6 little, `schedutil`, three policies exposed as policy0 / policy4 / policy6 |
| Kernel power nodes | `/proc/cpufreq/cpufreq_power_mode` (written as a number, answers as a sentence) and a full `/proc/ppm` tree: `hard_userlimit_max_cpu_freq`, `hard_userlimit_cpu_core`, `forcelimit_cpu_core`, `sysboost_*`, `dlpt_*` (dynamic power/thermal limiting), `profile`, `enabled` |
| Processes | ~300 PIDs, and nearly all of them are **kernel threads** (`[cmdq_*]`, `[ccci_*]`, `[id0_trusty_*]`, `[ged_*]`, `[disp_*]`, `[kworker/*]`) with RSS 0. These are Linux, not apps: they cannot be suspended the way an app can, and most of them must never be touched |

Because this is not realme UI, realme's super power saving behaviour (six apps,
no recents, hard background culling) does not exist to be borrowed: it has to be
built, from the levers above.

---

## 2. What the phone's own log and dump proved

**Already working on your device:** `SPSM ON: 15 knobs applied in 39s`; the
daemon tracks the panel correctly (`panel=323`, `panel=1`); the slot fix works
(`allow com.gitlab.mudlej.MjPdfReader: it is in the six slots, so it is no longer
blocked`); screen-off drain **0.39%/h** (`47% -> 45% in 304min`), deep phase
`little_max=1100000 big_max=1300000 governor=schedutil doze=forced`, instant wake.

**Bug A — fixed in v3.1.0.** `/proc/cpufreq/cpufreq_power_mode` is written with a
number and *answers with a sentence* ("Low Power mode" / "Default(Normal) mode").
The journal recorded the sentence, so the exit wrote words into a node that only
accepts a digit: the write failed, the phone stayed in **Low Power mode** with a
`powersave` governor, and the exit then ran its safety pass — the 59-second exit,
and the same phantom `want schedutil got powersave` seen since v3.0.9. The journal
now holds the token, an unrecognised state is left alone and said so, and the
probe reports both the token and the sentence.

**Bug B — checked in v3.1.0.** `keep block_other_apps: a value was changed
externally since we applied it` (correct rule when you add an app to a slot). A
test now proves that after any exit **nothing** is left suspended and the module
keeps no record — including the case in your log.

**Evidence that the node is also a lever:** while SPSM was on, the dump shows
`cpufreq_power_mode = Low Power mode`, `policy0 max=1100000`, `policy6 max=1300000`,
`cpu6 online=0 cpu7 online=0`. That is the in-use stack working as designed.

---

## 3. What "maximum" means in each state

| | screen off | screen on (in use) |
|---|---|---|
| Today | deep doze, CPU/GPU caps, 2 big cores offline, buckets, radios optional → **0.39%/h** | only what `cap_always` allows; the rest is released on wake |
| Room to take | little — this is already good | **everything**: MediaTek Low Power mode, caps held, fewer cores, background culling with the screen on |

The in-use side is where the remaining hours are. Screen-off is close to done.

---

## 4. The plan, one stage per release

Every stage: tests first, per-change opt-out, guaranteed revert, `zip == tree`,
and your verification on the phone before the next stage starts.

### Stage 1 — correctness, and the status bar  *(shipped as v3.1.0)*
- `cpufreq_power_mode` journalled as the number it is written with; unknown states
  never written; probe evidence shows the sentence.
- Proof that no app stays suspended after an exit, including the slot-change case.
- **Status bar visible again** in the SPSM home screen (hide was cosmetic, saved
  nothing, and took the clock, the battery and the way out of Android away).
- Exit back to ~1 s: with the power mode restored there is no safety pass.

### Stage 2 — the in-use savings  *(each its own toggle, in the order shown)*
1. **`mtk_low_power`** — MediaTek Low Power mode as its own, visible knob, so it
   can be on in use without turning everything else on with it. Instant revert.
2. **`cap_in_use`** (today's `cap_always`, on by default in the emergency preset):
   CPU/GPU ceilings and the offline cores held while you use the phone.
3. **`ppm_hard_limit`** — use `/proc/ppm/policy/hard_userlimit_max_cpu_freq`
   (kernel-enforced) instead of only `scaling_max_freq`, which a governor change
   can walk back. This is the mechanism FKM-style apps fight with; ppm wins.
4. **`brightness_cap` fixed for in-use** — the probe measures it with the screen
   *off* today, which is why it always reported "nothing to do here".
5. **Background culling with the screen on** (non-slot *user* apps suspended while
   the mode is on, not only while asleep), plus `max_cached_processes` and the
   cached-app freezer verified enabled on this ROM. Plain-language warning, own
   toggle, own probe verdict.

### Stage 3 — the lightest possible recents  *(your choice)*
- A small **Recents** screen inside SPSM, opened from the home screen.
- It reads the task list **only when opened** (one root `dumpsys activity recents`
  call, parsed in the app) and switches with `am task move-to-front <id>`; it em-
  ploys nothing resident in between and never starts Pulse/Quickstep, which is
  what makes recents cost RAM and CPU today.
- If the app cannot read tasks, it shows the six slots instead — never an error.
- *Risk:* low-to-medium; the home screen can already survive a layout failure.
- *First step:* capture `dumpsys activity recents` on this ROM so the parser is
  written against the real format rather than a guess.

### Stage 4 — user apps only, plus system-level levers  *(your decision)*
You chose **user apps only**, so no system package is ever named, suspended or
disabled. The system side is instead influenced the way Android intends:
- the cached-app freezer and `max_cached_processes` (fewer cached processes kept,
  and frozen instead of running),
- App Standby buckets and Doze for **user** apps outside the six slots,
- Android battery saver, which the ROM already ties into SystemUI and Doze.
This trades some raw savings for safety; the compensation is that none of it can
break a system service, a call, an alarm or the exit path.

### Stage 5 — prove it, then hand over a "Maximum" preset
1. In-use drain measurement (today `drain.log` only measures sleep), so every
   claim above is a number from your phone, not an estimate.
2. A single **Maximum** preset that enables every option your own probe reports
   as working and safe, with a one-screen list of what it will do and one tap back.

---

## 5. How breakage is avoided (your instruction, taken literally)

- **One stage, one release**, never two mechanisms at once.
- **Reversibility is the entry price**: original value journalled before writing;
  a value that cannot be read is never written (seen in practice: the two keys
  this ROM refuses to read, and now the power-mode state).
- **Per-change opt-out** stays mandatory, and the probe keeps every option honest.
- **Tests before device**: 296 assertions across 60 cases today, plus the install
  suite; a case per mechanism, added before the mechanism ships.
- **Rollback**: previous releases stay published; the module pre-restores on the
  next boot if a session ever ends in a crash.
- **You verify between stages**, and a stage that misbehaves is fixed before the
  next one starts.

---

## 6. What I still need from you

1. `dumpsys activity recents | head -60` while SPSM is on (Stage 3's parser).
2. Your verdict on Stage 1: status bar back, exit quick, no Low Power mode left
   behind (`cat /proc/cpufreq/cpufreq_power_mode` after exiting should read
   `Default(Normal) mode`).
