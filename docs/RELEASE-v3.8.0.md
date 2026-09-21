# Axion SPSM v3.8.0 (versionCode 71)

**The architecture round: measured where the phone's time went, then took it out. No feature changed.**

## The method

Not a rewrite, and not "convert it to C++". The workload is mostly waiting on
Binder round-trips to `system_server` — the language of the waiter barely
matters; the *number* of round-trips and forks is everything. So the harness's
own instrument did the analysis: the test stub records every command the phone
receives. One activate+exit cycle with 40 blocked packages cost **449 phone
calls**, and the daemon forked `sleep` once a second for as long as it lived.

## What changed — three mechanisms

**1. Package work, batched.** `pm` accepts a whole list of packages in one
call. Blocking, releasing, recovery and the sweep now ask for **forty apps
per call**, with the proven per-app path as an automatic fallback if a phone
refuses a batch. Measured on the 40-package cycle:

| phone calls | v3.7.12 | v3.8.0 |
|---|---|---|
| pm suspend | 43 forks | **2 calls** |
| pm unsuspend | 43 forks | **2 calls** |
| make-uid-idle | 43 (told twice) | 43 (told once) |
| **total** | **449** | **367** |

On the real ~190-app phone: roughly **370 fewer forks per session cycle** —
minutes of min-frequency-core CPU returned to the phone.

**2. The forkless nap.** The daemon's `sleep` forked a process every tick —
one per second while the phone is in use, **~86,400 forks a day**. The nap is
now a read with a timeout on a pipe the daemon holds open at both ends: zero
forks, identically interruptible (the app's poke breaks the read exactly as
it killed the sleep), with the old behaviour kept as a fallback if the pipe
cannot be made.

**3. The sweep stopped repeating itself.** The block apply already hands every
app to ActivityManager as idle; the sweep's full pass re-told the identical
set seconds later — one fork per app for a fact already told. The memory
reclaim (force-stop) stays; the repeat is gone.

## What did NOT change

Every option, default, scope and tag; the six slots and their immediacy; the
recovery command `su -c sh /data/adb/spsm/scripts/engine.sh six-restore`; the
journal and its restore guarantee; the boot heal; the launcher, plumbing and
overlay protections; the caps-last/caps-first order; the tile and the app.
The harness proves the equivalence: **637 checks, 0 failed**, twice
consecutively — including the new case that replays a 40-package block and
counts the forks (≤4 where 43 stood), exercises the per-app fallback on a
phone that refuses batches, and pins the forkless nap with its fallback.

## Why not C++

A native binary would have made each *remaining* call marginally cheaper
while the phone still pays for the call itself. The wins here were in call
count and fork count — architecture, not language — and shell keeps the
journal/restore semantics that six months of device logs have already
survived. The right tool for this round was fewer questions, not a faster
asker.

## Install

Mode off → flash `Axion-SPSM-v3.8.0-RMX3430.zip` → reboot.

## Harness

637 checks, 0 failed — twice consecutively.
