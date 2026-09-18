# Axion Super Power Saving Mode

realme UI-style **Super Power Saving Mode** for **AxionOS 2.7 (Android 16)** on the
**Realme Narzo 50A (RMX3430)**, delivered as a KernelSU / ResukiSU / Magisk module.

Current module: **v3.6.2**.

The headline property of v3 is that turning the mode **off puts everything back**.
Every change is written to a journal before it happens, and a value is only
restored if the phone still has the value we set — if the ROM or you changed it
in the meantime, that newer value wins. There is a test suite that proves this by
running the real scripts against a fake device tree.

## Why this is a rebuild, not a port

The real RUI Super Power Saving Mode is glued into the ColorOS framework, the
stock launcher, `com.oplus.battery` and vendor HALs. Those APKs crash on Axion,
so the feature is rebuilt on AOSP.

| realme UI SPSM | This module (v3.0) |
|---|---|
| Black 6-app home, door to exit | Same UX (`dev.axion.spsm`) |
| Phone / Messages / Browser + 3 | Auto-filled, tap to change |
| CPU / brightness cuts | Caps while **asleep**; nothing is taken offline unless you ask |
| Background apps gone | Standby buckets + background-run denial while asleep, per-app and reversible |
| Panel fully asleep | DT2W off while on; deep doze while asleep |
| Calls still work | Mobile data stays (Jio VoLTE) |
| Restore on exit | Journaled, per-value revert — verified by tests |

## What actually reduces idle drain

Ordered by how much they matter on this device. The first five are what a
default install turns on:

1. **Deep doze while asleep** (`deep_doze`, **on by default**) — puts the device into Doze as soon as
   the screen goes off instead of waiting for the system timers, and releases it
   the moment the screen comes on. Biggest single win, and the reason the mode is
   screen-aware: holding doze while you are using the phone is what makes a power
   mode feel broken.
2. **Background app restriction** (`app_restrict`) — non-whitelisted third-party
   apps go into a restricted standby bucket with background running denied while
   asleep, and are put back on wake. Jobs and alarms are deferred, never cancelled.
3. **Radio** (`wifi_off`, `bt_off`, `nfc_off`, `scan_always_off`) — Wi-Fi and
   background scanning are the biggest idle talkers. Mobile data stays up for
   VoLTE.
4. **Panel and touch** (`dt2w_off`, `aod_off`, `brightness_cap` — a cap that
   only ever *lowers* the screen, so a display you keep dim stays dim) — stops the touch controller and the
   ambient panel waking the SoC.
5. **The idle processor** (`gov_powersave` **on by default**, `cpu_cap`, `gpu_cap`,
   `ged_boost_off`) — while the screen is off, the kernel's own power-save
   governor runs every cluster at its lowest frequency, and no frequency ceiling
   is written on top of it: the same saving held continuously by the kernel
   instead of once from outside. The ceilings (`cpu_cap`, `gpu_cap`) stay for the
   in-use case and are lowered only while asleep, so wake-up stays instant.
6. **The memory the frozen apps hold** (`sweep_bg`, **on by default**) — suspending
   an app stops it starting; it does not give back the memory it already has.
   Every app outside your six is stopped outright and handed to ActivityManager as
   idle when the mode goes on and at **every screen-off**, so the memory comes
   back over the day. Nothing is changed, so there is nothing to undo.
7. **The ROM's own background work** (`rom_bg_off`, deep, **on by default**) — a
   system package working in the background is what keeps `system_server` busy.
   While the screen is off, the ones actually running on this phone go into the
   restricted standby bucket with `RUN_ANY_IN_BACKGROUND` denied — the same switch
   Settings offers per app — and are put back on wake. Nothing is disabled or
   suspended, the phone's own core is on a protected list, and each value is only
   restored if it is still ours.
8. **The frame rate** (`fps_cap`, off by default) — this panel is 60 Hz, and the
   platform's own frame-rate limit only accepts values that divide the refresh, so
   60 or 30 are the two real choices: the option caps the phone at **30** for as
   long as the mode is on and puts the phone's own value back on exit. Halving the
   frame rate is a visible trade, so it is yours to make, not the module's.

Every one of those is a switch in the app's **Options** screen. Nothing is
all-or-nothing.

### Leaving the screen-off state instantly

Capping the CPU only while asleep is what makes this mode usable, but it is
also a trap: if the cap is still on when you press the power button, the first
few seconds after waking are visibly slow. So the wake-up path is as short as
it can be made:

* The app's `ScreenReceiver` writes the new state and sends `SIGUSR1` to the
  daemon, which cuts its 8 second sleep short - the revert starts in
  milliseconds, not at the next poll.
* If the daemon is not running, the receiver runs `engine.sh screen-on` itself,
  so one writer or the other always acts.
* Inside `engine.sh`, the things you can feel (CPU cap, mobile-data doze) are
  lifted first and the slow per-package work runs after.
* A poke that arrives while the engine is mid-revert is remembered rather than
  lost, so a quick off-on-off still lands on the right state.

