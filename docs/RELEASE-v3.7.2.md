# Axion Super Power Saving v3.7.2 (versionCode 60)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

One theme again, and this time the owner's own log pointed straight at it.

### The exit, at the installer's pace — the last wait removed

His log told the whole story: a 7-second exit (the installer-style profile) and
a 33-second exit on the same phone, same scripts, same screen-on. The
difference: the 33-second exit ran the **deep phase first and the session phase
after** — and a quarter of the wall time was the deep phase finishing before
the session reverts even started.

The two phases hold **disjoint sets of values**, and every knob journals only
itself — so they now run **together, as one pool**. The single ordered step
that remains is the navigation overlay coming back strictly after the home
role has been handed back. The deep phase (cpu/gpu caps, per-app background
work) no longer adds its own wait on top of the session's.

Every path — the app's exit door, the Quick Settings tile, and the installer's
own revert — runs the **identical scripts**, so they now all run at the pace
his installer showed: **8–10 seconds**. Same journal, same only-ours rule,
same honest "revert clean in Ns".

### The tile: the stuck "working…" is fixed at the root

The working sign is a file the engine writes during a transition. A sign left
behind by a crash, a power cut, or a reboot never came down — after his
flash-and-reboot the tile read "working" permanently and ignored every press.
Now:

* the engine **takes the sign down the moment the mode settles** (on or off);
* the **boot safety net clears** any sign a crash left behind;
* the tile reads **what the sign says** — only "Applying…/Restoring…/Starting…"
  counts as busy, never a file that merely exists;
* a press during a real transition still waits (never stacks a second one), and
  the tile repaints the truth every 2.5 s.

### The icon, as described

Wide and **filled**, edge to edge, with the **S cut out of the fill** — on the
coloured tile the S reads white; the whole icon is one flat shape the system
tints by state, exactly like Wi-Fi and Bluetooth.

### Recents, in its right place

The recents button is **out of the app** — with the SPSM home off, the user's
own launcher already provides recents. The **recents icon now sits on the SPSM
launcher's home screen** (between the exit door and the edit pencil): the one
screen from which the phone's own recents cannot be reached. One tap opens the
real task list; nothing in the background watches anything to provide it.

The full harness passes **535 checks, 0 failed** — every exit in it running
the new combined parallel revert.

### Install

1. Switch the mode off (door → Exit) — or just flash; the installer reverts a
   live session by itself.
2. Install the zip in ResukiSU.
3. Reboot.
