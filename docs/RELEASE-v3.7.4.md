# Axion SPSM v3.7.4 (versionCode 62)

**Your icons, back by name — and the two bugs you caught, fixed at the source.**

## Your icons are back

You were right: last round's redraw threw away icons you liked. Both are
restored, with only the changes you asked for:

- **App icon** — the previous icon, untouched, with **the whole background
  black** (not white, and no square behind it). The yellow battery is exactly
  the art you chose; only the background colour changed.
- **Quick Settings tile** — the previous battery with the S, **stretched
  wider**: it now spans the full width of the tile. One honest note: the old
  shape stopped a hair short of the canvas edge, so a true +10% would have
  pushed the battery's terminal off the tile and clipped it. It is stretched
  to everything the tile can draw — about +9%, edge to edge.

While the mode is on, the system still paints the tile in its own active
colour, the same way Wi-Fi and Bluetooth colour — that part is the system's
own tinting and it was already correct.

## The six-slot swap bug (you caught it exactly right)

Taking an app out of the six slots only re-blocked it **when the screen was
off** — so swapping an app while you were using the phone left the removed
app fully usable next to the one you added. The re-block now runs the moment
the slot changes, screen on or off, same as every other change this mode
makes. The removed and the added app can never both be usable again.

## The "something crashed" message — root-caused in Android's own code

Your crash log said it precisely: `IllegalArgumentException: Package root
does not exist!` inside `android:ui`, from
`UsageStatsService.reportUserInteraction` via Android's own
`SuspendedAppActivity`. Verified against AOSP source:

- When any app is suspended, Android records **who** suspended it.
- We suspended as **root** — so the record said a package called `root`.
- Every button on the system's "app suspended" dialog ends with reporting the
  interaction for that name, and `root` is not a package — system_server
  died on the spot. That was the crash Logfox showed you as `Android:ui`,
  every time you tapped through the grey app's dialog.

**The fix:** suspensions now run as the **shell** identity (`com.android.shell`,
which Android itself grants the `SUSPEND_APPS` permission). The suspender on
record becomes a real package, the dialog has something real to point at, and
the crash is gone at the source. Same suspensions, same speed, same revert.

## Also in this build

- Verified no other suspension path writes the broken root record: the app
  blocker and the Google-freeze knob both go through the new suspend path.

## Install

Same as every build: flash `Axion-SPSM-v3.7.4-RMX3430.zip` in ResukiSU, or
install from storage. Reverting stays guaranteed, knob by knob.

## Harness

543 checks, 0 failed.
