# The precision battery readout (v3.8.3)

The owner's request: *the device shows the percentage in precision format like
31.63 or 44.00, moving smoothly with how aggressive I use the phone and with
charging speed, calibrated to my current device, and it must not cost battery.*

First preference was the number **inside** the system battery icon. That is
SystemUI: Android does not let any app draw over the status bar, and SystemUI is
signature-locked to the ROM key, so no app can replace that glyph. The app-level
answer is the persistent notification - and its **status-bar icon is the number
itself** (white-alpha text bitmap, tinted by the system like any bar glyph, wide
bitmaps render wide; the network-speed-indicator trick). The shade holds the
detail: `43.05% · -373 mA (-6.2%/h)`. The SystemUI route stays open as a patch to
the AxionAOSP tree for a future build.

## The calibration, measured on this phone first

| reading | value |
|---|---|
| `charge_counter` | **exactly `level x 60 000` uAh** (2 460 000 at level 41, 2 580 000 at 43) |
| step size | 1 % - the counter only moves at whole percents |
| `CHARGE_FULL` | 4 974 000 uAh (learned) |
| `CHARGE_FULL_DESIGN` | 6 000 000 uAh |
| `current_now` | signed: **+ charging, - discharging** (+1 326 000 / -249 000..-429 000 observed) |

So the gauge itself can only say 31.00 or 32.00. The model, after the owner's
first-hour correction: *the readout refines the system percentage, it never
argues with it.* The whole number is always the gauge's own level; the hundredths
are the position inside that one-percent bucket, walked by the integrated
current (1 500 ms ticks, EMA 0.7/0.3, one bucket = 60 000 uAh). At every gauge
step the number re-seats on the new whole percent - the visible snap is the
gauge's own tick, never more than the bucket width differs from 60 000 uAh - and
a plug/unplug turns the smoothed current over instantly. `42.xx` against a
system 43 is structurally impossible: the fraction is capped at 0.995 so
two-decimal rounding cannot leak into the next whole either. `I / 60 000` =
%/h exactly, shown alongside.

The first build kept an independent coulomb count anchored at service start and
only softly blended at steps (a 0.08 blend, one-shot - the rest of the error
stayed forever). It drifted under real use and the owner caught it at 42.xx vs
43. The bucket model cannot reproduce that failure.

## Zero cost, by construction

No wake locks. No alarms. No timers. The tick loop is a plain Handler that runs
only while `PowerManager.isInteractive()` - the CPU is awake anyway - and the
SCREEN_OFF broadcast removes even that; the service executes nothing until the
screen returns. Verified on the device after install: 0 wake locks, 0 alarms
held by the app.

## Where the control lives

Setup screen -> **Precision battery: on/off** (default on, restored at boot by
`BootReceiver`).
