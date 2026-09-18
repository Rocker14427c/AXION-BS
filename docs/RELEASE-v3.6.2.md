## Axion Super Power Saving v3.6.2 (versionCode 54)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

v3.6.1's device test found one thing broken and two things dishonest. This round
fixes all three, and answers the frame-rate question with what the phone can
actually do.

### The Recents button, properly this time

> "Installed v3.6.1, both back button work, home button properly take to spsm's
> home, but only problem is recent button didn't do anything, i click it but it
> didn't open spsm's recents, so can you please fix it properly."

The v3.6.1 guard watched for the launcher's recents **activity**
(`com.android.launcher3/com.android.quickstep.RecentsActivity`). Nine hours of
the device log contain that activity exactly **zero** times, and this line exactly
once:

```
I/input_focus( 1910): [Focus entering recents_animation_input_consumer, reason=setFocusedWindow]
```

That is the answer. This ROM's launcher does not start an activity for Recents at
all — Quickstep handles the press inside itself as a *recents animation*, and the
screen that slides up is drawn by the launcher process, never by an activity the
guard could match. So the handover was never triggered: the guard was watching a
door nobody uses.

Four changes, all in the tree:

* **The guard matches the animation line**, and the activity it used to match is
  still matched (in case a phone takes the other path).
* **A second watcher reads the touchscreen itself.** The daemon now also runs
  `getevent` and watches for a tap in the Recents area of the navigation bar
  (720×1600 at 280 dpi: `540 1516 720 1600`). The area is read from the phone's
  own `dumpsys window` navigation-bar insets and density rather than hard-coded,
  and it is expressed in **the touchscreen's own units**: `getevent -p` says what
  range each axis uses, so a driver that counts in its own raw range (0..4095 is a
  common one) gets the region in those numbers instead. A region named in screen
  pixels on such a phone would point at a place the finger never reaches - which
  looks exactly like the bug being fixed. A tap there calls the same handover, and
  if this phone has no `getevent`, the log now says so instead of staying silent.
* **The handover is asked for, then checked.** `am start` is run, the screen is
  read back, and the list is asked for again if the launcher's screen came up
  instead — up to three tries, and a press that fails writes what `am start`
  answered into `spsm.log`. Refusals are never reported as successes.
* **The daemon no longer acts on the past.** `logcat` replays its whole buffer
  before it starts following; the daemon now follows from `-T <now>`, so the
  pre-mode line in the buffer that v3.6.1 acted on at startup cannot be seen at
  all.

Three commands to prove it from a terminal (while the mode is on, from inside an
app):

```
su -c 'sh /data/adb/spsm/scripts/engine.sh recents-button'   # hand over as if pressed
su -c 'sh /data/adb/spsm/scripts/engine.sh recents-area'     # what region is watched, and why
su -c 'sh /data/adb/spsm/scripts/engine.sh recents-watch'    # watch the button for 20s: press it now
```

### The exit time was a lie

> "Check the spsm log for bug or fixes and try makint the exiting faster if you can"

The log said "revert clean in **4 s**" for an exit that took **97 s** of wall
clock. The stopwatch variable was shared: the phase loops kept restarting the
same `_t0` that `do_deactivate` started, so the number printed was the length of
the *last* knob's revert and not the exit. There are now three stopwatches
(`_exit_t0`, `_on_t0`, `_kt0`) and the summary line reports the real one. The
slowness that was real — `rom_bg_off` at 264 s — went in v3.6.1 and is 14–17 s on
this phone now.

### The rest of the log sweep

* **`note_rom_bg_off: inaccessible or not found`.** `[ "$(type fn)" ]` is truthy
  for a *missing* function in Android's `sh`, which prints that message on stdout.
  Every "does this function exist" test is now `has_function`, and the notes the
  log prints are the notes the phone actually answered.
* **`app_restrict` at 69 s on the second deep pass.** Each package was tested
  against the whitelists with its own process. The lists are one string now, and a
  package the journal already knows about is skipped with a note that says so
  (`rom_bg_off` and `managed_packages` got the same treatment).
