# Axion Super Power Saving v3.7.1 (versionCode 59)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

One theme: **one speed for everything** — plus the tile, fixed and renamed, and
this mode's recents reachable from any launcher.

### One speed for everything

Three measurements of the same work on this phone: the installer's revert of a
live session **~10 s**, the app's exit **~40 s**, a tile apply **~1 min**. The
work was identical; what differed was which steps still ran in single file. Now
everything runs the installer's way:

* the exit reverts the **deep phase side by side** (it holds the two slowest
  reverts on the phone — the per-app background work — and they ran one after
  another; that was the whole 30 s);
* the **apply runs side by side** too, so entering the mode takes about as long
  as the phone actually needs to answer, not four times that;
* every path — the door, the tile, the installer — runs the **same scripts at
  the same speed** now. The ordered pair stays ordered: navigation back before
  the home role on exit, home before navigation on entry. All guarantees
  unchanged: journalled, only-ours, verified, "revert clean in Ns".

### The tile: "Super Battery Saver"

* renamed exactly as asked, with a **system-style icon**: one flat monochrome
  battery-with-an-S, the way system tiles draw — so **the system tints it by
  state**: coloured while the mode is on, plain while off, like Wi-Fi and
  Bluetooth;
* **the hang is gone**: the transition is handed to root detached from the tile
  service — the system can unbind the tile at any moment and the scripts still
  finish (the exit always completes);
* a press **during** a transition no longer stacks a second one — the tile
  watches and shows the true state the moment the phone is idle;
* tap = enter/exit in place (the app never opens); long-press = Options.

### Recents from any launcher

With the SPSM home screen off, you are on your own launcher — so the app now
carries the recents itself: **drawer → Super Power Saving → Recents**. The same
real task list, Clear all included, and nothing in the background watching
anything to provide it.

The full harness passes **531 checks, 0 failed** — every one of them exercising
the parallel exit and apply on the way.

### Install

1. Switch the mode off (door → Exit).
2. Install the zip in ResukiSU.
3. Reboot.
