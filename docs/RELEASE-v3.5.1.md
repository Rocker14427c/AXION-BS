## Axion Super Power Saving v3.5.1 (versionCode 51)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

This build answers the three things you reported on v3.5.0 — the swipe, the app drawer, and one thing your log said about the governor.

### The swipe: why 200 swipes opened nothing

The log and the code say the same thing once you put them together, and it is one
line of a gesture: the swipe was only looked at when the finger **lifted**.

On a phone using gesture navigation the bottom edge does not belong to the app at
all — Android takes that strip for its own "go home" gesture. The app is given the
press and the first centimetre of the drag, and then the touch is **cancelled**.
The lift never arrives, so v3.5.0 was waiting for an event that a bottom-edge swipe
on this phone never produces. That is the whole of it.

v3.5.1 reads the swipe **while the finger is moving**, at 16 dp of travel — the
smallest movement that is unmistakably a swipe and never a tap on a slot. The
gesture now opens the list on the way up, before Android can take the strip for
itself. The reach changed with it: the swipe is judged from the bottom third of
the screen, which is where the apps and the time remaining live.

Also from the same report:

* **"It opened once and then never again" is fixed at its cause.** The guard that
  keeps a second go-home from bouncing the list was a flag set when the list
  appeared and cleared only on pause. One list that ended without a pause left it
  up, and from then on every go-home read as "the list is already open". It is now
  cleared on stop and on destroy as well, with a timestamp for the real
  double-fire — a swipe and a go-home arriving within the same moment.
* **The gesture is in the log now.** Every open writes what opened it — `swipe` on
  this screen, `go-home` from inside an app — and the list writes how many tasks it
  found. If this ever misbehaves again, the log says whether the swipe reached the
  app at all, instead of leaving it to be guessed at.
* **The log records which navigation this phone uses** and what Android answers
  for its home, the moment the mode takes the home over. A bottom-edge swipe means
  "go home" only on a gesture-navigation phone; that one number decides how this
  gesture can work on your phone at all.

### The governor: the log found the cluster it was leaving out

Two lines of the v3.5.0 log, read together, say the phone was left with its big
cluster on `schedutil` and **no idle ceiling at all**:

```
governor: power-save on 1 of 2 cluster(s)
cpu_cap: the power-save governor holds the frequency - no ceiling written
```

Two mistakes, both now gone:

* The governor was written to the **per-policy** paths, and this phone's middle
  policy has no governor node. It is written to the per-cpu paths your own Termux
  command uses — `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` — with
  each cluster named once, and every write is **read back**: a write the kernel
  accepted and ignored no longer counts as a change.
* The frequency ceiling was skipped for the **whole phone** the moment the little
  cluster read `powersave`. It is decided **per cluster** now: a cluster running
  power-save needs no ceiling, and a cluster that kept `schedutil` gets one. On
  this phone that is the big cluster — the one that was actually unprotected.
  The log says which happened: `ceiling written for the 1 cluster(s) the governor
  did not take`, and `held_by=ceiling` on the idle line.

### The grey app drawer on the way out

The reason it happens: the launcher builds its app list once and keeps it, and
while the mode was on, the state that list was built from changed underneath it —
the standby buckets, the background restrictions, apps stopped. A launcher that is
merely *resumed* keeps drawing the stale list; a launcher that is *started* builds
it again. That is exactly what your force stop was doing by hand.

The exit does it now, once, at the end of the exit path and nowhere else:

* the home the mode was covering is refreshed — `am force-stop <that launcher>`,
  immediately followed by starting the home again, so the phone is never left with
  nothing on screen;
* never while the mode is running, and never during a screen-off;
* and only when the session actually changed something: turning the mode off after
  a session with every option switched off restarts nothing, because there is
  nothing to rebuild;
* the package is the one the journal recorded before the home swap, not a guess.

### Also

* `cpu_cap`, `gov_powersave` and the idle line now agree on what "held by the
  governor" means: it is said only when **every** cluster this phone has is
  running power-save.
* Tests: cases 70 (the governor's three paths) and 71 (a repeat screen-off inside
  one idle period) are joined by case 72 — the launcher is restarted once on the
  way out, never while the mode runs, and not at all by a session that changed
  nothing. The fake phone now carries the same per-cpu governor nodes as yours,
  including the cluster that has none. **72 cases, 454 checks, 0 failed; install
  test 22/0.**

### How to check it on your phone

1. Install with the mode off, reboot, turn the mode on.
2. **Stand on the six apps and swipe up from the bottom third — once, twice,
   three times.** The list should come up every time. Then open an app from the
   six, and swipe up from the bottom there too: same list, no flash of the Pulse
   launcher.
3. Look at the SPSM log the next time it happens if it does not: lines
   `gesture: the recents list was opened by swipe` (or `by go-home`) appear on
   every open, and `recents: listed N task(s)` says what the list found. If a
   swipe leaves *no* line at all, the phone kept that edge from the app and the
   log will say so by staying silent — send it and it will be read.
4. **Turn the mode off completely** and look at the app drawer: the icons should
   be in their normal colour immediately, without you force-stopping anything.
   The log shows `launcher refreshed: com.android.launcher3 restarted`.
5. Screen off for a few minutes, then read the log: `deep applied: … governor=powersave
   held_by=governor` should name **2 of 2 clusters** on this phone, or the
   ceiling should be named for whichever cluster refused.

### Files

* `release/Axion-SPSM-v3.5.1-RMX3430.zip` — the module: APK v3.5.1 (51), 30
  options.
  * size 1,684,030 bytes
  * sha256 `41d947c8c6dde6b823e8c9d1be412d61ea6835cb33bdad1fb0d11bce08511e68`
  * md5 `932af136e5db2ff5086fe7ee35df34bb`
* Download: `https://github.com/Rocker14427c/AXION-BS/raw/v3.5.1/release/Axion-SPSM-v3.5.1-RMX3430.zip`
* Whole build so far: `release/` holds every version from v3.3.0 on; the patch
  files in the download folder bring an older v3.5.0 up to this one.