* **The suspend state is read once** from `/data/system/users/*/package-restrictions.xml`
  instead of per package.

### 60 fps → 40 fps: 40 is not on the menu, 30 is

> "My device produce 60fps all the time, is it possible to reduce that 60fps to
> 40fps because it will reduce some cpu/gpu load and 40fps is smooth too."

A frame rate that the panel cannot show is not a frame rate. This is a 60 Hz
panel, and the platform's own frame-rate throttling (Game Mode's FPS override,
A13+) only accepts values that **divide the display refresh** — Google's own
table for a 60 Hz display lists **60 FPS and 30 FPS**, not 40. Ask for 40 and the
system either rounds it away or refuses it; either way you get no saving and no
honest answer.

So the option this build adds caps the frame rate at **30**, which is exactly half
of 60 and the value the platform documents as the power-saving one on this
display:

```
device_config put game_overlay "mode=1,fps=30:mode=2,fps=30:mode=3,fps=30"
```

* **Off by default** — `frame rate cap (30 fps)`, in Options. A 30 fps phone is a
  slow phone when it is on, and that is your decision, not mine.
* **Journalled like everything else**: the previous value is read first; the exit
  puts it back, or deletes the key if there was none.
* **Honest about refusal**: if the phone will not answer, will not take the value,
  or has no `game_overlay` at all, the log says which of those happened and the
  option is put back. A value that does not take is never reported as applied.
* **Visible in Check**: the top-right check now reports `frame_rate_setting` and
  `game_mode_service` alongside the other probes, so you can see what the phone
  says before you trust it.

### DeepDoze-Enforcer: read, nothing taken

> "Can you check once this GitHub https://github.com/Azyrn/DeepDoze-Enforcer such
> that you can improve our spsm logic or features, if you can't find or looks same
> like our then leave it."

Read it end to end. It forces Doze behind a lock-state gate, sets standby buckets,
denies `RUN_ANY_IN_BACKGROUND`, force-stops aggressively behind a whitelist, and
records/restores what it changed — the same ground this module already covers,
with the same "leave newer values alone" rule. There is no feature in it this
module does not already have, so **nothing was ported** and no code was written
chasing it.

### What was left alone

* Nothing in this round changes what the mode does while it is on. The knobs, the
  whitelist, the exit path and the guarantees are where v3.6.1 left them.
* The Recents handover still only runs while the phone is on three-button
  navigation, whoever put it there.
* The test suite grew to **80 cases / 578 checks** (all green) covering
  gesture-navigation phones being
  left alone, a phone with no `device_config`, the animation-line handover, the
  touch region, the button command with the mode off, and every frame-rate branch
  (applied, refused, not taken, no key, no command).

### One thing the suite itself had wrong

The fake phone kept two records of which apps are suspended - the one the module
reads (the system's own `package-restrictions.xml`) and the one the test wrote by
hand - and they disagreed, so the suite was asserting against a phone that does
not exist. Three fixes, all in the tests: `pm suspend` now writes the system's
record the way the real PackageManager does, "the user suspended this themselves"
is recorded in both places, and the round-trip comparison reads that file as what
it says (which packages are suspended) rather than as bytes - the system rewrites
it whenever a restriction changes, and a line saying `suspended="false"` is the
phone writing down that nothing is suspended.

The exit path got a fix out of it that matters on the phone: when the system's
record does not name one of the apps this session suspended, the app is now asked
directly before the exit decides there is nothing to release. The record is
written asynchronously, and this is the one mistake that cannot be left behind -
a phone keeping an app that will not open.

The harness also now insists that no daemon from an earlier case is still
running before it measures "a second idle pass reads nothing again". It was: one
had survived, because its pid file dies with the tree it belongs to and the
module's own stop-daemon cannot recognise it afterwards - and a test that counts
reads while a second process is doing the same reads is counting noise. With the
stop made by command line - and a new check that proves nothing is left - the
same measurement gives the real answer: first pass 4 reads, second pass 0.
