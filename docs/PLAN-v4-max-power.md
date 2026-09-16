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
1. **`mtk_low_power`** — MediaTek Low Power mode. **Shipped in v3.3.0, unblocked.**
   The blocking question was answered on the device: with SPSM off, writing `1`
   reads `Low Power mode`, writing `0` reads `Default(Normal) mode` **about a
   second later**. v3.1.0's `want [0] got [1]` was a read taken in the same breath
   as the write — there was never a refusal. The option records the token, verifies
   entering, verifies leaving (retried up to two seconds), never writes a state it
   cannot map, and is on by default with its own switch. `do_deactivate()` releases
   it before `phase_deep_revert`, which is what removes the phantom `powersave`
   drift and the 41-second exit.
2. **`cap_in_use`** (today's `cap_always`): CPU/GPU ceilings and the offline cores
   held while you use the phone. **On by default since v3.3.1**, at the owner's
   direction - it is the largest in-use saving available and this is an emergency
   mode. Still one switch, and the tests that are about waking now state it.
3. **`ppm_hard_limit`** — use `/proc/ppm/policy/hard_userlimit_max_cpu_freq`
   (kernel-enforced) instead of only `scaling_max_freq`, which a governor change
   can walk back. This is the mechanism FKM-style apps fight with; ppm wins.
4. **`brightness_cap` fixed for in-use** — the probe measures it with the screen
   *off* today, which is why it always reported "nothing to do here".
5. **Background culling with the screen on** (non-slot *user* apps suspended while
   the mode is on, not only while asleep), plus `max_cached_processes` and the
   cached-app freezer verified enabled on this ROM. Plain-language warning, own
   toggle, own probe verdict.
6. **`blur_off`** — window blur off for the duration of the mode (shipped in
   v3.3.0, **on by default since v3.3.1** by the owner's direction; its
   description says the interface looks plainer, and the switch takes it back).
7. **`statusbar_on`** (v3.3.1) — clears a system-wide immersive rule
   (`Settings.Global.policy_control`) while the mode is on and puts it back on
   exit. Added because a status bar can be hidden from outside the app as well as
   by the app's own theme; the probe reports whether this phone has such a rule.
8. **`host_recents_off`** (v3.4.0) — the launcher's own recents screen
   (`mRecentsComponent`, read from the phone's task dump: on this ROM
   `com.android.launcher3/com.android.quickstep.RecentsActivity`) is switched off
   for the session and its recorded setting put back on exit. Added because
   swiping up — or going home from an app — kept starting the launcher and
   drawing its screen over whatever the user was doing. Component on/off state is
   exact and reversible; a state that cannot be read is never written, and a
   change that cannot be verified is never claimed (the knob returns 2 and says
   so).

Still open in Stage 2: item 3 (the kernel-enforced `/proc/ppm` ceiling), item 4
(the brightness probe measured with the screen on) and item 5 (culling with the
screen on).

### Stage 3 — the recents, and the home screen

Shipped as v3.2.0, corrected in v3.4.0:

- `recents.sh` reads the task list itself and switches tasks directly, so the
  launcher is never started to switch apps.
- The owner's report on the v3.2.0 behaviour: closing an app from that list did
  nothing, however many times it was tried. Cause: the removal trusted the exit
  code of `am task remove`, and on this ROM that command is answered and does
  nothing. Closed tasks are now **verified against the phone's own list**, every
  form of the command is tried, and the app is stopped when the task will not go;
  switching is verified the same way.
- The way into the list is a button (and a long press on the home screen) rather
  than the swipe: swiping up from the bottom edge belongs to Android's gesture
  navigation, which opens the launcher's recents before any app sees it. Item 8
  above switches that screen off for the session.
- v3.4.0 also redesigned the home screen in the spirit of a phone's own super
  power saving mode (large centred clock kept, date under it, 3x2 grid of large
  rounded containers, edit mode for taking an app out of a slot, battery and
  estimate near the bottom, white/grey only, exit as a dark sheet from the bottom
  with a red Exit).

Corrected again in v3.4.1: **v3.4.0 shipped a build that could not be opened at
all** — the redesigned app containers became `FrameLayout`s (they had to, for the
edit badge) while the setup screen and the home screen went on casting them to
`LinearLayout`, which Android refuses on resume. The source compiles, and no test
of the scripts inflates a layout, so nothing in the pipeline saw it: the phone
found it. The screens now ask for a plain `View`, and three checks were added —
a source audit of every view lookup against its layout, a read of the *built
APK's* dex for the fixed method signatures, and a test case that replays the
crash through the audit so the audit is known to work. The rule that came out of
it: **an app build is not shippable until something has opened every screen's
start-up path**, and where that cannot be done off the phone, the checks above
stand in for it.

### Stage 4 — system components, by proof rather than by prediction
*(supersedes the earlier "user apps only" choice: that rule was safe but left the
non-essential system services untouched even when diagnostics can identify them)*

**Policy — the one that fits this phone and this project:**
1. **Nothing is ever named from my judgement alone.** A component is a candidate
   only because the phone's own data says it is idle and unimportant: not bound
   by anything, not in the battery statistics, no wakeups of its own, no ongoing
   notification, not a foreground service.
2. **Weaker levers first, and only these until proven:** App Standby bucket →
   AppOp restriction → cached-app freezer. `pm disable` on a system package is
   **not used at all**, because it is the least reversible and the most likely to
   break something silently.
3. **Each candidate is its own toggle**, default off, with a probe verdict that
   says what it actually freed (PSS/CPU from your own device), like every other
   option in the list.
4. **Protected by default, always, whatever any diagnostic says:**
   `system_server`, `zygote`/`zygote64`, `netd`, `vold`, `logd` (our logging),
   `surfaceflinger`, `servicemanager`, `hwservicemanager`, `vndservicemanager`,
   `init`, `ueventd`, `lmkd`, `keystore2`/keymaster, `statsd`, `tombstoned`,
   `android.system.suspend-service`, `wmt_launcher`, all `tee*`/trusty threads,
   RIL/telephony (`com.android.phone`, telephony providers), `com.android.systemui`,
   the permission controller, Bluetooth/NFC core, the launcher while `home_swap`
   is on, and **kernel threads as a class** (they are not app processes: there is
   no `pm suspend` for them and no honest way to undo one).
5. **Proven-reversible is the entry price**: the same rule that just removed
   MediaTek's Low Power mode from `cpu_cap` because the phone did not accept
   leaving it. A component that fails its own revert in the probe is never
   offered.

**The better way I would use instead of a hand-written list:** most of the saving
is available *without naming any system package at all*, by changing what the
system is allowed to keep rather than which packages are killed —
- `max_cached_processes` (how many cached processes survive at all),
- the cached-app freezer (verified enabled on this ROM),
- Doze + App Standby for everything outside the six slots,
- Android battery saver, which this ROM already wires into SystemUI and Doze.

That combination is ROM-agnostic, cannot break a service by name, and reverts by
putting the same numbers back. The named-component list is then only the last
few percent, opt-in, per item — which is exactly the policy you described.

### Stage 5 — prove it, then hand over a "Maximum" preset
1. In-use drain measurement (today `drain.log` only measures sleep), so every
   claim above is a number from your phone, not an estimate.
2. A single **Maximum** preset that enables every option your own probe reports
   as working and safe, with a one-screen list of what it will do and one tap back.

---

## 4b. What v3.4.1 changed in the engine

- The per-app loops (suspend every app outside the six slots, release them on
  exit, freeze/unfreeze the Google packages) ran one app at a time: three shell
  commands each, about a dozen apps, and the v3.3.1 log showed a 45-second exit
  where the power-mode release itself took one second. They run together now, and
  the results are written down afterwards in the same order as before, so the
  journal is byte-for-byte the same kind of record.
- Every step of an apply and a revert is timed, and any step over two seconds is
  named in the log: a slow exit can now be attributed instead of guessed at.

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

1. **The recents output** (it did not arrive last time — the message contained the
   placeholder line instead). While SPSM is on:
   ```
   su -c 'dumpsys activity recents | head -80' > /sdcard/recents.txt
   ```
   and send `recents.txt` the way you send the log. Stage 3 is written against
   that, not against a guess.
2. **The power-mode experiment**, with SPSM **off**, so we can put MediaTek's Low
   Power mode back in the toolbox safely (it is the biggest in-use lever):
   ```
   su -c '
   echo "now: $(cat /proc/cpufreq/cpufreq_power_mode)"
   echo 1 > /proc/cpufreq/cpufreq_power_mode
   echo "after 1: $(cat /proc/cpufreq/cpufreq_power_mode)"
   echo 0 > /proc/cpufreq/cpufreq_power_mode
   sleep 1
   echo "after 0 (+1s): $(cat /proc/cpufreq/cpufreq_power_mode)"
   echo "profile: $(cat /proc/ppm/profile 2>/dev/null)"
   echo "enabled: $(cat /proc/ppm/enabled 2>/dev/null)"
   echo "gov: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
   '
   ```
   If the last line does not read `after 0 (+1s): Default(Normal) mode`, the phone
   is in Low Power mode and a reboot clears it — say so and I will find the release
   path from the rest of the `/proc/ppm` tree instead of guessing.
3. Your verdict on v3.1.1: status bar visible, and after exiting,
   `cat /proc/cpufreq/cpufreq_power_mode` reads `Default(Normal) mode`.
