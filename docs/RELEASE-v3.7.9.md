# Axion SPSM v3.7.9 (versionCode 67)

**The bug hunt: the sweep treadmill, the overlays, and an option list that reads like your phone's own.**

## The bug hunt — three finds, from your own v3.7.7 log

**1. The memory sweep was running in circles.** Your log shows
`background sweep: 264 frozen app(s) stopped` three times — once when the
mode started, again at every screen-off, again on Clear All. But a suspended
app cannot start, so it cannot take memory back: re-stopping the same 264
apps every time only kept your phone busy for 15 seconds a sweep, with the
load spike riding along. Now the full pass runs **once per session**; every
sweep after it reaps the strays and reports the memory — which is all the
phone actually needs.

**2. An overlay was in your block list.** Your log's list starts
`android  android.axion_auto_generated_rro_product__  android.ext.services…`.
That second name is an RRO — a runtime resource overlay: a package that is
*only* resources, with no code to stop, and one that apps use for their
theming. The system-app widening had suspended it because its name appeared
in `pm list packages -s`. Overlays are now skipped by name in both widening
paths (blocking and background limits) — they can never be touched again.

**3. The exit log overstated its subject.** It said "released the six-slot
record" while releasing **every** app the mode had suspended — 264 of them,
slots or not. It now says "released every suspended app", and the sweep's
light pass logs exactly what it did instead of implying it did nothing.

## The option list, rewritten like an OEM's power-saving mode

You asked for every option's title and detail to read formally and plainly,
the way a phone maker's own premium power-saving mode reads. All 31 are
rewritten — same behaviour, same defaults, same positions; only the words
changed:

| was | now |
|---|---|
| Power-save governor, always | Processor power-save |
| Graphics at minimum, always | Graphics at minimum |
| Sleep cores 2 to 7 after a minute | Sleep six cores after a minute |
| Hand back background memory | Free background memory |
| 15-second screen timeout | Shorter screen timeout |
| Turn off Wi-Fi / Bluetooth / NFC / location | Wi-Fi off / Bluetooth off / NFC off / Location off |
| Stop background scanning | Background scanning off |
| Restrict the ROM's background work | Restrict the ROM's background services |
| Cap the frame rate (30 fps) | Frame rate capped at 30 fps |
| …and 22 more, same voice throughout | |

Each option is still one switch with one short, honest sentence — including
the two promises you set in writing: the processor line still says no
frequency limit is ever written by hand, and the system-app line still says
Android's own essentials are never touched.

## The icon, fixed

The battery filled the whole tile — 67% of the adaptive canvas, past the
66% safe zone launchers are drawn around — so it looked like a battery with
no icon around it. It is redrawn at 53% of the canvas on the same pure
black, and the legacy black square got proper margins too. Same art, same
colours; now it sits in the tile the way an icon should.

## Install

Mode off → flash `Axion-SPSM-v3.7.9-RMX3430.zip` → reboot.

## Recovery (unchanged)

```
su -c sh /data/adb/spsm/scripts/engine.sh six-restore
```

## Harness

594 checks, 0 failed — including the light-sweep pins (the second sweep must
not re-stop one app, and a new session must sweep fully again), the overlay
case, and the renamed options pinned with their promises word for word.
