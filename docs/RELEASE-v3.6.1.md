## Axion Super Power Saving v3.6.1 (versionCode 53)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

A correction and a fix round on v3.6.0: the bar is the phone's own now, the
Recents button is wired to this mode's list, the four-minute step is gone, and
the exit is faster.

### The bar: the phone's own, switched by the phone's own command

> "i didn't told you to implement a custom three button navigation bar, i mean i
> want system own 3-button navigation bar. Also you custom three button
> navigation bar is too buggy, so remove it completely and then just add system
> one and as always while leaving return back to normal state."

Fair. v3.6.0 drew its own three buttons as a fallback; drawing buttons under a
system bar that is also there is how you get two bars, one of them wrong. The
bar this app drew is **deleted outright** — no layout, no class, no icons, not
even the strings, and the test suite now fails if any of it comes back.

What replaces it is exactly what you verified by hand:

```
su -c 'cmd overlay enable-exclusive --user 0 --category com.android.internal.systemui.navbar.threebutton'
su -c 'cmd overlay enable-exclusive --user 0 --category com.android.internal.systemui.navbar.gestural'
```

* **On:** the three-button overlay is enabled *and* the setting the ROM keeps in
  step with it is written (`secure navigation_mode 0`), so the two can never
  disagree. The phone is then asked what it is actually drawing, up to six times
  over 2.4 s — a write that was accepted and ignored is not a change.
* **Off:** both go back — the overlay that was enabled before (`gestural` on your
  phone, read from `cmd overlay list` before anything was touched) *and* the
  setting. The log says which:
  `nav: the phone's own navigation is back (overlay com.android.internal.systemui.navbar.gestural)`.
* **Refused:** a ROM that takes the command and does nothing gets its own
  navigation written back explicitly, the journal is told the change was undone,
  and the log says so. Nothing is left half-switched.
* **Unknown:** a phone that will not say which navigation it uses (no overlay
  list, no setting) is left alone rather than guessed at.
* **Your own choice is respected:** with the option off, the phone's navigation is
  not touched, and not even asked about.

### The Recents button, synced to this mode's list

> "Make shure that recent button of system 3-button navigation bar is sync with
> spsm recents such that i can easily switch to spsm's recent whenever I want
> like if I am using an app and I want to see recent."

Three things changed to make that true:

1. **The watcher now follows the phone, not the option.** If the phone is on
   three-button navigation — because this mode switched it, *or* because you
   chose it yourself with the option off — the daemon watches the event log and
   hands the launcher's recents screen over to this mode's list. On gesture
   navigation there is no Recents button, so nothing is watched.
2. **The handover is verified instead of assumed.** The list is started, then the
   screen is *read back* (`topResumedActivity`). If the phone put the launcher's
   recents screen up instead, that screen is stopped and the list is asked for
   again — up to three tries, a couple of seconds at worst. `am start` is a
   request, not a guarantee: a start that lands and is then covered up is exactly
   what "the button did nothing" looks like from the outside.
3. **A press that does not work is now readable in the log.** If the list cannot
   be put up, the line carries what `am start` answered
   (`recents: could not put SPSM's list up … am start said: …`). And a line about
   recents that the guard decides *not* to act on is written down once per burst
   (`recents-guard: a line about recents it did not act on: …`) — so the next log
   will say whether the button's press arrived, what it said, and what was done
   with it.

Also: one press is one handover. The event log carries the activity being created
*and* then resumed, which are two lines about the same press, and the guard acts
on the first.

### From your log — the four-minute step, and what else it showed

The log you sent had the answer to the slow activation in it:

```
apply rom_bg_off took 264s
rom background: 14 of the phone's own package(s) restricted for this idle period
```

Four minutes for fourteen packages, because every package was tested against the
protected lists with two `printf | grep` per test, and every value was read and
written one at a time. Two tests and three list lookups per package became **no
forks at all** (the sets are strings, tested with a shell `case`), and the writes
run together. The same step is now a couple of seconds.

The exit got the same treatment:

* **The daemon is stopped at the top of the exit**, not at the end. It was holding
  the transition lock against the exit — the log has
  `WARN lock timeout (held by pid …)` and a second of the exit spent waiting for a
  loop that was about to be stopped anyway.
* **`app_restrict` now releases its apps together** (the apply already did): a
  dozen apps, one after another, was eight seconds of the exit.
* **Independent values are written together** in every restore: a knob with six
  settings spent three seconds writing six settings that do not depend on each
  other, and there are a dozen such knobs.
* **The log no longer forks per line**: the size check (`wc`) ran on every single
  line of an activation; it runs every twentieth now.

