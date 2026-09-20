# Axion SPSM v3.7.10 (versionCode 68)

**The second bug hunt: the recovery command, the boot heal, and the app's words.**

The first hunt (v3.7.9) opened the engine's sweep, the widening paths and the
icon. This round opens the surfaces that round did not touch: the recovery
command every document points at, the boot that heals a dead session, and the
app you actually hold.

## The recovery command dragged — minutes, in the worst moment

`su -c sh /data/adb/spsm/scripts/engine.sh six-restore` — the command in
every "if something looks wrong" section — unsuspended the record **one
package at a time**. On this phone the record held **264 packages**: minutes
of sequential `pm` calls at the exact moment the phone is already misbehaving.
The boot heal in `service.sh` (which runs the same command when a dead session
left apps suspended) sat on the same slow queue.

It now unsuspends **six packages at a time**, the same bounded shape every
other per-package loop uses — the record that took minutes now takes seconds.

## Recovery could fight a running mode

It also took no lock and asked no questions:

- Run **while a screen-off transition was mid-flight**, it mutated the same
  suspensions the transition was writing — the journal and the phone quietly
  disagreed afterwards.
- Run **while the mode was on**, it freed the mode's blocked apps without a
  word; the mode's next transition then re-applied its choices, and the
  person was left wondering what happened.

Now: it runs **under the lock** (a transition in flight is waited for, up to
twenty seconds; if the lock still cannot be had, recovery says `busy` instead
of lying), and **when the mode is on it says so in the log** — "its next
transition will re-apply its choices; switch the mode off to keep them
freed". Recovery always works; now it also tells the truth.

## The options screen spoke in code

Toggling an option toasted its internal id — `wifi_off enabled`. It now
toasts the option's own name from the same list the scripts publish:
**"Wi-Fi off enabled"**. One of those small things that decides whether a
screen feels finished.

## Also checked this round, and clean

The Quick Settings tile (detached transitions, honest busy state, watchdog on
every read), the screen-state publisher (event-driven, no polling, instant
wake), the boot receiver (guarded, cannot break a boot), and the root command
layer (bounded waits everywhere) — all audited; no defects found.

## Install

Mode off → flash `Axion-SPSM-v3.7.10-RMX3430.zip` → reboot.

## Recovery (unchanged command, now fast)

```
su -c sh /data/adb/spsm/scripts/engine.sh six-restore
```

## Harness

600 checks, 0 failed — including the new recovery case: bounded, under the
lock, answers with what it freed, honest while the mode is on, and the exit
after a recovery leaves the phone clean.