The tests measure this: a screen change is acted on in ~250 ms, where a poll
would have taken 8 seconds.

## Install (ResukiSU)

1. Download the newest `Axion-SPSM-vX.Y-RMX3430.zip` from
   [Releases](https://github.com/Rocker14427c/AXION-BS/releases).
2. **ResukiSU → Modules → Install from storage** → zip → **Reboot**.
3. Open **Super Power Saving** → grant root → **Allow**.
4. **Options** → untick anything you do not want changed.
5. Pick 6 apps → **Turn on**.

Optional: add the **Super Power Save** tile in Quick Settings.

If a previous version is installed, the installer undoes its leftover changes
before installing.

## What changed in 3.0.1

A second, deliberately adversarial pass over every script. Ten things were
wrong; each one was reproduced with a failing test before it was touched, and
the test stays in the suite:

- **The brightness cap could brighten your screen.** It wrote the cap
  unconditionally, so if you kept the panel darker than the cap, switching the
  mode on made it *brighter* — and the exit put back a value that was never
  yours. It now only ever lowers.
- **Exiting forced cores, governor and backlight whenever a journal existed**,
  even for a session where every knob was switched off and nothing had been
  recorded. Your own choices paid for it. It now forces only when a value of
  ours is genuinely still in place.
- **The "phone is stuck dark" net fired on a dim screen you had chosen**, on
  every exit. It now acts only when the journal proves the value is still ours,
  the mode is off, and the screen is on and unreadable.
- **Re-applying the idle phase saved our own values as yours.** The deep phase
  runs again on every screen-off cycle, and each run overwrote the record of
  what your apps looked like — so after a second cycle (or a reboot) every app
  stayed restricted after exit. The first record per idle period now stands.
- **A setting the mode never touched was deleted on exit**
  (`battery_saver_constants`), whatever it held.
- **Sleeping Google re-enabled packages you had disabled yourself.** It now
  only undoes its own change (unsuspend) and leaves your choices alone.
- **An interrupted exit destroyed the record of the phone's real values.** If a
  revert never finished, re-entering the mode made the capped value the new
  "original". Unfinished records are now kept across sessions.
- **A stale lock made the next action fail.** A lock left by a dead process
  waited out a 20-second timer and then reported "busy". It is taken at once
  when the owner is gone; the long override is reserved for a live, wedged one.
- **A value that spans lines came back truncated** at its first line, and a
  value containing a literal backslash-n came back as a newline. The journal is
  one record per line with values encoded, and the codec is an exact inverse.
- **Stepping out of doze was reported as an "external change"** by the verify
  command, because the snapshot recorded a state the system moves by itself.

`tests/run.sh` grew from 19 cases to 30 to pin all of this down.

## What changed in 3.0.2 — the screen, and the cap, in this phone's terms

The device itself settled two arguments this release, and both had been decided
the wrong way by assumption.

**The screen is read the way the phone actually reports it.** The verified
method on the RMX3430 is the panel node: `/sys/class/leds/lcd-backlight/brightness`
is 0 while the screen is off and 1..4095 while it is on. That node is now the
primary source — and a lit panel is accepted outright, whichever other source
disagrees. A dark panel is the weaker evidence, so it is only read as "off"
when the app's marker is not saying "on" at that moment; believing a stale "off"
is the expensive mistake, because it drops the phone into its deep phase while
somebody is using it.

The daemon no longer depends on the app at all. It reads the node through a
redirection — a syscall, not a spawned process — and re-reads it every second
while awake and every three while asleep, so the power button is acted on
without needing an event from anywhere. Measured in the suite: caps engage
500 ms after the panel goes dark with no app, no marker and no signal.

**The app's instant-signal path had never worked.** `SCREEN_ON` and
`SCREEN_OFF` are broadcasts the framework delivers only to receivers registered
at runtime, so the manifest-declared one was dead code and every transition went
unnoticed. It is now registered properly, and registering also republishes the
current state. The module does not depend on it — with a one-second poll it is
an optimisation, not a requirement.

**The dim cap is expressed in this phone's units.** The node here is 0..4095,
not 0..255, so the old raw `160` meant 4% — and the same value on another phone
means something else entirely. `brightness_cap` is now a fraction of the panel
by default (8% = 327 here), also accepts `4%`, and treats anything above 100 as
a raw value for someone who knows their node. A config carried over from a
0..255 phone is used as-is rather than quietly doing nothing.

**The emergency lift is scaled to the panel too.** It fired below a raw 40 and
lifted to a raw 128 — calibrated for a 0..255 node, so on this one the "lift"
would have been barely brighter than the cap it was lifting. It now acts below
10% of the panel and lifts to 40%, whatever the panel's range.

**The repository can rebuild the app that ships.** The options screen and the
screen receiver existed only as uncommitted files in one working tree, so a
fresh clone built an APK without the per-change opt-out screen. They are
committed now, and `build.sh` recomputes the APK from them.

## What changed in 3.0.3 — the crash that took the home screen down

The first on-device run of 3.0.2 crashed, and the log from the phone was
unambiguous:

```
java.lang.NullPointerException: Attempt to invoke virtual method
  'android.view.WindowInsetsController ...DecorView.getWindowInsetsController()'
  on a null object reference
  at com.android.internal.policy.PhoneWindow.getInsetsController(PhoneWindow.java:4136)
  at dev.axion.spsm.SpsmHomeActivity.hideSystemBars(SpsmHomeActivity.java:64)
  at dev.axion.spsm.SpsmHomeActivity.onCreate(SpsmHomeActivity.java:38)
```

`hideSystemBars()` was called before `setContentView()`, so the window had no
decor view yet and `PhoneWindow.getInsetsController()` threw. The activity that
died was **the SPSM home screen** — the one the mode swaps in — and a home
activity is restarted by the system the moment it dies. So the result was a
crash loop and a phone with no home screen at all, which is what "the app
crashed and many more things happened" was.

Two fixes, because one of them was a whole class of failure rather than this
one crash:

- **The activity can no longer be taken down by a cosmetic call.** The decor
  view is obtained after the content view exists, the insets call is made on
  that view, and the whole method is guarded: hiding the status bar is never
  worth the phone's home screen.
- **The module no longer swaps the home in without checking.** After launching
  the new home it asks the device which activity is actually resumed. If the
  answer is "not ours", the user's launcher is put back immediately and
  `home_swap` is recorded as restored, so nothing later chases a change that was
  already undone. If the device will not answer, the swap is left alone rather
  than undone on a guess.

The second fix means this failure mode cannot leave a phone without a home
again, whatever the reason: a crash, a ROM that ignores the role change, an
activity disabled since. `tests/run.sh` now covers both directions — a home that
never comes up gets the launcher back within seconds while the rest of the mode
carries on, and a home that does come up is left alone (no false alarms).

### Getting out without the app

The KernelSU/ResukiSU manager's **Action** button toggles the mode with no app
involved (module `action.sh`). If the home ever looks wrong, this puts it back:

```sh
su -c 'cmd role add-role-holder android.app.role.HOME com.android.launcher3'
su -c 'cmd package set-home-activity com.android.launcher3/.Launcher'
su -c 'am start -a android.intent.action.MAIN -c android.intent.category.HOME'
```

## What changed in 3.0.4 — speed, and two readings that became values

Everything here came out of a device log from a real session. The module keeps
its own log (`/data/adb/spsm/spsm.log`), and it showed both the timings and the
bugs.

### Exiting took 25 seconds. It should take a few.

The revert itself was never the cost - re-reading was. Every value was read by
running `settings`, one process at a time, and a phone spends about a fifth of a
second on each of those. A full revert re-read every knob twice: once to decide
whether each value was still ours to undo, and again afterwards to double-check
the result. That second pass alone was most of the wait, and it was re-asking a
question the revert had answered milliseconds earlier.

- Snapshot and restore reads now run **together** instead of one after another.
  They are independent, so the wall time is the slowest read in a group rather
  than their sum.
- An activation while the mode is already on no longer re-applies every knob.
  It ensures the daemon and the deep phase and stops - that case used to cost a
  full second pass for nothing (it appears twice in the log as "re-applying").
- The exit decides from the journal the revert just wrote, not from a fresh
  read of the whole device. `engine.sh verify` is still the honest end-to-end
  read, and it is what to run when you want the truth about the device.
- One snapshot per knob was dropped: the "before" reading only ever fed one log
  line, and the recorded original answers the same question.
- Both phases now log how long they took, so the next log says it plainly.

Measured on the shipped scripts, the same on/off turn was **236** stubbed
commands and is now **183**, with the reads inside each snapshot concurrent
rather than serial.

### A failed read became a stored value

The settings provider sometimes answers with a sentence instead of a value:

```
cmd: Failure calling service settings: Failed transaction (2147483646)
```

Two things were happening with it. The sentence was recorded as if it were the
setting - so a revert could write that sentence back into the settings database
- and it appeared as the original in the journal, so the value it replaced could
never be restored. Now a failed read is retried once, and if it still fails it is
recorded as *no reading*, which means the value is never touched in the first
place: **nothing is changed that cannot be read**.

### Home

`cmd package resolve-activity` was being asked without the action it requires, so
this ROM answered "No activity found" - and that sentence was recorded as the
original home, which meant the revert had no believable launcher to restore. The
command is correct now, the value is validated before it is recorded, and a ROM
that lacks `get-component-enabled-setting` is recorded as `unknown` instead of
having its complaint stored. On this device the configured home activity is what
actually decides HOME - the role holder does not - so this is the step that puts
the launcher back.

### Telltale that is gone

A lock released between the check and the stat was dated from the epoch, which
produced `WARN stale lock (1789238021s) - taking it` in the log: alarming, and
meaning nothing. The age is only computed when there is a lock to age.

## What changed in 3.0.9 — verified on the device, and the check that was not running

The log from this round is the first one that proves the deep phase working
(`screen on -> off (panel=0 via panel)` → `deep applied: little_max=1100000 …`),
and it also found four things wrong. All four came from the report and the log
together.

### The check finished in three seconds because it declined silently

"Check what works on this phone" needs the mode **off** - it applies and undoes
every option, which is not something to do to a live session - and the first
version said so only in a line of output the screen then overwrote. It also wrote
its own findings into the scratch directory it deletes at the end, so the run that
produced the report destroyed it.

Now: the button asks *"the check writes and undoes every option, so it will switch
SPSM off first"* with a **Switch off and check** button, the reason is logged if it
declines anyway, and the findings stay in `spsm.log` while only the scratch journal
is cleaned up. Any single option can also be checked on its own:

```sh
sh /data/adb/spsm/scripts/engine.sh probe cpu_cap     # one option
sh /data/adb/spsm/scripts/engine.sh probe             # everything
```

### The exit took 43 seconds, and left two values behind

The log tells the whole story: the screen came on and the exit arrived in the same
second, so the screen-on revert and the exit were both writing the same CPU nodes,
and the exit queued behind the other worker for the lock - 20 s of waiting, and
`WARN cpu_cap did not return to its original value` / `gpu_cap` because each was
verifying while the other wrote.

The exit now has **priority**: it waits a moment, and if the lock is held by one of
its own workers (`engine.sh` or `daemon.sh` - never anything else) it ends it and
takes the lock, saying so. Ending it is safe precisely because the exit's job is to
undo everything the worker was doing. Measured in the suite: **4 s instead of 20+**.
And when a value genuinely does not come back, the log now says what it wanted and
what it found, instead of only that something was wrong:

```
WARN cpu_cap did not return: want [policy0/scaling_max_freq 1800000 …] got […]
```

### Root apps now have their names, icons - and they start

They appeared in the list (from `pm list packages` through root) but with a
placeholder icon, the package name instead of a label, and tapping did nothing -
because every question was being asked of this app's `PackageManager`, which cannot
see them. Now, when the PackageManager says no, the answers come through root:
`pm path` → `getPackageArchiveInfo` for the label and icon, and
`cmd package resolve-activity --brief` for the launcher component, which is what
makes the app startable. On the home screen the icon and name arrive a moment later
from a background thread, so nothing slow runs on the UI thread.

### New option: Keep CPU and GPU limits while the screen is on

This was the real question behind "FKM shows all cores active and no governor
setting": by design the limits exist only while the screen is off. With this option
on they are applied the moment the mode is switched on and stay until it is
switched off - so they can be watched in a kernel manager with the screen on.
Deep doze and the background restriction are **never** held that way: those are
about sleeping, and holding them while the phone is in use would break the apps you
allowed. `engine.sh probe` verifies each of them individually.

## What changed in 3.0.8 — the app list, and options that prove themselves

### The app list was still not complete, and now it cannot be

The picker has been wrong twice, in two different ways, and the second fix was
built on the same wrong assumption as the first: that the package manager will
happily tell this app about every package on the phone. It will not, always, and
when it does not there is no error to see - the app is simply not in the list.

So the list is now merged from two independent sources and nothing is filtered
out at all (except SPSM itself):

1. `PackageManager.getInstalledApplications` - which is where labels and icons
   come from,
2. `pm list packages` **through root** - which reports what is installed
   regardless of what this app is allowed to see.

Anything only the second source knows about still appears, by package name with a
placeholder icon, so it can be picked. Every row now also says what it is:
`user`, `system`, `hidden` (no launcher entry) or `root`. And for the case where
even that somehow misses one, a package name typed into the search box is added
directly - that path cannot fail, because it asks for nothing to be discovered.

The list is read fresh every time the screen is opened, so an app installed five
minutes ago is already there; the header shows how many were found.

### An option that toggles but does nothing is now labelled as such

This was the fairest complaint of the lot: options were listed that, on this
phone and this ROM, changed nothing. There is now a check that answers it against
the device itself - **Check what works on this phone** in the options screen, or
`engine.sh probe` in a terminal. For every option it records the value, applies
the change, reads the phone back, undoes it, and reads again, then reports one of:

| verdict | meaning |
| --- | --- |
| works | it changed something here, and putting it back worked |
| nothing to do here | the phone was already in that state (e.g. the screen is already darker than the brightness cap) |
| did not revert | it changed something and did not put it back - a real bug worth reporting |
| could not check | nothing it controls could be read on this phone |

Each option carries its verdict in the options screen, and `engine.sh status`
summarises the last run. Two things worth knowing about how it works: it refuses
to run while the mode is on (it writes its own journal while it checks), and
options whose effect a settings reading cannot see - the radios, Play Services -
declare extra evidence of their own, because switching a radio does not
necessarily move any setting.

### Radios: switched off only when the phone said they were on

The device log showed Bluetooth recorded as `0` and NFC recorded as `null` while
both radios were on - and those recorded values are what the exit used to decide
whether to switch them back on, so it did not. Wi-Fi, Bluetooth, NFC and the new
mobile data option now ask the system for the radio's real state (via
`cmd wifi status`, `cmd bluetooth_manager`, `dumpsys nfc`, with the old globals as
a fallback), record that before touching anything, and restore from it. A radio
whose state cannot be read is not switched at all, and the log says so.

