# Axion Super Power Saving v3.6.3 (versionCode 55)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

v3.6.2's device test found the Recents button still dead — the watcher ran,
said it was watching, and the press still did nothing — and the new frame-rate
cap still left the panel at 60 Hz. This release fixes the first at its real
cause and makes the second refuse honestly where it cannot win.

### The tap that never arrived

> "I installed v3.6.2 but again pressening recent button from 3-button
> navigation bar didn't open spsm's recents and just didn't do anything."

The v3.6.2 device log showed the tap watcher alive the whole session — it
logged the region, it stayed running — and not one handover. The stream was
being read; nothing came out of it. The cause, proved in the sandbox this
round:

**awk buffers its input.** An awk reading a pipe does not handle lines as they
arrive; it waits until it has a full block — or until the stream *ends*.
Demonstrated with the module's exact tap state machine: fed 344 bytes of tap
events through a pipe that stays open, the awk sits on them for the full
thirty seconds the fake touchscreen holds the stream, and fires only at
end-of-file. Fed ~137 KB, the same awk fires in two seconds. A phone's event
stream never ends and a tap is a few hundred bytes — **the tap would have sat
in that buffer effectively forever.** v3.6.1's fix (the animation watcher) and
v3.6.2's watcher were both correct in what they looked for; this was the layer
underneath, silently holding everything they saw.

The tests never caught it: the fake `getevent`'s stream ends, and
end-of-file flushes the buffer. A hold-the-stream-open test (added in v3.6.2)
caught the *shape* of the bug but the suite's awk still only fired at EOF —
inside the thirty-second hold, where a phone never gets one.

**The fix removes awk from the stream path entirely.** The tap state machine
now runs in plain POSIX shell, reading the stream one line at a time —
`read` on a pipe asks for a line and takes whatever has arrived, so no
implementation can wait for a full block. The hex-to-decimal conversion and
the tap-timing arithmetic are plain integer shell (microseconds, no floating
point, no overflow at any uptime). The rules are unchanged from v3.6.2:

* the press must start **inside the Recents button's region** (in touchscreen
  units, read from the phone, as before);
* the finger must stay **almost still** (no 40-unit drag on either axis);
* the press-to-release time must be **under 0.8 s**;
* a `TRACKING_ID` release counts exactly like a `BTN_TOUCH` release.

On release the handover is the same command the terminal uses:
`engine.sh recents-button tap` — the list is put up, the screen read back,
and the attempt retried, exactly as v3.6.2's design intended. The log line
says so: `recents: the list was put up for the Recents button command (tap)`.

The same suite run that proves this also proved how the old bug hid: with the
shell reader, the tap is handed over **while the fake stream is still held
open** — the test now asserts the handover with nothing to flush it.

### The frame rate: honest by panel, not hopeful by default

v3.6.2's cap asked the ROM's Game Mode overlay (`device_config game_overlay`)
to hold 30 Hz. On the device that setting was unreadable — the module said so
and put nothing in its place — and the mechanism was the wrong one anyway: it
caps **games only**, so the home screen and normal apps were never going to
follow it.

v3.6.3 goes at the panel itself, but only where the panel proves it can:

* The panel's own modes are read from `dumpsys display`. If a 30 Hz mode is
  offered (60/30 panels), the mode writes
  `@system:peak_refresh_rate` and `@system:min_refresh_rate` to **30.0**
  while this mode is on, and both are restored on exit — same
  snapshot/restore/verify discipline as every other knob, drift-checked.
* On a 60-only panel, the Game Mode overlay survives as a **fallback leg only**
  (it can still cap what games run at), and the log names it as that — not as
  a screen-wide cap.
* A phone that offers neither, or will not say, gets an honest refusal:
  the option turns on, the note says what was tried and why it was left alone,
  and nothing is written that the phone would have to undo.

A 40 fps cap stays impossible: the frame rate a panel shows must divide its
refresh rate, and 40 does not divide 60. 30 does, and 30 is what the option
now asks for — on panels that have it.

### The rest of this round

* The died-at-once probe (v3.6.2) now also covers the rewritten tap watcher:
  a `getevent` that cannot read the touchscreen is named in the log within
  seconds instead of leaving a silent "watching" line behind.
* The exit-time honesty of v3.6.2 is untouched: same stopwatches, same
  "revert clean in Ns" line, and the same per-knob notes when the phone takes
  a setting back.

### Proven before shipping

The full harness — the real engine scripts against a fake device tree —
passes **594 checks, 0 failed**, including the new ones written from this
round's findings: a tap handed over with the stream still open (the exact
v3.6.2 failure), a tap *not* handed over outside the region, the watcher
death reported, and the frame-rate option refusing, capping, and restoring
per panel type.

### What this release asks of the phone

Two one-line captures, if the button still does not answer after install:

* ten seconds of `su -c 'getevent -lt'` while tapping the Recents button —
  to see the events exactly as the watcher receives them;
* the head of `su -c 'dumpsys display'` — to confirm the panel's mode list
  for the frame-rate leg.
