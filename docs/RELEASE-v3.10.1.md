# Axion SPSM v3.10.1 (versionCode 79)

**The reunion release: the phone's v3.9.2 — the lost session's field-caught race round, which existed only on the device — is now the branch's tree of record, and the two bugs its own logs caught are fixed and regression-tested.**

Version map, because two lines diverged on 2026-09-25 and this release ends that:

| line | what it was | where it is now |
|---|---|---|
| GitHub v3.10.0/77 | the perf round (deep grace, native cmd paths, batch tool, gesturemon) | superseded by this release |
| device v3.9.1/77 → v3.9.2/78 | the same perf round PLUS the race fixes, evolved on the phone only, never committed | recovered file-by-file into `recovery/device-2026-09-25/`, adopted here |
| **v3.10.1/79** | device v3.9.2 + both field bugs it caught fixed + jar source recovered | **this release** |

A three-way diff (v3.9.1 backup ↔ GitHub HEAD ↔ device v3.9.2) proved v3.9.1 was byte-identical to HEAD for eight of nine scripts and that v3.9.2's lib.sh was a strict superset of HEAD's — so adopting the device tree wholesale lost nothing from either side.

## What v3.9.2 brought (device-proven, now in the branch)

1. **The batch tool actually runs (rc=134 root cause).** KernelSU keeps `/data/adb` at mode 700 root, so uid 2000 cannot read the CLASSPATH jar at all and ART aborts with a misleading `DEX2OATBOOTCLASSPATH` error. The tool now lives as a runtime copy in `/data/local/tmp/spsm/` (755 dir, 644 jar), republished every boot, and the proof-of-life runs from *that* copy — proving the unreadable master would prove nothing but root's own eyesight. Device evidence: `repair.log` — 171 packages read in one batch, 111 writes, zero failures.
2. **The 21:27 stranding is contained.** A deactivate landed while the grace-deferred restrict pass was still applying; the exit's journal sweep deleted the in-flight knob's records, the pass finished anyway, and 31 standby buckets + 80 appops writes were left with nothing on record. Now: a knob mid-apply says so in the journal (`applying`), records are written **before** the writes they authorize (batch and fan paths), workers stand down when the session marker dies, the exit gives an in-flight pass a bounded moment (≤45s) to stop via `deep_restrict.pid`, the pass reverts its own writes if its session vanished, and an unreadable value at restore time is restored **from the record** instead of being skipped. The night's stranding itself was repaired on-device (`repair.log`: writes=111, rc=0; verify scan clean).
3. **Milliseconds per operation instead of 30 seconds.** The tool's result receiver is pumped the way the platform's own `cmd` pumps it (see the recovered Main.java below).

## Fixed in v3.10.1 — the two bugs the device logs caught

### 1. The false drift that cost one exit 70 seconds

Device log, 23:52: `WARN cores_sleep did not return: /sys/devices/system/cpu/cpu6/online: want [1] got [1]` — a drift alarm about a value that had *never moved*. The kernel refused cpu6 in **both** directions that night: the sleep write did not take (the applied journal honestly recorded `1`), and the identical write-back on the way out got EPERM. The restore logged the refused no-op as `failed`, the verdict counted one drifted knob, and the safety valves ran: a 70s exit.

**Fix:** a refused write whose value already stands at the recorded original is a no-op success — `wrote`, not `failed`. A value that merely could not be *read* still fails (the guard compares a real reading; an empty read matches nothing). Plus: `safety_force` no longer leaks `can't create cpu0/online: Permission denied` into the log mid-exit (cpu0 is read-only on this kernel; the redirect failure now dies inside a subshell).

**Regression test 7b** reproduces the device scenario end-to-end on the rig: `chmod 444` on the fake `cpu6/online`, fire core-sleep, assert the honest applied record (`cpu6 = 1\n`), the honest log (`5 core(s) asleep`), wake, and a journal closed as `restored` — not `restored-drift` — with no `did not return` anywhere.

