# SPSM performance and architecture work

What was changed, what it was measured against, and — just as important — what
was deliberately left alone.

The brief was "make it as fast, light and battery-efficient as realistically
possible", explicitly *not* "rewrite it in C++". So the first job was to find
out where SPSM actually spends its time and its wakeups, rather than assume the
shell was the problem.

---

## The headline: the daemon was a busy loop

`daemon.sh` waits between passes in `nap()`. It used a fifo plus `read -t` to
get an interruptible sleep without forking `sleep`, and decided whether that
worked by checking that the fifo **opened**.

That check proves nothing. `dash` — and several Android `/system/bin/sh`
builds — accept `-t`, ignore it, and return immediately. On those shells the
nap returned instantly, every time, and the daemon spun as fast as the CPU
allowed for as long as the mode was switched on.

| 10 s idle, screen off | before | after |
|---|---|---|
| forks | 30,827 | 20 |
| loop passes | 5,400 in 2 s | 2 |

A module whose entire purpose is to stop the phone waking up was pegging a core
the whole time it ran. On a phone this is not a micro-optimisation; it is the
difference between the feature working and doing the opposite of what it claims.

The fix is `nap_probe()`: measure the elapsed time of a real one-second `read
-t` at startup and only trust the fast path if the clock actually advanced.
A capability is now proven, never assumed.

`tests/run-daemon.sh` asserts this with **CPU time**, which is the only thing
that catches it — a spinning loop looks perfectly healthy if you count ticks.

---

## The architectural change: events instead of polling

With the spin fixed, the daemon still woke **once a second, ~86,400 times a
day**, purely to read one number out of sysfs and usually find it unchanged.
Every one of those is a timer that stops the SoC reaching its deeper idle
states.

This is the one place where native code buys something a language benchmark
cannot show: **a shell cannot wait on a kernel event.** It has `sleep`. So
`native/spsm-screenmon.c` (~29 KB static, no libc dependency on the ROM) blocks
in `epoll_wait` on four sources:

- the kernel **uevent netlink** socket — a real panel change arrives in
  microseconds;
- **`EPOLLPRI`** on the brightness attribute, for drivers that call
  `sysfs_notify()`;
- a **timerfd** backstop, so a silent kernel still behaves exactly as before;
- a **signalfd** for `SIGUSR1`, so the APK's instant poke stays instant.

Measured: **0 CPU ticks over 8 s blocked, ~880 kB RSS.**

### It earns its interval rather than assuming one

Whether a kernel announces backlight changes is not knowable in advance — it
differs by SoC, by ROM, and between the `leds` and `backlight` classes on one
phone. So the monitor **starts at the old poll rate and only relaxes once an
event has actually delivered a change the timer had not already found**. If an
event source is ever caught missing one, it drops back and stays there.

This is what makes it safe to ship to hardware nobody can test on: there is no
device on which it is a downgrade. On a phone that announces, ~86,400 timer
wakeups a day become ~2,880 **and the power button gets faster** (an event, not
a poll). On a phone that does not, nothing changes.

The daemon treats it as strictly optional. Missing, unbuildable, wrong-ABI,
failed or killed mid-run — every path falls back to the original poll with all
loop logic, rules and fallbacks untouched.

### Three bugs measurement caught that review did not

1. **"Any uevent" is wrong on a phone.** Treating every uevent as a doorbell
   looks safely general. But a phone announces battery, charging, thermal, USB
   and network constantly, so the daemon was woken hundreds of times an hour
   for events with nothing to do with the screen — the event path used *more*
   CPU than the poll. The payload is now filtered for display-ish subsystems.

2. **A flat 1 s fallback is three times the old asleep rate.** The poll was 1 s
   awake but **3 s asleep**, and asleep is where a phone lives. Measured: 30 s
   asleep cost 41 daemon wakeups polling but 150 on the untrusted event path.
   The monitor now mirrors the poll exactly until events are trusted. Being
   faster than what you replaced is not an optimisation if nobody asked for it
   and it costs battery.

3. **The fifo rendezvous was a silent race.** Starting the child with
   `> "$fifo"` and then unlinking it is a race the unlink can win: the child's
   redirection happens *after* the fork, so it recreates the path as a **regular
   file** and writes events into it forever. Everything looked healthy — helper
   running, 0 CPU, daemon blocked on a real fifo — but they were attached to
   different inodes and not one event was ever delivered. Both ends are now
   opened *before* the child starts, and the descriptor is passed, not the path.

Related: engine children are now started with `3<&- 4<&-`. A child inheriting
the monitor pipe **competes for its lines**, and one line delivered to the wrong
process is a wakeup the daemon never sees.

---

