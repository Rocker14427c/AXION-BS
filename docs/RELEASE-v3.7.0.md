# Axion Super Power Saving v3.7.0 (versionCode 58)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot (the reboot also arms the frame-rate cap).

Three things this round, all from the owner's reports: the tile is a real
switch, the mode is fully usable without its home screen, and the exit is as
fast as the installer's own revert.

### The Quick Settings tile

* **Tap = on / off.** The tile runs the same journalled scripts the app's door
  runs, in place. The app does not open. (The old tile opened Setup on every
  press and never showed a state.)
* **The tile shows the truth.** Coloured while the mode is on, plain while it
  is off — read from the marker file on the phone, the same fact the door and
  the log go by.
* **Long-press = Options.** The system's own hook
  (`QS_TILE_PREFERENCES`) opens this mode's options screen, where each change
  can be allowed or refused.

### The mode without its home screen

With "Switch the home screen" off, the phone keeps its own launcher — and
nothing is lost any more: the tile enters/exits from anywhere, and the app from
the drawer has the six app slots, Options, and the exit door. Nothing in the
mode requires the SPSM home to be switched on.

### The exit, at the installer's speed

The owner measured the module's own installer revert of a live session at about
**20 s**, while the app's exit took about **60 s** for the same work. The work
was the same; the waiting was not — this phone answers one settings/pm call at
a time, and the exit asked its questions in single file. The exit now runs the
independent reverts **side by side** (each knob in its own subshell, its own
journal slice, its own tagged scratch files), while the two reverts that have
an order — the navigation overlay back before the home role — run in order, as
always. Every guarantee is unchanged: journalled, only-ours, verified,
"honest Ns" in the log.

### Also

* **The status-bar switch is gone.** The bar is kept visible the whole time the
  mode is on; the option is out of the list, and even an old stored "off"
  cannot disable it.
* **Recents, final state:** the phone's Recents button is the phone's own —
  there is no watcher, listener, or handler of any kind left in the module.
  This mode's own recents list is one tap of the Recents button on the mode's
  home screen, and it costs nothing while you are not using it.

The full harness passes **526 checks, 0 failed**, including the new ones: the
tile's sources (toggle in place, no activity on tap, the long-press hook, the
full name), the status bar kept with a stored "off" and absent from the option
list, and the ordered reverts keeping their order on the way out.

### Install

1. Switch the mode off (door → Exit).
2. Install the zip in ResukiSU.
3. Reboot.
4. Optional: pull the tile into Quick Settings; tap it any time.