### The version is on screen now

A whole round of this went into "did the flash take effect?", and neither side
could answer it from the evidence available: the log had no version in it, so a
log written by scripts three versions old looked exactly like a current one. Now:

- every session header reads `===== SPSM v3 ON (scripts 3.0.8, module 3.0.8) =====`
- `engine.sh status` and a new `engine.sh version` print it, and status also
  summarises the last probe
- the home screen shows `scripts 3.0.8`, or **`STALE SCRIPTS: running 3.0.4,
  module is 3.0.8`** when the phone is executing an older copy than the module it
  has installed - which is the failure that makes every fix invisible
- when that mismatch is detected, the next switch copies the scripts out of the
  module and says so in the log. The copy goes through a temporary file and a
  rename, because the files being replaced are the ones currently running.

### New option: Mobile data off

Off by default, because only the user knows whether a message has to get through.
On a weak signal the radio is one of the biggest drains. It is recorded and
restored like every other radio, and the probe verifies it.

## What changed in 3.0.7 — what the device log showed

The install log and the module log arrived, and they confirmed the diagnosis and
found two more real bugs.

### Confirmed: the daemon was alive and blind

```
10:02:59 daemon start (pid 11805)       <- the daemon is running
10:02:59 screen  -> on                  <- and its first decision is "on"
10:13:41 daemon: mode is off, exiting   <- still alive 10m43s later
```