The rest of the log was clean — `power-save on 2 of 2 cluster(s)` (both clusters
took the governor this time), the deep phase applied, `revert clean in 3s` on the
way out, the launcher refreshed. Two things it names are now in this build's log
as well: `deep sleep: the phone has been told to go idle now`, and the honest
`app_restrict` note that the phone did not report its restrictions back.

### The two other projects, checked against this phone

Asked for, so here is what was actually decided rather than a list of features
copied across:

* **[Xtreme-Battery-Saver](https://github.com/Magisk-Modules-Alt-Repo/Xtreme-Battery-Saver)**
  (DethByte64, GPLv3) — a well-built module, and most of what it does this project
  already has: suspend/kill apps with allowlists (`block_other_apps` +
  `app_restrict`), power-save cores (`gov_powersave`, `cpu_offline_big`), forced
  doze (`deep_doze`), Wi-Fi off, GMS handling (`freeze_google`), event-driven
  behaviour (**stronger here**: real screen events from the app and a daemon,
  rather than a 3-second poll of its config). Its three genuinely different
  options are `low_ram`, `disable_cores=auto`, and process renicing:
  * `low_ram` is a boot property (`ro.config.low_ram`) — it needs a reboot to take
    effect and its own README warns of random reboots on some devices. Not
    suitable for a mode that must be reversible in one press.
  * `disable_cores` is `cpu_offline_big`, which this mode already has as a deep
    option, and the phones its README warns about are the ones where it is not
    reversible through a reboot — which is exactly why this project keeps the
    boot-time safety net instead.
  * **`handle_proc` (renice) is the one thing worth having** — it lowers the
    priority of leftover system processes instead of stopping them, so nothing is
    disturbed and nothing needs restoring when they die. It is left out of this
    build on purpose: with the governor, the frequency caps and the background
    restrictions already in place, it is a change whose benefit cannot be
    demonstrated on this phone, and this project does not ship options that
    cannot prove themselves. If you want it tried, the probe path
    (`engine.sh probe`) is where it would be measured first.
* **[Extreme-Battery-Saver-Magisk-Module](https://github.com/reiryuki/Extreme-Battery-Saver-Magisk-Module)**
  (reiryuki) — **not usable here, and deliberately not ported.** It is a port of
  Google's Flipendo app: it ships a prebuilt APK, patches `runtime-permissions.xml`
  and the framework's signature checks, and its own README requires Android 11–14
  *or* an AOSP-signed ROM with signature verification disabled on 15+. This phone
  runs Android 16 on AxionOS. Installing it would mean disabling platform
  signature verification to give a Google app system permissions — the opposite of
  this project's promise that a reboot or a flat battery can never leave the phone
  crippled, and something a phone in a power-saving mode is a bad place to
  experiment with. Its one idea that is relevant — "pause apps while battery saver
  is on" — is what `app_restrict` and `block_other_apps` already do, per app and
  reversible.

### Tests

Cases 73 (the phone's own navigation: applying it, both ways of refusing, the
phone already on three buttons, the option switched off, a phone that will not
say, and the round trip) and 77 (the Recents handover: by hand, the start refused,
a recents-shaped line that is not the screen, one press = one handover, live
through the daemon on a phone *you* put on three buttons, and no watcher on a
phone with no Recents button) are rewritten. Case 66 now fails if any of the
deleted bar comes back.

### How to check it on your phone

1. Install with the mode off, reboot, turn the mode on.
2. **Look at the bottom of the screen: the phone's own three buttons**, not this
   app's. Press **Recents** on the home screen and inside an app: this mode's list
   both times, with Clear all in its header.
3. **Turn the mode off**: your gesture bar should be back, and no bar of this
   app's should ever have appeared. The log says
   `nav: the phone's own navigation is back (overlay …gestural)`.
4. If the Recents button ever opens the launcher's recents screen instead, the log
   will now say which of the two it was — `could not put SPSM's list up … am start
   said: …` or `recents-guard: a line about recents it did not act on: …`. Send
   that line and it will be a one-line fix rather than a guess.
5. The activation and the exit should both be visibly shorter. The log prints
   `SPSM ON: N knobs applied in Ms` and `revert clean in Ms`.

### Files

* `release/Axion-SPSM-v3.6.1-RMX3430.zip` — the module: APK v3.6.1 (53), 33
  options.
  * size 1,694,628 bytes
  * sha256 `cb7f07ff32ea63cbfd859243b5ababf60b90d2df9ac1c53d121b2406277b8cb2`
  * md5 `4291dbb9065f146f7d0936d96864b978`
* Download: `https://github.com/Rocker14427c/AXION-BS/raw/v3.6.1/release/Axion-SPSM-v3.6.1-RMX3430.zip`
* Before it was packaged: the full suite ran **79 cases, 529 checks, 0 failed**,
  and the APK inside this zip was read with `tools/dexcheck.py` — it carries the
  current code and **no navigation-bar class at all**.
