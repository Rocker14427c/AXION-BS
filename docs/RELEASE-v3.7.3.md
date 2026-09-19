# Axion Super Power Saving v3.7.3 (versionCode 61)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

The owner confirmed the v3.7.2 exit ("now it's exiting very fast" — the log
shows **revert clean in 16s**, every knob returned). This round is polish in
the places he pointed at, plus a careful audit.

### The small things

* **The recents icon moved beside the pencil** on the SPSM launcher's home
  screen (top-right pair): the one place the phone's own recents cannot be
  reached, one tap from the real task list.
* **The tile battery is the battery-saver shape** — wide, 2:1, matching the
  ROM's own battery-saver tile — and the active colour is the **system's own
  tile tint**, the same mechanism that colours Wi-Fi and Bluetooth.
* **A new launcher icon.** The white square with the yellow battery is gone.
  The app is a proper adaptive icon now: near-black background, tall green
  battery in the mode's own green, the S on the fill — shaped by whatever mask
  the launcher uses, with a themed monochrome layer for Android 13+.

### The audit

Every report in this project gets the same question: is it really a bug? This
round's audit found and fixed exactly one, and removed one relic:

* **Fixed:** a failed tile state read (a slow `su`, a busy moment) returned
  "unknown", and the tile would have repainted a mode that is **on** as if it
  were off. Now a read that says nothing changes nothing — the tile keeps its
  last truth until the phone answers.
* **Removed:** the last dead line of the watcher era — a no-op exit function
  whose name promised to kill watcher children that no longer exist. Nothing
  called it; the name lied.
* **Re-asserted by test:** the two orders that matter on the way in — the
  memory sweep after the app blocking it depends on, and the navigation mode
  after the home role.

The 16-second exit code is untouched. Full harness: **539 checks, 0 failed.**

### Install

1. Switch the mode off (door → Exit).
2. Install the zip in ResukiSU.
3. Reboot.