The daemon ran for the whole session and exited on command, so it was not dead.
Its view of the screen never changed once, although the screen was off for the
five-to-seven minute test inside that window: it was frozen at "on", exactly as
3.0.6 diagnosed, and the deep phase never applied.

### The exit was crying wolf

```
10:13:43 WARN location_off did not return to its original value
10:14:01 exit: 3 value(s) could not be restored - forcing the safety valves
```

Three drifted knobs were reported while only one was named. Two things were
wrong, and both made the module distrust its own work:

- a record left in `restored-drift` by an earlier session was **counted** as
  drift on every later exit while never being retried (the revert skipped any
  state that was not `applied`). It is now retried like an `applied` record -
  which both makes the count honest and actually repairs what a dead session left
  behind, since every restore function writes only what is still ours to write;
- a target whose original could not be **read** was compared against the later
  reading as if it were a value, and the difference was called drift. `apply_kv`
  refuses to write such a target, so the module never changed it and it cannot be
  drift. Those are the two keys this phone refuses to read - they were producing
  a false alarm on every exit.

### Location was switched off with no way back (a real unrevertable change)

`location_off` reversed itself by reading `secure location_mode` — **the key this
ROM refuses to read.** So it switched location off, could not prove it had, and
left it off. That is the one thing the module promises never to do, and it was
sitting in the log. The switch's real state is now asked of the system
(`cmd location is-location-enabled`), written down before anything is touched,
and only a location this module switched off is switched back on. If the state
cannot be read, location is left alone and the log says so.

