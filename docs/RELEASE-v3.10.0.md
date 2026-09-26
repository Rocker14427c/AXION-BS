# Axion SPSM v3.10.0 (versionCode 77)

**The measurement round: the phone was asked where the time goes, and the answers became code. Plus gesture navigation inside the mode — the bottom edge is Axion's now, and Pulse stays suspended.**

This release is the interrupted session's work, recovered from the branch and finished (versioning, zip, release). Its discipline is the owner's: census first, per-component decisions, every old path kept as a fallback, nothing kept without measurement. The full plan and census live in `docs/ARCH-PERF-PLAN.md`.

## The census (measured on the owner's RMX3430, 2026-09-25)

A full daily round with PATH shims counting and timing every spawned command, while the phone was used normally with a 15-second screen timeout: **6,354 calls in 488 seconds**.

| call | count | avg under load |
|---|---|---|
| get-standby-bucket | 1,113 | 84ms native / 300–480ms via the am-fan |
| appops get | 1,104 | 80ms |
| appops set | 1,083 | 69ms |
| set-standby-bucket | 552 | 59ms |
| force-stop | 188 | 82ms |
| settings get/put | 87 | 82–140ms (native `cmd settings`: 28–36ms) |

The reading: **the churn is the cost, not any single call.** With a 15s screen timeout, every screen-off is a new idle period, and each one re-ran the per-app restriction passes — ~48 of them in eight minutes, ~100 binder calls each, `am`+`cmd` burning ~750 CPU-seconds in a 488s window. Every one of those calls is a full `app_process` JVM start; that is what `settings`, `pm`, `am`, `cmd`, `appops` are.

## What was built from it

1. **Deep grace (`deep_grace_secs`, default 75).** Screen-off now applies only the cheap deep knobs; the per-app restrictions wait until the screen has *stayed* off 75 seconds — the daemon's core-sleep timer mechanism, mirrored exactly, and the wake clears the marker. A 15-second screen-off never pays for them: this kills ~90% of the passes the census counted. `deep_grace_secs=0` restores the v3.9.0 behavior exactly.
2. **Native command paths first.** `cmd settings`, `cmd activity`, `cmd package` instead of the `settings`/`am`/`pm` JVM wrappers (a third of the cost under load), each with the old command as the fallback, keeping the `su 2000` identity order of the batch chains.
3. **`spsm-tool.jar` — one JVM for the whole batch.** A dex jar run through `app_process` as uid 2000 that hands each batch line to the service's own shellCommand entry point in-process: the platform's bytes, permissions and result codes, minus fork+exec+runtime per call. Wired into the per-app knobs' read/write batches and the exit's unstop fan (**187 calls, one JVM**). The fan stays byte-for-byte the reference: the suite proves the tool's record equals the fan's, and any short or dead answer falls back to the fan over idempotent writes.
4. **Fork hygiene verified, not guessed:** `now_epoch` was already forkless on the device (mksh `%(%s)T`); the steady-state daemon and screenmon were measured clean and left alone.

### What was deliberately NOT done

* **No C++ port of the transitions.** The work *is* binder calls to system services; once JVM starts are batched, the shell orchestrates at syscall parity. A C++ orchestrator would duplicate libbinder's private surfaces for no measured gain.
* **No native settings writes via IContentProvider** — private, version-fragile; the tool covers it through the platform's own entry points.
* **No evdev grab / uinput remap for gestures** — that consumes every touch on the phone; unacceptable latency risk. The recognizer READS only.

## Gesture navigation inside the mode (the owner's ask)

The symptom: with gesture navigation, swipe-up and swipe-hold did nothing in the mode, so the mode forced three-button nav. The root: the bottom edge belongs to the **default launcher's TouchInteractionService** (a signature-permission input monitor bound by SystemUI). The mode suspends Pulse — correctly, it is the point of the mode — and the gesture pipeline dies with it.

**Plan D, shipped: `spsm-gesturemon`.** One small static native binary (~58KB, both ABIs), built like `spsm-screenmon`: `poll()` over the touchscreen evdev (auto-discovered, screen geometry from the panel's own absinfo), a timerfd for the hold, a signalfd for the exit. **Zero CPU between touches; no grab, no uinput — every normal touch keeps working.**

* Swipe up from the bottom band → Axion home.
* The same swipe **held 350ms** → Axion's own recents (`SpsmRecentsActivity`), fired while the finger is still down — Pulse never runs, so no second launcher, no extra drain.
* 500ms cooldown swallows the bounce; commands are config-overridable.

It only takes the edge when the mode owns the situation: gated on `cfg gesture_nav` (default on), the phone actually being in gesture mode, **and** the launcher being in the mode's own blocked record — the recognizer stands in for the pipeline *we* suspended. `apply_nav_buttons` now keeps gestures for the session when the recognizer is present (nothing written, nothing to undo); without it, the v3.9.0 three-button path runs unchanged. The engine starts it at the end of activation and stops it first on exit, so Pulse's service reclaims the edge before Pulse is unblocked.

## Verification status — honest ledger

| proof | state |
|---|---|
| Main suite | 740 checks / 95 sections green (92: deep grace; 93: tool byte-equivalence + fallbacks; 94: gesturemon wiring, gates, pid lifecycle, nav interplay; 95: recognition semantics against the host build) |
| Codec / install / daemon suites | green (daemon 19/19) |
| Gesture recognizer semantics | proven on the host through the same state machine the device path runs (`--script` mode, synthetic touches) |
| Census | measured on the device (above) |
| **On-phone proof** | **PENDING** — a real finger on a real evdev device, the recents activity actually coming up, and the before/after benchmark round (activate/deactivate/deep walls, fork counts, CPU-s) — the tunnel died before it ran; numbers get appended here when it does |

Every new path ships with its old path as the fallback, so the zip is safe to flash before the benchmark round: no jar → the fan runs; no gesturemon binary (or `gesture_nav=0`, or a phone not on gestures) → the v3.9.0 three-button behavior; `deep_grace_secs=0` → the v3.9.0 deep phase.
