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

## The device, researched (what the kernel really exposes)

| signal | truth | use |
|---|---|---|
| `fuelgauged` kernel log: `ui_soc:4094` | **40.94 % in 0.01% units** - the very value the system integer is cut from (system 41 = round(40.94)) | THE anchor |
| `Q:[49799 ...]` / `charge_full` | 4 979 000 uAh learned capacity (aging: 10000 = 100.00%, 65 cycles) | the scale: 49 790 uAh per 1 % |
| `charge_full_design` | 6 000 000 uAh | nothing - the old 60 000 uAh/% scale came from here and was **20% wrong** |
| `current_now` | signed, live (+ charging, - discharging) | the motion of the decimals |
| `charge_counter` | `level x 60 000` exactly, 1% quanta | nothing - presentation only |
| `charge_now` | frozen (8931, then 37) | nothing |
| gauge print cadence | ~2 lines / 45 s | anchor poll every 12 s is enough |

## The model (after the owner's two corrections)

1. *"42.xx against a system 43 means the battery is lower than 43"* - a fine
   reading that disagrees with the rounded integer is information. The whole
   number is never locked to the integer.
2. *"The xx must follow my usage at a constant rate, or it is a showpiece"* -
   the decimals are current integration on the learned scale: `uA * s / 3600 /
   49 790` per tick. Constant current = constant slope, load and charger move
   it instantly.

So: `ui_soc` anchors, integration carries the number between gauge prints, a
fresh anchor blends in at 0.02%/tick (a bad read cannot jump the display), and
the detail line predicts the next whole percent from the real slope: `-266 mA
(-5.3%/h) - 40 in 10 min`. Two bugs died on the way, both caught live: the
20%-wrong scale above, and a "not anchored" sentinel that its own safety clamp
turned into 0.00, after which the anchor dragged the display *upward* for an
hour while the battery discharged.

## Zero cost, by construction

No wake locks. No alarms. No timers. The tick loop is a plain Handler that runs
only while `PowerManager.isInteractive()` - the CPU is awake anyway - and the
SCREEN_OFF broadcast removes even that; the service executes nothing until the
screen returns. Verified on the device after install: 0 wake locks, 0 alarms
held by the app.

## Where the control lives

Setup screen -> **Precision battery: on/off** (default on, restored at boot by
`BootReceiver`).
