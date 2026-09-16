## Axion Super Power Saving v3.4.1 (versionCode 49)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

v3.4.0 was withdrawn because it closed itself the moment it was opened. This fixes that, and makes the same mistake impossible to ship again.

### The crash, and why it happened

The report from the phone was exact:

```
Unable to resume activity {dev.axion.spsm/dev.axion.spsm.SetupActivity}
  ← java.lang.ClassCastException: android.widget.FrameLayout cannot be cast to
    android.widget.LinearLayout   at SetupActivity.bindSlots(SetupActivity.java:79)
```

The six app containers on the home and setup screens were rewritten for v3.4.0 so a container could carry the small badge that edit mode uses. That needs a `FrameLayout` as the container's root. Two screens — the setup screen and the home screen — went on asking for those containers as `LinearLayout`, and Android refuses that cast at the moment the screen is resumed. Nothing could catch it earlier: it compiles cleanly, and every test of this project is a test of the *scripts*, which never inflate a layout.

**Fixed:** the screens ask for the plain `View` (which is all they use — a tap, a long press, a lookup of the children) and so does the helper that binds a slot. The container's type is now the layout's business, not the code's.

### So that it cannot happen again

Three checks now stand between this class of bug and a release, and all three run in the build:

1. **`tests/audit-ids.py`** walks every `findViewById` in the app — including the `findViewById(slotIds[i])` form that crashed, and casts like `(ImageButton) editButton` — works out the type each one is held in, reads the type each layout actually declares, and fails on a mismatch with the file, the line and the two types. It understands Android's widget hierarchy, so a `TextView` may be held as a `Button` but never the other way round.
2. **`tools/dexcheck.py`** reads the *built APK's* dex and demands the fixed method signature is in it and the one that crashed is not. The source being right is not the same as the APK being right, and the APK is what gets flashed.
3. **A test case** replays the shipped crash: it puts the old cast back into a copy of the app tree and fails the suite if the audit does not catch it. A net that has never caught anything is a net of unknown size.

Two screens can also no longer be taken down by a view problem at all: the setup screen's slot row and the recents list are wrapped, so a fault there costs the icons, not the app.

### Faster exit

The v3.3.1 log showed the power-mode release taking one second and the whole exit taking forty-five. The cost was the app list: every third-party app was suspended (and on exit released) one at a time, three shell commands each. Those loops now run together and only the results are written down, in the same order as before. The journal — what was changed, and by whom — is built exactly as it was, so restore semantics are unchanged. The log also names any step that takes more than two seconds from now on, so the next slow exit can be pointed at instead of guessed at.

### Everything from v3.4.0, unchanged

The redesigned home screen (large centred clock and date kept, yellow pill gone, 3×2 grid, thin `+`/Add, edit pencil and tick, badges, hold-to-change, bottom exit sheet with grey Cancel and red Exit), recents that really close an app (verified against the task list, with a stop-app fallback), the launcher's own recents screen switched off while the mode is on, and all 29 options with their previous defaults.

### Not changed

No option's default was touched. Nothing about what the mode does to the phone changed — only whether the app opens, how long an exit takes, and how the build checks itself.

### Also fixed

The release build could fail on its last step at random: a JVM tool's output was piped into `head`, and closing that pipe early aborted the build under `pipefail`. It reads the APK's details into a file first now.

### Files

`release/Axion-SPSM-v3.4.1-RMX3430.zip` — APK v3.4.1 (49), 29 options, suite 69 cases / 419 checks green, install test 22/0.
