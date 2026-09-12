# Axion Super Power Saving Mode

realme UI-style **Super Power Saving Mode** for **AxionOS 2.7 (Android 16)** on the
**Realme Narzo 50A (RMX3430)**, delivered as a KernelSU / ResukiSU / Magisk module.

Current module: **v3.0**.

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
4. **Panel and touch** (`dt2w_off`, `aod_off`) — stops the touch controller and the
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

1. Download `Axion-SPSM-v3.0-RMX3430.zip` from
   [Releases](https://github.com/Rocker14427c/AXION-BS/releases).
2. **ResukiSU → Modules → Install from storage** → zip → **Reboot**.
3. Open **Super Power Saving** → grant root → **Allow**.
4. **Options** → untick anything you do not want changed.
5. Pick 6 apps → **Turn on**.

Optional: add the **Super Power Save** tile in Quick Settings.

If a previous version is installed, the installer undoes its leftover changes
before installing.

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
stubbed Android commands. It asserts, among other things, that entering and
leaving the mode leaves that tree **byte-for-byte identical**, that a value you
changed yourself is never overwritten, that a crash-and-reboot puts the phone
back, that a normal boot touches nothing at all, that a screen change is
reacted to in under a second, and that the shipped defaults are themselves
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
