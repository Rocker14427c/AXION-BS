# Architecture & performance plan - the measurement-driven round (2026-09-25)

Owner's brief: make SPSM as fast, responsive, smooth, lightweight, low-CPU, low-RAM,
low-wakeup, battery-efficient and reliable as realistically possible. No blind language
conversion: each component gets the implementation that measurement says is right. Old
paths stay as fallback while new ones prove themselves. Everything below marked
[MEASURE] is a question for the phone, not for theory - the census in section 3 answers
them before any of section 4 is built.

## 1. What exists today (inspected fresh, 2026-09-25, Rewrite @ 59cbd9d)

| component | implementation | state |
|---|---|---|
| transitions & phases | mksh: engine.sh (1375 ln), knobs.sh (2799), lib.sh (1320) | v3.9.0, field-measured: ON 33s/21 knobs, OFF 21-24s, drift=0 |
| steady-state watcher | daemon.sh (480 ln) + native spsm-screenmon (C, static, 418 ln) | event-driven: epoll + uevent(netlink) + POLLPRI(backlight) + timerfd + signalfd; forkless `read -t` naps; adaptive tick (fast until kernel events prove themselves, then slow) |
| screen events | THREE sources: screenmon (kernel), app ScreenReceiver (broadcast -> pokes monitor+daemon), daemon backstop tick | redundancy by design; panel re-read decides |
| UI | APK, 14 Java classes (Home/Recents/Setup/Knobs/AppPicker/KeepAwake/Tile/Receivers), built by repo pipeline (aapt2+ecj+d8+apkpack+apksigner) | Root.java already has a PERSISTENT ROOT SHELL for short reads (28x cheaper than per-call su); long jobs one-shot su |
| recents | recents.sh: `dumpsys activity recents` + awk, via full engine invocation | works; pays engine startup + one JVM per open |
| nav during SPSM | engine session tail FORCES three-button (nav_buttons gated by home_swap, "never a saved preference") - v3.5.1 decision after in-app swipe failed (bottom edge owned by system; BAL refused from paused app) | the gesture problem lives here |

Healthy already (do not touch without measurement): screenmon design, daemon nap
plumbing, Root.java session, journal codec + drift=0 verification, two-wave deep phase,
per-run caches, 12-wide fans.

## 2. Where the remaining cost is (static evidence, to confirm by census)

Every `settings`, `dumpsys`, `pm`, `am`, `cmd`, `svc`, `appops`, `input` call is a full
**app_process JVM start** (~40-150ms each under the power-save governor; these commands
ARE app_process wrappers). Source-site census: knobs.sh alone has cmd x52, pm x31,
am x29, dumpsys x22, settings x18, svc x17, appops x11 call sites. snap_kv/apply_kv
already fan these in parallel, but a fan of N JVM starts on 4 little cores is still
N/4 x startup serialised - one JVM doing N in-process operations (~1-5ms each via
binder) is the structural win.

Second-order costs: `su 2000 -c` round trips wrapping each of those; per-invocation
mksh startup sourcing ~240KB of scripts (every screen-off/on, recents open, keep/set);
small fork leaks (`rd()` = cat+tr per read; `battery_level` = dumpsys JVM twice per
sleep cycle; `date` per asleep pass).

## 3. Device census (the gate for everything in section 4)

Run with PATH shims (no PATH override in lib/engine - verified) counting + timing every
spawned command, plus /proc/stat deltas:

1. **Fork/exec inventory per transition**: activate, screen-off, screen-on,
   deactivate, recents-open, one keep/set call. Per command: count, total ms, share.
   (strace -f -e execve if present; else shim dir of logging wrappers.)
2. **Steady-state cost**: daemon + screenmon + app process: CPU-seconds/hour and
   wakeup rate (schedstat timeslices) screen-on 3min and screen-off 3min; screenmon
   settled tick (do panel uevents/POLLPRI actually fire on this kernel? decides
   whether the 3s asleep backstop can rise); logcat OverviewProxyService behaviour
   with Pulse suspended (bind-retry noise?).
3. **RAM**: dumpsys meminfo dev.axion.spsm (home resident), Pulse launcher total vs
   its TouchInteractionService share, SystemUI.
4. **Gesture pipeline facts**: `dumpsys input` - who owns the bottom-edge input
   monitor (pid -> package); Pulse package + quickstep/TIS component name + signature
   (platform-signed?); SysUI `OverviewProxyService` dump (config_recentsComponentName
   value, connect state); `cmd overlay lookup` for the same config.

## 4. Candidate implementations (per component - build only what the census ranks)