## Where the forks actually were

Profiled with an `LD_PRELOAD` exec shim (`tests/bench/execprofile.c`) — this
host has no `strace`/`perf`, and `/proc/stat`'s global counter is useless here.

`status` ran **180 execs**, and they were not spread thin:

| calls | what | why |
|---|---|---|
| 36 + 32 | `sed -n` + `tail -1` | every `cfg` lookup |
| 31 | `awk -F\|` | every `knob_scope` / `knob_default` |

So three helpers accounted for essentially all of it. All three are now
fork-free: `cfg` reads the file once into a cached variable
(`cfg_load`/`cfg_invalidate`), and `knob_field` does the split with shell
parameter expansion. `esc`/`unesc`/`cmp_val`/`snap_get`/`snap_targets` got the
same treatment.

**`tests/run-codec.sh` (242 checks)** pins every one of these against a verbatim
copy of the implementation it replaced. A faster helper that changes an answer
is a bug, and this is the file that stops it.

---

## A real bug found on the way

Case 60 had been failing before any of this work: every exit *after an app was
moved into one of the six slots* reported drift.

Moving an app into a slot frees it, so it stops being a blockable package and
the next snapshot has **no row for it at all**. The verdict compared that
absence against the recorded original and read it as `want [0] got []` — naming
as "unrestored" an app the module had deliberately and correctly released. An
absent target is now skipped in both `revert_verdict` and `drift_list`.

---

## What was deliberately *not* rewritten

- **The engine, in shell.** Its work *is* shell work: `pm`, `settings`, `cmd`,
  and sysfs writes. The cost is the binder round trip, not the interpreter.
  Rewriting it in C++ would buy nothing measurable and would throw away the
  thing that makes a root module auditable.
- **The parallel fans.** Already bounded (3 apply / 6 revert) and already the
  right shape.
- **The journal format.** Slower to parse than a binary blob, and worth it: it
  is the recovery contract, and a human can read it when a phone is misbehaving.

---

## Test-harness bug worth recording

Four "new" suite failures (cases 40, 41) were **not** a product regression — all
four passed in isolation, under both new and stashed code. `stop_daemons` killed
only processes matching `daemon.sh`, but the daemon runs its screen transitions
**detached**; those `engine.sh` children outlived it and wrote into the tree the
next case was about to build.

Worth stating plainly: *do not assume a suite failure is a product regression.*
Re-run the case standalone and `git stash` to compare before editing product
code.

---

## The screen-off stall: three seconds of nothing

`apply_deep_doze` polled up to six times, half a second apart, waiting to see
`mForceIdle=true` — and the **entire product of that loop was one log line**.
The journal entry, the status note and `note_deep_doze`'s own reading are all
derived later from the phone itself; nothing downstream ever depended on it
having finished.

What it *did* depend on was the user's time. `deep_doze` is the first thing
applied when the screen goes off and the rest of the idle sequence queues behind
it, so on any phone that does not report the flag — most of them; the note text
*"this phone does not report its idle state"* exists for exactly that case —
**every single screen-off paid a flat three seconds** before any other saving
was applied.

| | before | after |
|---|---|---|
| screen-off (deep phase on) | 3298 ms | 630 ms |

The confirmation now runs detached. The log line survives for phones that
answer; the three seconds go back to every phone that does not.

## Epoch without a fork — and the test that nearly broke

`date +%s` was **112 execs in a single activation**: every duration, timeout and
age check in the engine. `now_epoch()` uses the `printf %(%s)T` builtin (mksh on
Android, bash) — 300 calls, **540 ms → 117 ms**.

With one deliberate exception, and it is the interesting part. The suite injects
a **fake clock** by putting a `date` stub on `PATH`, so an hourly drain rate can
be asserted without the test sleeping for an hour. A builtin reads the kernel
directly and would sail straight past it — the module would keep working while
every time-travel test quietly measured real time instead.

So `now_epoch` uses the builtin only when no such stub is present: a phone gets
the saving, the suite keeps its injected clock. *A faster implementation that
defeats the tests proving it correct is not a good trade.*

## mkdir that did nothing, 200 times

`mkdir -p` on an existing tree is a no-op that still pays for a process. The
line at the top of `lib.sh` runs on **every sourcing**, and the engine sources it
from every subshell it fans out; `suspend_app`/`unsuspend_app` ran one per
package. All now test first.

Verified by wrapping `mkdir` and counting: an activation went from ~200 calls to
**1**. The 101 remaining `mkdir` calls are the lock primitive itself — a
mkdir-based mutex, which is correct and not removable.

| | before | after |
|---|---|---|
| daemon idle 10 s, asleep | 134 forks | 25 forks |

