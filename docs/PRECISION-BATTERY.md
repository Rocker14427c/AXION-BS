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

## The device, researched (corrected after live diagnostics)

| signal | truth | use |
|---|---|---|
| `{FGADC}... ui_soc:3141` | 31.41% in 0.01 units - the value the system integer is rounded from | THE anchor (filter to FGADC lines only!) |
| `[GM3_boot_data]... ui_soc:3839` | a STALE boot record interleaved in the same log | NEVER - it flickered the anchor between 31 and 38 |
| `charge_counter` | `level x 60000` uAh exactly | the % scale is the DESIGN scale: 60000 uAh per 1.00% |
| `Q:[49899 ...]` | learned/aging capacity (~4990 mAh) | an aging report, NOT the percent scale - using it made every rate 20% wrong |
| `CAR[c:NNNN ...]` | hardware coulomb counter, 50 uAh/LSB, dumped in ~60 s batches | ground truth energy (diagnostic reference) |
| `current_now` | signed live uA | the motion of the decimals |
| `charge_now` | frozen | nothing |

## The model (seven 11-minute live diagnostics later)

Hard-won rules, each learned from a failure the diagnostics caught:

1. The integrator owns the motion: `uA * s / 3600 / 60000` per tick. Constant
   rate per current; load and charger move it instantly (sign flip on plug).
2. Tick stalls never lose energy: the stall gap is integrated at the last known
   current (up to 2 min); longer gaps are screen-off dormancy by design.
3. The gauge corrects drift ONLY outside a +-0.10 deadzone, at 0.03 per 12 s
   catch - invisible in the motion. Full-strength pulls produced the
   39.93/39.94 loop; per-print positional snaps produced visible jitter; a
   feedback integrator windup produced a 0.9% plunge; a 0.8% snap produced a
   0.84% jump. All four are rejected by evidence, not taste.
4. Gross desync (reboot, hours off) glides back at 0.03/tick - never jumps.
5. Repeated gauge prints are deduplicated on the VALUE, never on the log line.

Acceptance protocol (owner-mandated): 10+ minutes of continuous 5 s samples of
the displayed value, ui_soc, current, and level; verdict on slope ratio vs
current physics (0.65-1.35), reversals (0), sawtooth loops (0), max step
(<0.05), gap to gauge (mean <0.25), and flat spells (<90 s while awake).
Active-window slope ratio measured: 0.94. Zero wake locks and alarms throughout.

## Zero cost, by construction

No wake locks. No alarms. No timers. The tick loop is a plain Handler that runs
only while `PowerManager.isInteractive()` - the CPU is awake anyway - and the
SCREEN_OFF broadcast removes even that; the service executes nothing until the
screen returns. Verified on the device after install: 0 wake locks, 0 alarms
held by the app.

## Where the control lives

Setup screen -> **Precision battery: on/off** (default on, restored at boot by
`BootReceiver`).
