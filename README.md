# Axion Super Power Saving Mode

realme UI-style **Super Power Saving Mode** for **AxionOS 2.7 (Android 16)** on the
**Realme Narzo 50A (RMX3430)**, delivered as a KernelSU / ResukiSU / Magisk module.

Current module: **v3.0.3**.

The headline property of v3 is that turning the mode **off puts everything back**.
Every change is written to a journal before it happens, and a value is only
restored if the phone still has the value we set — if the ROM or you changed it
in the meantime, that newer value wins. There is a test suite that proves this by
running the real scripts against a fake device tree.

## Why this is a rebuild, not a port

The real RUI Super Power Saving Mode is glued into the ColorOS framework, the
stock launcher, `com.oplus.battery` and vendor HALs. Those APKs crash on Axion,
so the feature is rebuilt on AOSP.

| realme UI SPSM | This module (v3.0) |
|---|---|
| Black 6-app home, door to exit | Same UX (`dev.axion.spsm`) |
| Phone / Messages / Browser + 3 | Auto-filled, tap to change |
| CPU / brightness cuts | Caps while **asleep**; nothing is taken offline unless you ask |
| Background apps gone | Standby buckets + background-run denial while asleep, per-app and reversible |
| Panel fully asleep | DT2W off while on; deep doze while asleep |
| Calls still work | Mobile data stays (Jio VoLTE) |
| Restore on exit | Journaled, per-value revert — verified by tests |

## What actually reduces idle drain

Ordered by how much they matter on this device. The first five are what a
default install turns on:

1. **Deep doze while asleep** (`deep_doze`, **on by default**) — puts the device into Doze as soon as
   the screen goes off instead of waiting for the system timers, and releases it
   the moment the screen comes on. Biggest single win, and the reason the mode is
   screen-aware: holding doze while you are using the phone is what makes a power
   mode feel broken.
2. **Background app restriction** (`app_restrict`) — non-whitelisted third-party
   apps go into a restricted standby bucket with background running denied while
   asleep, and are put back on wake. Jobs and alarms are deferred, never cancelled.
3. **Radio** (`wifi_off`, `bt_off`, `nfc_off`, `scan_always_off`) — Wi-Fi and
   background scanning are the biggest idle talkers. Mobile data stays up for
   VoLTE.
4. **Panel and touch** (`dt2w_off`, `aod_off`, `brightness_cap` — a cap that
   only ever *lowers* the screen, so a display you keep dim stays dim) — stops the touch controller and the
   ambient panel waking the SoC.
5. **CPU / GPU caps while asleep** (`cpu_cap`, `gpu_cap`, `ged_boost_off`) — the
   ceiling is lowered only while the screen is off, so wake-up stays instant.

Every one of those is a switch in the app's **Options** screen. Nothing is
all-or-nothing.

### Leaving the screen-off state instantly

Capping the CPU only while asleep is what makes this mode usable, but it is
also a trap: if the cap is still on when you press the power button, the first
few seconds after waking are visibly slow. So the wake-up path is as short as
it can be made:

* The app's `ScreenReceiver` writes the new state and sends `SIGUSR1` to the
  daemon, which cuts its 8 second sleep short - the revert starts in
  milliseconds, not at the next poll.
* If the daemon is not running, the receiver runs `engine.sh screen-on` itself,
  so one writer or the other always acts.
* Inside `engine.sh`, the things you can feel (CPU cap, mobile-data doze) are
  lifted first and the slow per-package work runs after.
* A poke that arrives while the engine is mid-revert is remembered rather than
  lost, so a quick off-on-off still lands on the right state.

The tests measure this: a screen change is acted on in ~250 ms, where a poll
would have taken 8 seconds.

## Install (ResukiSU)