### 4a. `spsm-tool`: one JVM instead of a hundred (Java, repo toolchain, HIGH priority if census confirms JVM dominance)
A classes.dex jar run as `su 2000 -c "CLASSPATH=/data/adb/spsm/bin/spsm-tool.jar
app_process / dev.axion.spsm.tool.Main <batch>"` (app_process + hidden APIs from
shell uid is the standard root-module pattern - it is literally how `settings`/`pm`/
`cmd` themselves work; one start, N in-process binder calls).
Batch verbs (output contracts byte-compatible with today's shell functions):
settings get/put/delete multi; pm suspend/unsuspend/unstop/stop multi (stdin list);
appops set multi; svc wifi/bluetooth/nfc; input keyevent; am force-stop multi;
recents (ActivityManager getTasks -> id\tpkg\tcomp\tlastActive lines).
Integration: lib.sh routes through the tool when present, falls back to the current
per-call path when not (old implementation stays = the fallback, per owner rule).
Journal semantics unchanged: the tool prints the same `target\tvalue` lines the
snapshots consume; the writes log, synthesis rules and drift verification are untouched.
Test rig: stub tool in tests/ asserting batch==per-call equivalence; suite grows a
section for it.
Expected: activation snapshots+applies from ~40-80 JVM starts to a handful; recents
open without engine startup; release loops one JVM for all 187 packages.

### 4b. Fork hygiene in hot paths (shell, LOW risk, do regardless)
`rd()` via `read` builtin (single-line sysfs values; multi-line callers audited first);
`battery_level` via /sys/class/power_supply/battery/capacity (same integer, no JVM);
audit cat/tr/echo forks in daemon tick + heartbeat paths.

### 4c. Steady state (native/shell - only if census shows a problem)
screenmon/daemon are already event-driven; candidates pending data: asleep backstop
3s -> longer IF kernel events fire on this panel; heartbeat rd forks; date forks.
A native spsmd absorbing the whole daemon was considered and is NOT justified unless
the census shows the shell daemon itself costs measurable CPU/wakeups - the current
design spends its waits blocked in read().

### 4d. Gesture navigation in SPSM (the owner's ask - fork in the road)
Symptom root (established from code history + to confirm on device): with gesture nav,
the bottom-edge swipes belong to the DEFAULT LAUNCHER's TouchInteractionService (input
monitor, MONITOR_INPUT = signature permission; SysUI binds it via
config_recentsComponentName). SPSM suspends Pulse -> pipeline dead -> swipe-up does
nothing. v3.5.1's in-app swipe failed for the same ownership reason + BAL refusal.

**Plan A - full replacement (needs AxionOS platform key; owner builds the ROM):**
platform-sign the APK (build.sh already supports SPSM_KEYSTORE); add
`QuickstepService` (action android.intent.action.QUICKSTEP, foreground while mode on):
InputManager.monitorGestureInput on the bottom edge (MONITOR_INPUT granted by platform
signature), classify short-swipe vs swipe-and-hold, pilfer pointers, then launch home /
SpsmRecentsActivity with START_ACTIVITIES_FROM_BACKGROUND (also signature) - no Pulse
process at all, both gestures are Axion's. Optionally point SysUI at a minimal
IOverviewProxy stub (extract the exact AIDL from the device's SysUI APK with the repo
toolchain) or a fabricated RRO overlay for config_recentsComponentName to silence
bind retries. Engine change: nav force becomes a real choice (cfg nav_mode=gestures
skips the three-button tail when the pipeline verifies).

**Plan B - no platform key:** protect Pulse from block_other_apps + restricted bucket
+ disable its HOME activity component (TIS stays, never draws home): swipe-up works
(TIS launches the HOME intent = Spsm home), swipe-hold shows PULSE's recents (not
Axion's). Cost: Pulse TIS resident RAM [MEASURE: how much]. Honest tradeoff, reversible.

Decision inputs: census item 4 + owner's answer on the platform key.

### 4e. Explicitly NOT planned (measured, reasoned, rejected for now)
- C++ port of transitions/phases: the work IS binder calls to system services; the
  shell orchestrates them at syscall-parity once JVM starts are batched (4a). A C++
  orchestrator would duplicate libbinder's private surfaces for no measured gain.
- Native settings writes via IContentProvider: private, version-fragile; 4a covers it
  through the public ContentResolver from a shell-uid JVM.
- Kernel-side tricks (evdev grab/uinput remap for gestures): consumes every touch,
  unacceptable latency risk; rejected.

## 5. Method (owner's rules, verbatim in effect)

Incremental; old path stays as fallback until the new one proves itself on the device;
benchmark before/after (activate/deactivate/deep/recents latency, fork counts, CPU-s/h,
wakeup rate, RAM PSS); keep only measured wins; never break calls/SMS; no blind CPU
restrictions; preserve every existing feature, workaround and the journal's guarantees
(drift=0). Suite (966 checks) green at every step; new behaviour gets new checks.