### The panel-unreadable path no longer trusts an old marker either

If the backlight node cannot be read at all, the app's marker used to answer for
up to a day - the same trap from the other side. Now a marker only answers while
it is seconds old; after that the power manager is asked directly
(`dumpsys power`), cached for a few seconds so the degraded path costs one binder
dump per cache window rather than one per tick, and an old marker is the last
resort.

### The installer stopped wasting two rounds per install

```
pm install --disable-verification --bypass-low-target-sdk-block -> Unknown option
pm install --disable-verification                              -> Unknown option
pm install                                                     -> Success
```

Both flags are rejected by this ROM's `pm`, so every install began with two
failures and a stack trace before the attempt that always works. The plain
install now goes first, and the flags remain as fallbacks for a ROM that needs
them.

## What changed in 3.0.6 — why nothing was being saved

### The bug: a stale "on" from the app made the mode believe the screen was always on

This is the one that mattered, and it made everything else untestable.

The screen state is read from the backlight node, which is the right answer on
this phone. But one rule sat on top of it: when the panel read 0 (dark) and the
module had not already decided "off", the app's marker file was allowed to
override it, and that marker was trusted for **24 hours**.

The app writes "on" every time it is opened and every time the screen wakes. It
also writes "off" when the screen turns off — but only while its process is
alive, and a cached app gets reclaimed routinely, more so while a power saving
mode is running. So the sequence is ordinary:

1. the app is opened (it writes `on`),
2. Android reclaims the process,
3. the screen is turned off and nobody writes `off`,
4. the marker still says `on`, and it is fresh as far as the old rule was
   concerned, so it outranks the dark panel.