## A poke that bash would have swallowed

The APK signals the daemon with `SIGUSR1` when it hears `SCREEN_ON`/
`SCREEN_OFF`, so the transition is instant instead of a poll away. Once the
daemon started waiting on the monitor's pipe instead of on `sleep`, that stopped
being reliable — and the failure is shell-dependent, which is the worst kind:

| shell | USR1 while blocked in `read` on a fifo |
|---|---|
| dash | read returns, trap runs |
| bash | **read restarts; the handler never runs** |

So on a bash-like `sh` the app's instant path would have silently degraded to
whatever the backstop happened to be. The fix does not fight the signal
semantics: the daemon publishes the monitor's pid, the app pokes **the monitor**
as well, and the monitor answers by writing a line. The *pipe* delivers the
poke, not the signal — and a pipe wakes a blocked reader on every shell there
is.

This also required the monitor to emit a `tick` for a poke that finds the panel
unchanged (the broadcast routinely beats the backlight write by a few
milliseconds). Staying silent there would have swallowed the very poke that was
sent to make the transition instant.

## A lost-update race that had been hiding behind "flaky"

One test failed intermittently — "the device still comes back byte for byte",
always a radio, roughly one run in three. It would have been easy to write off
as harness noise, especially having already found real contamination in
`stop_daemons`.

It was not noise. Wi-Fi, Bluetooth and NFC are all `session` knobs, so they
revert **together in the same bounded parallel fan** — three processes doing a
read-modify-write on one small file. `radio_forget` did it through a **shared**
temp path:

```sh
grep -v "^$1	" "$RADIO_STATE" > "$RADIO_STATE.tmp"
mv -f "$RADIO_STATE.tmp" "$RADIO_STATE"
```

Three of those interleaved clobber both the file and each other's temp. The
observed result was the record coming back **empty**: a radio's remembered state
vanished before its own restore had read it, so *the radio was never switched
back on*. On a phone that is a user whose Wi-Fi stayed off after leaving the
mode.

Reproduced in isolation, the old code lost an update in **40 of 40** trials; the
fix (private `$$` temp + a `mkdir` lock over the whole read-modify-write) loses
**0 of 40**. `tests/run-codec.sh` now pins it, and that test fails 14/15 against
the old implementation.

The lesson is the inverse of the `stop_daemons` one, and worth holding both at
once: *an intermittent failure is not evidence of a flaky test.* Reproduce the
mechanism before deciding which it is.

## Results

| | before | after |
|---|---|---|
| idle forks (10 s) | 30,827 | 20 |
| daemon CPU, 20 s idle | 4 ticks | 1 tick |
| minor faults, 20 s idle | 740 | 460 |
| monitor CPU while blocked | — | 0 ticks |
| monitor RSS | — | ~880 kB |
| screen-off reaction | ~250 ms (poll) | ~250 ms, event-driven |
| timer wakeups/day (announcing kernel) | ~86,400 | ~2,880 |
| `status` execs | 180 | dominant three eliminated |
| screen-off latency | 3298 ms | 630 ms |
| daemon idle 10 s asleep | 134 forks | 25 forks |
| `log` 300 lines | 543 ms | 309 ms |
| `date +%s` 300 calls | 540 ms | 117 ms |
| suite | 572 checks (aborted early) | 649, 0 fail |

Whole-benchmark comparison (`tests/bench/run.sh --cmp baseline final`), forks
counted inside the measured tree, not from `/proc/stat`:

| | baseline | final | change |
|---|---|---|---|
| activate | 2963 f / 2298 ms | 2620 f / 1836 ms | -12% f / **-20% ms** |
| deactivate | 3011 f / 1874 ms | 2023 f / 1068 ms | -33% f / **-43% ms** |
| screen-off | 1189 f / 3405 ms | 1031 f / 592 ms | -13% f / **-83% ms** |
| screen-on | 552 f / 366 ms | 459 f / 243 ms | -17% f / **-34% ms** |
| status | 414 f / 282 ms | 287 f / 165 ms | -31% f / **-41% ms** |
| verify | 135 f / 101 ms | 100 f / 81 ms | -26% f / -20% ms |
| daemon idle 10 s, on | 30,827 f | 166 f | **-99%** |
| daemon idle 10 s, off | 23,003 f | 25 f | **-100%** |
| **total** | **62,559 f / 28,630 ms** | **7,043 f / 24,171 ms** | **-89% f / -16% ms** |

Every operation improved on both axes; nothing regressed.

Suites: `tests/run.sh`, `tests/run-install.sh`, `tests/run-codec.sh`,
`tests/run-daemon.sh` — all wired into `ci/build.yml`.
