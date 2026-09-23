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

So the gauge itself can only say 31.00 or 32.00. The hundredths between its
anchors come from integrating the live current (a coulomb count at 1 500 ms,
EMA 0.7/0.3 to smooth the sample noise), and at every gauge step the estimate
blends onto the new anchor over ~20 s. After a screen-off gap the integral
cannot reconstruct, the gauge re-anchors outright. The display therefore agrees
with the system percentage at every whole number and glides between them at the
true pace of use (`I / 60 000` = %/h exactly, shown alongside).

## Zero cost, by construction

No wake locks. No alarms. No timers. The tick loop is a plain Handler that runs
only while `PowerManager.isInteractive()` - the CPU is awake anyway - and the
SCREEN_OFF broadcast removes even that; the service executes nothing until the
screen returns. Verified on the device after install: 0 wake locks, 0 alarms
held by the app.

## Where the control lives

Setup screen -> **Precision battery: on/off** (default on, restored at boot by
`BootReceiver`).
