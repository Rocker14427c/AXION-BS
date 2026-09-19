## Axion Super Power Saving v3.6.0 (versionCode 52)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

Four things, all of them from your last message: the swipe, the buttons, Clear
all, and the background that keeps running.

### The swipe is gone; the phone runs on three buttons while the mode is on

Your report was "gesture didn't work properly", and your own log says why. Every
swipe line the app wrote was there — `recents: the list was opened by swipe`,
`by go-home` — so the swipe *did* reach the app. What did not happen was the list
coming up. On a phone using gesture navigation the bottom edge belongs to Android:
it takes the touch away mid-swipe, and a background activity started from an app
that has been pushed to the back is refused. Two builds were spent on reading that
gesture better. Reading it better was never going to fix it, so it is **removed**.

On your instruction the mode now puts the phone into **three-button navigation**
while it is on, and the three buttons do exactly what you asked:

* **Back is Back** — an app you are in gets the back press it always got; on the
  power-saving home there is nothing behind it, and the home stays where it is.
* **Home comes to this mode's home** — the six apps, never the phone's launcher.
* **Recents opens this mode's list** — the phone's own Recents button sends
  `KEYCODE_APP_SWITCH`, which is delivered to whatever is on screen first. This
  mode's screens consume it and open *this* mode's list, so the launcher's recents
  screen is never started at all. Nothing is covered up afterwards because nothing
  else was opened.
* **And from inside an app**, where a home-screen control could never reach you,
  the daemon reads the phone's event log (`logcat -b events`). The moment a line
  names the launcher's recents screen, that screen is taken down and this mode's
  list is started in its place. `engine.sh recents-guard <line>` runs that same
  decision by hand, for a quick check.

Your navigation setting is journalled like everything else: it is read before it
is touched and put back exactly as it was when the mode is switched off. On a phone
that refuses the switch (the write is read back six times over 2.4 s), the old
value is written again explicitly, the journal is told the change was undone, and
the mode's own screens **draw their own three buttons** at the bottom instead — so
there is a way into recents either way, never a screen with dead controls.

### Clear all, in the recents list

One button, next to the door icon: every task the list is showing is closed, and
the frozen background is stopped and goes idle in the same press. The honest part
is the count — the phone's task list is read back afterwards, so the message says
`Cleared 2 · 0 still open` and a task that refused to close is counted as still
open rather than reported as done. The log line has the memory freed with it:

```
clear all: 3 task(s) asked to close, 3 gone, 0 still listed, free memory 3.6G -> 3.6G
```

### The memory the frozen apps were holding

Your `top` had 649 processes and 47 MB free, with one chat app holding 490 MB.
Suspending an app stops it being *started*; it does not give back the memory it
already has. Stopping it does — so with **Hand back background memory** on (the
default), every app of yours that is not in the six slots is stopped outright and
handed to ActivityManager as idle (`am make-uid-idle`), and the phone is asked to
clear what it still calls background (`am kill-all`). It runs when the mode is
switched on and again at **every screen-off**, so a phone left alone all afternoon
keeps giving memory back:

```
background sweep (screen off): 12 frozen app(s) stopped, free memory 1.9G -> 2.6G
```

Nothing is changed here, so there is nothing to undo: a stopped app is simply an
app that starts again the next time you open it.

### The ROM's own background work, and `system_server`

`system_server` is Android itself and is deliberately not touched — every app,
including this one, is a client of it. What *can* be taken away is its work: a
system package humming along in the background is exactly what keeps that big
process busy while you are not using the phone.

**Restrict the ROM's background work** (deep, on by default) does it per package,
while the screen is off, using only what the phone says is running right now
(`ps`, filtered to the phone's own packages):

* the package goes into the **restricted** standby bucket — jobs and network are
  deferred, nothing is cancelled;
* **`RUN_ANY_IN_BACKGROUND` is denied** — the same switch the system's own
  "Restrict background" setting sets for an app;
* `am make-uid-idle` puts it to sleep now instead of leaving it to a timer.

Nothing is disabled and nothing is suspended: every one of them works the moment
it is opened. The phone's own core — System UI, the phone, Telecom, Settings, the
providers, Wi-Fi/Bluetooth/NFC, the launcher, WebView — is on a protected list and
is never touched, nor is anything Android already exempts from battery
optimisation, nor anything in your six slots. Each package's bucket and app-op are
recorded **before** they are changed and put back on wake, and only if the live
value is still ours: a value something else has moved since is a newer decision
than ours and is left alone.

### Also in this build

* The hint under the apps now says what it really does (`Hold an app to change it`)
  — the word "swipe" is gone from the app entirely.
* Log lines for every button: `recents: the list was opened by recents-button`,
  `… by back-button`, `… by home`.
* With the governor refused by a cluster, the log now names the governors that
  node offers, and says when MTK's Low Power mode may be pinning it — the reason
  `1 of 2 cluster(s)` was all the last log could tell you.

### Tests

Five new cases (73–77), all of them running the real scripts against the fake
phone: three-button navigation and its journalled revert (including a ROM that
refuses the write, and a phone that never had the setting), the background sweep
and its opt-out, the ROM-background restriction with a core package, an exempt
package and a third-party package left alone, Clear all with a task that will not
close, and the recents guard — by hand, live through the daemon, ignored when the
mode is off, and not started at all when the option is off.

### How to check it on your phone

1. Install with the mode off, reboot, turn the mode on.
2. **Look at the bottom of the screen: there should be three buttons.** Press
   **Recents** — this mode's list comes up. Press **Home** — the six apps. Open an
   app from the six, then press Recents there: same list, and no launcher recents
   screen in between.
3. In the list press **Clear all**: the tasks go, and a message says how many are
   still open. The log line `clear all: …` has the exact count and the memory freed.
4. Screen off for a few minutes, then read the log: `background sweep (screen off)`,
   and `rom background: N of the phone's own package(s) restricted for this idle
   period` with the names.
5. **Turn the mode off completely.** The phone should be back on gesture
   navigation, exactly as it was — the log says
   `nav: three-button navigation is on (was 2)` going in, and the exit restores it.

### Files

* `release/Axion-SPSM-v3.6.0-RMX3430.zip` — the module: APK v3.6.0 (52),
  **33 options** (three new: Three-button navigation, Hand back background memory,
  Restrict the ROM's background work).
  * size 1,694,980 bytes
  * sha256 `bf8cfb14e00a47068bf05346e22953d7d844961b1796840056cfbe38136b1432`
  * md5 `34c9bde46ed5f4a502826c127ed94a90`
* Download: `https://github.com/Rocker14427c/AXION-BS/raw/v3.6.0/release/Axion-SPSM-v3.6.0-RMX3430.zip`
* The build was checked before it was packaged: the full test suite ran **79 cases,
  517 checks, 0 failed**, and the APK inside this zip was read back with
  `tools/dexcheck.py` to confirm the new code is really in it.