From then on the daemon is certain the screen is on, forever. It never logs a
screen-off transition, never enters the deep phase, never applies a CPU cap,
never freezes Google, never restricts background work, and `drain.log` stays
empty — which is precisely the report: *"all cores active, schedutil, apps still
running, no saving"*. The session knobs still worked, which is why the mode
looked like it was doing something.

The fix is a bound rather than a removal: the marker may outrank a dark panel
only while it is seconds old (the window in which the app's write can genuinely
arrive before the backlight node lights). Anything older is stale evidence, and
the panel decides. `tests/run.sh` case 31 fails on the old rule and case 41
reproduces the whole device scenario end to end.

### The mode can now prove it is working, and prove it is alive

A mode that saves nothing and a mode that is not running look identical from the
outside, so the daemon now says what it is doing:

```
daemon: screen is off (panel=0 via panel marker=on@10800s)   <- the decision, and its evidence
screen on -> off (panel=0 via panel)                          <- every transition
daemon alive: panel=0 state=off deep=applied caps_little=1100000 ticks=60   <- every few minutes
```

The heartbeat is the important one: while the phone is asleep it is the proof
that the screen is off, that the caps are in place, and that the process saying
so is still running. `engine.sh status` reports the same thing on demand:

```
screen=off
screen_source=panel
panel=0
deep=little_max=1100000 big_max=1300000 governor=schedutil doze=forced
daemon=2341
```

### The daemon detaches itself

It is started from a shell that belongs to an app, so it now runs in its own
session (`setsid`, when the phone has it) and writes its own pid file. A
force-stop of the app cannot take the screen watcher down with it.

## What changed in 3.0.5 — blocking other apps, and a list that shows them all

### Other apps can now actually be blocked (a knob, and you can turn it off)

The mode used to leave every app launchable — it restricted their background
work, but anything that could start them (Settings ▸ Apps ▸ *Open*, a widget, a
notification) still worked, which is not what a super power saving mode means.
There is now a knob for it: **Block other apps**. Apps you have not allowed are
suspended (their icons grey out) and stopped, and they are returned to normal the
moment you exit.

What it never touches: the dialer, messages, alarms, the system UI, Settings,
your keyboard, your launcher, our own app, and **your root manager**. That last
one is deliberate and was also a bug: ResukiSU's package was missing from the
"never restrict" list, so the mode was treating the app you would use to rescue
the phone as an ordinary background app. It is now protected by name, along with
Magisk, KernelSU, SukiSU, MMRL, FKM and the rest.

It also keeps careful books: only apps *it* suspended are unsuspended on exit. An
app you had suspended yourself before switching the mode on stays exactly as you
left it, and is never claimed as the module's work — `tests/run.sh` covers that
case specifically.

### The app list shows root managers now

The picker asked the launcher what it had: activities answering MAIN/LAUNCHER.
That is not the same question as "what is installed", and it left out precisely
the apps people need most here — a hidden root manager, or any app whose launcher
entry is disabled, simply was not offered. The list is now built from the
installed apps: everything with a launcher entry, every user app (even a hidden
one), and the known root managers by name, with each package listed once.

### The idle state is written down where you can read it

The CPU caps, the offlined cores and deep doze exist **only while the screen is
off** — that is the design, so the phone is never slow while you are using it.
The consequence is that if you open a kernel manager with the screen on, every
core and governor looks normal, because it *is* normal at that moment. That made
the work impossible to verify after the fact, which is a fair complaint.

So the module now records it at the moment it applies:

```
deep applied: little_max=1100000 big_max=1300000 governor=schedutil doze=forced
```

That line goes to `spsm.log` when the screen goes off, and `engine.sh status`
shows it as `deep=…` until the next wake, when it becomes `deep=released`.

### A snapshot function must not write

Worth recording because it cost me a bug: the engine calls a knob's snapshot
function twice per application (once to record the original, once to record the
result). The first version of the blocking knob also wrote a state file from its
snapshot, so its own second call overwrote the record with "these apps were
already suspended" — and the exit then left every app suspended. Snapshot
functions now only read, and what the module suspended is recorded by the apply
itself, in one place.

## What changed in 3.6.0 — the buttons, Clear all, and the memory that was left running