### 2. Gesture dispatch — recognised swipes that went nowhere

`gesturemon.log` from the owner's phone: three real swipes recognised (`home (dy=209 in 177ms)` …), each followed by `cmd: Failure calling service input: Failed transaction (2147483646)`. Recognition worked; **dispatch never landed** — that is exactly why the owner's swipes did nothing. The defaults used the native `cmd` binary, whose binder call dies in the recognizer's nohup'd root context, while the engine's own app_process `input`/`am` calls run from the same context class all day.

**Fix:** dispatch defaults are now `input keyevent 3` (home) and `am start --user 0 -f 268435456 -n dev.axion.spsm/.SpsmRecentsActivity` (recents). `cfg gesture_home_cmd` / `gesture_recents_cmd` still override per phone. Suite section 94 now asserts the exact argv the recognizer is started with.

### 3. The recognizer follows the first finger on ANY slot (source now matches the device)

The panel hands real swipes slots 2, 3, 5, 7 — HEAD's C source still filtered slot 0 only and threw all of them away; the device binary had the fix, the source did not. The MT state machine is rewritten in source: the first finger DOWN owns the gesture whatever slot the driver assigned, other fingers are palm noise until the owner lifts, single-touch panels behave as before. Both ABIs rebuilt with zig 0.13 and proven by loading on the phone at publish time.

### 4. The jar's source recovered from the device binary

The device jar (6,256 B) differed from the committed source's build. Rather than guess, its `classes.dex` was decompiled (jadx) and the lost session's changes ported into `tool/src/Main.java` exactly:

- `ArrayBlockingQueue(1)` instead of `SynchronousQueue`: an offer with no waiting poller **dropped** the result code that arrived while the main thread was still draining the output pipe — the poll then burned the full 30s ceiling for an answer already in hand.
- `pumpBinder()`: a cheap `getService("activity")` between ≤250ms poll slices — an idle app_process JVM does not get its binder callbacks serviced promptly; the platform's `cmd` never stands still like that.
- One `nanoTime` deadline for the whole wait.

Rebuilt through the documented toolchain (ecj + d8 8.2.2-dev, min-api 31, release): the new `classes.dex` strings are diff-clean against the field-proven device jar (identical D8 header sha-1). The branch's jar is the rebuild — source and binary say the same thing again — and the device-proven jar stays in `recovery/` as the fallback.

## Suites

`tests/run.sh` **749 passed, 0 failed** (incl. the new 7b and the section-94 argv assertions), codec **252/0**, daemon **19/0**, install **22/0** — on the fully reconciled tree. (One earlier run showed 83 failures: all bounded-wait assertions, caused by concurrent toolchain builds saturating the sandbox CPU; the clean re-run is green.)

## Device verification status

Honest ledger at cut time: the reconciled tree is deployed-and-benched **pending** — the Pinggy tunnel expired before the payload (scripts + rebuilt natives + jar + `bench5.sh`) could ship. `bench5` waits to prove, on the phone: foreign-slot gestures **with the focus actually moving** (recognition alone no longer passes; the corrected recents injection moves 30px over 500ms — bench4's 79px-in-two-frames was correctly read as a home swipe: the harness was wrong, not the recognizer), `dispatch_failures=0` in the recognizer log, the exit race live (deactivate 8s into the grace pass → bounded stand-down, no false drift, no safety valves, zero stranding, journal/pidfiles closed), and the clean-cycle scorecard. This release is cut when that log is green; until then v3.10.0 remains the latest *device-benched* zip, and this branch state is the tree of record.

## Recovered artifacts

`recovery/device-2026-09-25/` (committed, 170+ files): the deployed v3.9.2 scripts, the device binaries, `spsm.log`/`gesturemon.log`/`drain.log`, the bench1–4 harnesses and logs, the stranding repair log and script, the v3.9.1 backup that made the three-way diff possible, and the config/journal/state of the phone as it stood. Everything claimed above is sourced from those bytes.