1. Download `Axion-SPSM-v3.0.3-RMX3430.zip` from
   [Releases](https://github.com/Rocker14427c/AXION-BS/releases).
2. **ResukiSU → Modules → Install from storage** → zip → **Reboot**.
3. Open **Super Power Saving** → grant root → **Allow**.
4. **Options** → untick anything you do not want changed.
5. Pick 6 apps → **Turn on**.

Optional: add the **Super Power Save** tile in Quick Settings.

If a previous version is installed, the installer undoes its leftover changes
before installing.

## What changed in 3.0.1

A second, deliberately adversarial pass over every script. Ten things were
wrong; each one was reproduced with a failing test before it was touched, and
the test stays in the suite:

- **The brightness cap could brighten your screen.** It wrote the cap
  unconditionally, so if you kept the panel darker than the cap, switching the
  mode on made it *brighter* — and the exit put back a value that was never
  yours. It now only ever lowers.
- **Exiting forced cores, governor and backlight whenever a journal existed**,
  even for a session where every knob was switched off and nothing had been
  recorded. Your own choices paid for it. It now forces only when a value of
  ours is genuinely still in place.
- **The "phone is stuck dark" net fired on a dim screen you had chosen**, on
  every exit. It now acts only when the journal proves the value is still ours,
  the mode is off, and the screen is on and unreadable.
- **Re-applying the idle phase saved our own values as yours.** The deep phase
  runs again on every screen-off cycle, and each run overwrote the record of
  what your apps looked like — so after a second cycle (or a reboot) every app
  stayed restricted after exit. The first record per idle period now stands.
- **A setting the mode never touched was deleted on exit**
  (`battery_saver_constants`), whatever it held.
- **Sleeping Google re-enabled packages you had disabled yourself.** It now
  only undoes its own change (unsuspend) and leaves your choices alone.
- **An interrupted exit destroyed the record of the phone's real values.** If a
  revert never finished, re-entering the mode made the capped value the new
  "original". Unfinished records are now kept across sessions.
- **A stale lock made the next action fail.** A lock left by a dead process
  waited out a 20-second timer and then reported "busy". It is taken at once
  when the owner is gone; the long override is reserved for a live, wedged one.
- **A value that spans lines came back truncated** at its first line, and a
  value containing a literal backslash-n came back as a newline. The journal is
  one record per line with values encoded, and the codec is an exact inverse.
- **Stepping out of doze was reported as an "external change"** by the verify
  command, because the snapshot recorded a state the system moves by itself.

`tests/run.sh` grew from 19 cases to 30 to pin all of this down.

## What changed in 3.0.2 — the screen, and the cap, in this phone's terms

The device itself settled two arguments this release, and both had been decided
the wrong way by assumption.

**The screen is read the way the phone actually reports it.** The verified
method on the RMX3430 is the panel node: `/sys/class/leds/lcd-backlight/brightness`
is 0 while the screen is off and 1..4095 while it is on. That node is now the
primary source — and a lit panel is accepted outright, whichever other source
disagrees. A dark panel is the weaker evidence, so it is only read as "off"
when the app's marker is not saying "on" at that moment; believing a stale "off"
is the expensive mistake, because it drops the phone into its deep phase while
somebody is using it.

The daemon no longer depends on the app at all. It reads the node through a
redirection — a syscall, not a spawned process — and re-reads it every second
while awake and every three while asleep, so the power button is acted on
without needing an event from anywhere. Measured in the suite: caps engage
500 ms after the panel goes dark with no app, no marker and no signal.

**The app's instant-signal path had never worked.** `SCREEN_ON` and
`SCREEN_OFF` are broadcasts the framework delivers only to receivers registered
at runtime, so the manifest-declared one was dead code and every transition went
unnoticed. It is now registered properly, and registering also republishes the
current state. The module does not depend on it — with a one-second poll it is
an optimisation, not a requirement.

**The dim cap is expressed in this phone's units.** The node here is 0..4095,
not 0..255, so the old raw `160` meant 4% — and the same value on another phone
means something else entirely. `brightness_cap` is now a fraction of the panel
by default (8% = 327 here), also accepts `4%`, and treats anything above 100 as
a raw value for someone who knows their node. A config carried over from a
0..255 phone is used as-is rather than quietly doing nothing.

**The emergency lift is scaled to the panel too.** It fired below a raw 40 and
lifted to a raw 128 — calibrated for a 0..255 node, so on this one the "lift"
would have been barely brighter than the cap it was lifting. It now acts below
10% of the panel and lifts to 40%, whatever the panel's range.

**The repository can rebuild the app that ships.** The options screen and the
screen receiver existed only as uncommitted files in one working tree, so a
fresh clone built an APK without the per-change opt-out screen. They are
committed now, and `build.sh` recomputes the APK from them.

## What changed in 3.0.3 — the crash that took the home screen down

The first on-device run of 3.0.2 crashed, and the log from the phone was
unambiguous:

```
java.lang.NullPointerException: Attempt to invoke virtual method
  'android.view.WindowInsetsController ...DecorView.getWindowInsetsController()'
  on a null object reference
  at com.android.internal.policy.PhoneWindow.getInsetsController(PhoneWindow.java:4136)
  at dev.axion.spsm.SpsmHomeActivity.hideSystemBars(SpsmHomeActivity.java:64)
  at dev.axion.spsm.SpsmHomeActivity.onCreate(SpsmHomeActivity.java:38)
```

`hideSystemBars()` was called before `setContentView()`, so the window had no
decor view yet and `PhoneWindow.getInsetsController()` threw. The activity that
died was **the SPSM home screen** — the one the mode swaps in — and a home
activity is restarted by the system the moment it dies. So the result was a
crash loop and a phone with no home screen at all, which is what "the app
crashed and many more things happened" was.

Two fixes, because one of them was a whole class of failure rather than this
one crash:

- **The activity can no longer be taken down by a cosmetic call.** The decor
  view is obtained after the content view exists, the insets call is made on
  that view, and the whole method is guarded: hiding the status bar is never
  worth the phone's home screen.
- **The module no longer swaps the home in without checking.** After launching
  the new home it asks the device which activity is actually resumed. If the
  answer is "not ours", the user's launcher is put back immediately and
  `home_swap` is recorded as restored, so nothing later chases a change that was
  already undone. If the device will not answer, the swap is left alone rather
  than undone on a guess.

The second fix means this failure mode cannot leave a phone without a home
again, whatever the reason: a crash, a ROM that ignores the role change, an
activity disabled since. `tests/run.sh` now covers both directions — a home that
never comes up gets the launcher back within seconds while the rest of the mode
carries on, and a home that does come up is left alone (no false alarms).

### Getting out without the app

The KernelSU/ResukiSU manager's **Action** button toggles the mode with no app
involved (module `action.sh`). If the home ever looks wrong, this puts it back:

```sh
su -c 'cmd role add-role-holder android.app.role.HOME com.android.launcher3'
su -c 'cmd package set-home-activity com.android.launcher3/.Launcher'
su -c 'am start -a android.intent.action.MAIN -c android.intent.category.HOME'
```

## Measuring it

Claims about battery life are worth nothing unmeasured, so the daemon measures
its own sleeping drain and writes it to `/data/adb/spsm/drain.log`:

```
2026-09-10 23:41:02 screen off 84% -> 82% in 421 min (0.28%/h)
```

One line per sleep: the level as the screen went off, the level when it came
back, and the rate in between. If the numbers do not look like the 4-5% a night
this is meant to replace, `/data/adb/spsm/spsm.log` next to it says which knobs
were applied and which were left alone.

## Guaranteed revert

`module/scripts/engine.sh` is the only thing that changes anything:

- **Snapshot first.** Before a knob is touched, its current value(s) are written
  to `/data/adb/spsm/journal/<knob>.orig`. The value we then set is stored
  separately as `.applied`.
- **Per-value revert.** On exit, each target is re-read. It is written back only
  if its live value still equals what we set. A value you changed yourself after
  us is left alone and logged as `keep <knob>`.
- **LIFO order.** Changes are undone in the reverse of the order they were made.
- **Drift is visible.** `engine.sh verify` re-reads everything and reports any
  value of ours that is still in place, as `drift=N`.
- **Crash safety.** `post-fs-data.sh` runs before the system is up and, if a
  journal exists, forces cores online and puts back a sane governor and a visible
  panel. A reboot or a flat battery can never leave the phone crippled. On the
  next boot the mode is *reverted*, not resumed (unless `resume_on_boot=1`).

Missing nodes are recorded as `(MISSING)` and skipped on restore, so the engine
never invents a value or writes to a node that was not there.

## Options, and why the app cannot lie to you

The scripts are the source of truth. `engine.sh dump-knobs` writes
`/data/adb/spsm/knobs.list` from the same registry the engine executes, and the
app's Options screen renders that file. A switch that appears there is a change
the scripts really make.

Turn a knob off and it is never touched — no snapshot, no apply, no restore.

## Commands (root)

```sh
sh /data/adb/spsm/scripts/engine.sh status       # what is on and what is applied
sh /data/adb/spsm/scripts/engine.sh verify       # is anything still changed?
sh /data/adb/spsm/scripts/engine.sh toggle       # on / off
sh /data/adb/spsm/scripts/engine.sh set deep_doze 1
sh /data/adb/spsm/scripts/engine.sh deactivate   # full revert
```

Log: `/data/adb/spsm/spsm.log`. Journal: `/data/adb/spsm/journal/`.

## If you get stuck

- Door icon (top left) → Exit.
- ResukiSU → Modules → remove this module → reboot. Uninstall reverts first, then
  removes itself.
- Root shell: `sh /data/adb/spsm/exit.sh`
- Emergency undo scripts are in `tools/`. Read-only diagnostic:
  `sh tools/DIAG.sh` (writes nothing).

## Build

The build is reproducible and fetches its own toolchain — no SDK install and no
hardcoded paths:

```sh
./build.sh --bootstrap        # downloads the toolchain once, then builds
./tools/makezip.sh            # flashable zip from module/
sh tests/run.sh               # device behaviour, no phone needed
sh tests/run-install.sh       # the APK install fallback chain
```

`tests/run.sh` runs the real engine scripts against a fake device tree with
stubbed Android commands, 35 cases and 153 assertions. It asserts, among other
things, that entering and leaving the mode leaves that tree **byte-for-byte
identical**, that a value you changed yourself is never overwritten, that a
crash-and-reboot puts the phone back, that a normal boot touches nothing at all,
that a screen change is reacted to well inside the poll interval, that an exit
cannot be undone by a screen-off that was already in flight, that the drain
report is arithmetically right, and that the shipped defaults are themselves
fully reversible. `tests/run-install.sh` drives `install-apk.sh` through a stub
`pm`: first-try success, the signature-mismatch recovery, the package-already-
present case, and outright failure (which must not silently pretend to work).

Toolchain sources are public registries: `jdk4py` (PyPI), `aaptjs3` and
`@drxiaozhi/minapk` (npm, which carries the official `d8`, `apksigner` and an
Eclipse compiler), and `Sable/android-platforms` (GitHub) for `android.jar`. If
`ANDROID_HOME` / `JAVA_HOME` already point at an SDK and JDK, those are used
instead. `resources.arsc` must be **STORED** and 4-byte aligned; `tools/apkpack.py`
does that in Python so no `zipalign` binary is required.

`ci/build.yml` is the same thing for GitHub Actions: it runs both suites, builds
the APK and the zip, and uploads them as artifacts. It lives outside
`.github/workflows/` because the token used here is not allowed to write
workflow files - move it into place (`mkdir -p .github/workflows && mv
ci/build.yml .github/workflows/`) and it runs on the next push.