**The swipe is gone.** v3.5.1 was spent on reading the swipe better, and your log
settled it: the gesture *did* reach the app on nearly every try (the log lines are
all there) and the list still did not come up, because on a gesture-navigation
phone Android takes the bottom edge for its own "go home" mid-swipe and a
background activity start from a pushed-back app is refused. So the mode now asks
the phone for **three-button navigation** while it is on — the phone's own bar,
switched by the phone's own overlay command (`cmd overlay enable-exclusive
--user 0 --category com.android.internal.systemui.navbar.threebutton`), with
nothing drawn by this app:

* **Back** is Back — an app you are in gets the press; on the power-saving home
  there is nothing behind it.
* **Home** comes to this mode's home, never the phone's launcher.
* **Recents** — the phone's own button sends `KEYCODE_APP_SWITCH`, which reaches
  whatever is on screen first: this mode's screens consume it and open this mode's
  list, so the launcher's recents screen is never started. From inside an app the
  daemon watches the phone's event log and hands that screen over the moment it is
  named, then reads the screen back and retries (up to three times) if the phone
  put the launcher's screen up instead. This runs on a phone in three-button
  navigation whether this mode put it there or the owner did.
* Your navigation setting **and** the overlay that draws your bar are journalled,
  and both are put back on exit. A phone that refuses the write keeps its own
  navigation; a phone that will not say which navigation it uses is left alone.

**Clear all** in the recents list closes every task on it and stops the frozen
background in the same press, then reads the phone's task list back so the count it
shows is true.

**The memory** — 649 processes and 47 MB free in your report — is addressed twice:
apps outside your six are stopped outright and made idle at mode-on and at every
screen-off (`sweep_bg`), and the phone's own background work is restricted per
package while asleep, with the bucket and app-op recorded and put back on wake
(`rom_bg_off`, deep). `system_server` itself is not touched: what is taken away is
its clients.

## What changed in 3.6.2 — the Recents button, for real, and 60 → 30 fps

**The button was watched in the wrong place.** The v3.6.1 guard waited for the
launcher's recents *activity*. Your log has that activity zero times in nine
hours, and this line exactly once: `I/input_focus: [Focus entering
recents_animation_input_consumer, reason=setFocusedWindow]`. This launcher does
not start an activity for Recents — Quickstep plays a *recents animation* inside
itself and the screen that slides up belongs to no activity the guard could ever
match. So the guard watched a door nobody uses.

The daemon now (a) matches that animation line as well, (b) reads the touchscreen
itself and watches a tap in the Recents area of the navigation bar, taken from the
phone's own insets and density rather than a hard-coded guess, (c) starts this
mode's list and **reads the screen back**, asking again if the launcher's screen
came up instead — three tries, and a press that fails writes what `am start`
answered, and (d) follows the log from *now* (`logcat -T`) instead of replaying
the buffer, which is why v3.6.1 acted on a pre-mode line the moment the daemon
started. A phone with no `getevent` says so in the log instead of staying silent.

```
sh /data/adb/spsm/scripts/engine.sh recents-button   # hand over as if the button was pressed
sh /data/adb/spsm/scripts/engine.sh recents-area     # the region being watched, and where it came from
sh /data/adb/spsm/scripts/engine.sh recents-watch    # watch the button for 20 s - press it now
```

**The exit time was understated.** The log said "revert clean in 4 s" for a 97 s
exit: one stopwatch was shared by the exit and by the phase loops, so the number
printed was the last knob's revert, not the exit. Three stopwatches now, and the
line reports the real one.

**40 fps is not a thing this panel can do.** The platform's FPS limit (Game Mode,
A13+) only accepts values that divide the display refresh, and Google's own table
for a 60 Hz panel lists **60 and 30**. So the new option is `fps_cap`, **off by
default**, capping the phone at **30 fps** while the mode is on — journalled,
restored to the phone's own value on exit, refused loudly if the phone will not
answer or will not take it, and shown in Check as `frame_rate_setting`.

**DeepDoze-Enforcer** was read end to end and adds nothing this module does not
already do (lock-gated Doze, buckets, `RUN_ANY_IN_BACKGROUND` deny, whitelist,
record/restore, newer-values-win). Nothing was ported from it.

## What changed in 3.6.1 — the phone's own bar, and an exit that is not four minutes

**The bar is the phone's own.** v3.6.0 drew three buttons of its own as a fallback;
that is gone — no layout, no class, no icons, no strings, and the suite fails if any
of it comes back. The switch is the owner's own verified command (`cmd overlay
enable-exclusive --user 0 --category com.android.internal.systemui.navbar.threebutton`)
plus the setting the ROM keeps in step with it, read back before it counts as a
change. The overlay that was enabled before — `gestural` on this phone, read from
`cmd overlay list` — and the setting are both put back on exit; a phone that
refuses is put back explicitly and told about in the log; a phone that will not say
is left alone.

**The Recents button is synced to this mode's list**: the daemon watches the
phone's event log while the phone is on three buttons (whoever put it there), and
the handover is verified — the list is started, the screen is read back, and if the
launcher's recents screen came up instead it is stopped and the list is asked for
again. A press that fails now says so in the log, with what `am start` answered,
and a recents line the guard refuses is written down once per burst.

**The four-minute step is gone.** `rom_bg_off` spent 264 seconds on fourteen
packages because every package was tested against the protected lists with two
`printf | grep` per test, and every value was read and written one at a time. The
tests are string comparisons now and the writes run together.

**The exit is shorter**: the daemon is stopped at the top (it was holding the lock
against the exit), `app_restrict` releases its apps together, independent values
inside a restore are written together rather than one at a time, and `log()` no
longer forks a `wc` on every line.

## Measuring it

Claims about battery life are worth nothing unmeasured, so the daemon measures
its own sleeping drain and writes it to `/data/adb/spsm/drain.log`:

```
2026-09-10 23:41:02 screen off 84% -> 82% in 421 min (0.28%/h)
```

One line per sleep: the level as the screen went off, the level when it came
back, and the rate in between. If the numbers do not look like the 4-5% a night
this is meant to replace, `/data/adb/spsm/spsm.log` next to it says which knobs
were applied and which were left alone.

## Guaranteed revert

`module/scripts/engine.sh` is the only thing that changes anything:

- **Snapshot first.** Before a knob is touched, its current value(s) are written
  to `/data/adb/spsm/journal/<knob>.orig`. The value we then set is stored
  separately as `.applied`.
- **Per-value revert.** On exit, each target is re-read. It is written back only
  if its live value still equals what we set. A value you changed yourself after
  us is left alone and logged as `keep <knob>`.
- **LIFO order.** Changes are undone in the reverse of the order they were made.
- **Drift is visible.** `engine.sh verify` re-reads everything and reports any
  value of ours that is still in place, as `drift=N`.
- **Crash safety.** `post-fs-data.sh` runs before the system is up and, if a
  journal exists, forces cores online and puts back a sane governor and a visible
  panel. A reboot or a flat battery can never leave the phone crippled. On the
  next boot the mode is *reverted*, not resumed (unless `resume_on_boot=1`).

Missing nodes are recorded as `(MISSING)` and skipped on restore, so the engine
never invents a value or writes to a node that was not there.

## Options, and why the app cannot lie to you

The scripts are the source of truth. `engine.sh dump-knobs` writes
`/data/adb/spsm/knobs.list` from the same registry the engine executes, and the
app's Options screen renders that file. A switch that appears there is a change
the scripts really make.

Turn a knob off and it is never touched — no snapshot, no apply, no restore.

## Commands (root)

```sh
sh /data/adb/spsm/scripts/engine.sh status       # what is on and what is applied
sh /data/adb/spsm/scripts/engine.sh verify       # is anything still changed?
sh /data/adb/spsm/scripts/engine.sh toggle       # on / off
sh /data/adb/spsm/scripts/engine.sh set deep_doze 1
sh /data/adb/spsm/scripts/engine.sh deactivate   # full revert
sh /data/adb/spsm/scripts/engine.sh clear-all   # close everything, stop the frozen apps
sh /data/adb/spsm/scripts/engine.sh status | grep -i nav   # which navigation the phone is on
sh /data/adb/spsm/scripts/engine.sh recents-guard "<one line of logcat -b events>"
```

Log: `/data/adb/spsm/spsm.log`. Journal: `/data/adb/spsm/journal/`.

## If you get stuck

- Door icon (top left) → Exit.
- ResukiSU → Modules → remove this module → reboot. Uninstall reverts first, then
  removes itself.
- Root shell: `sh /data/adb/spsm/exit.sh`
- Emergency undo scripts are in `tools/`. Read-only diagnostic:
  `sh tools/DIAG.sh` (writes nothing).

## Build

The build is reproducible and fetches its own toolchain — no SDK install and no
hardcoded paths:

```sh
./build.sh --bootstrap        # downloads the toolchain once, then builds
./tools/makezip.sh            # flashable zip from module/
sh tests/run.sh               # device behaviour, no phone needed
sh tests/run-install.sh       # the APK install fallback chain
```

`tests/run.sh` runs the real engine scripts against a fake device tree with
stubbed Android commands, 41 cases and 184 assertions. It asserts, among other
things, that entering and leaving the mode leaves that tree **byte-for-byte
identical**, that a value you changed yourself is never overwritten, that a
crash-and-reboot puts the phone back, that a normal boot touches nothing at all,
that a screen change is reacted to well inside the poll interval, that an exit
cannot be undone by a screen-off that was already in flight, that the drain
report is arithmetically right, and that the shipped defaults are themselves
fully reversible. `tests/run-install.sh` drives `install-apk.sh` through a stub
`pm`: first-try success, the signature-mismatch recovery, the package-already-
present case, and outright failure (which must not silently pretend to work).

Toolchain sources are public registries: `jdk4py` (PyPI), `aaptjs3` and
`@drxiaozhi/minapk` (npm, which carries the official `d8`, `apksigner` and an
Eclipse compiler), and `Sable/android-platforms` (GitHub) for `android.jar`. If
`ANDROID_HOME` / `JAVA_HOME` already point at an SDK and JDK, those are used
instead. `resources.arsc` must be **STORED** and 4-byte aligned; `tools/apkpack.py`
does that in Python so no `zipalign` binary is required.

`ci/build.yml` is the same thing for GitHub Actions: it runs both suites, builds
the APK and the zip, and uploads them as artifacts. It lives outside
`.github/workflows/` because the token used here is not allowed to write
workflow files - move it into place (`mkdir -p .github/workflows && mv
ci/build.yml .github/workflows/`) and it runs on the next push.
