## Axion Super Power Saving v3.5.0 (versionCode 50)

**RMX3430 / AxionOS 2.7 (Android 16) / ResukiSU.** Switch the mode off before installing, then reboot.

Everything in this build answers your last message: the way into recents, the two things to take off the home screen, and the governor. The module's own log you sent found four more things, and they are fixed too.

### Recents: the swipe up, and nothing else

* The **Recents button is gone** from the power-saving home, exactly as you asked.
* The **long press on the empty space is gone** with it. There is no hidden way in and no button; the gesture is the way in.
* **Swipe up from the bottom edge** and SPSM's own recents opens — on the power-saving home screen, and from inside any app.
  * On SPSM's own screen the swipe is read directly (the bottom fifth of the screen, upward).
  * From **inside an app** that edge belongs to Android, not to us. But this mode's home *is* your phone's home while it is on, so the system answers that swipe with "go home" — and being sent home now opens the recents list instead of just redrawing the icons. That is the part that was doing nothing when you tried it.
  * Pressing **Back** out of an app still lands on the six apps, exactly as before.
* The list itself has one new control in the corner: a **home icon** that takes you back to the six apps. The X still closes the list.
* The screen no longer bounces: if the list is already open, being sent home again does nothing.

### The home screen

* The **percentage is gone**. The estimate — the line that says how long the phone has left — stays, in plain grey, a little larger than before.
* The **date under the clock is gone** too; the clock stands alone as the biggest thing on the screen.
* The **3×2 app grid has moved to the bottom**, directly above that estimate, with the black space above the clock where it belongs.
* The small hint under the apps now teaches the gesture: *Swipe up for recent apps*.

### The governor

You were right, and you proved it on the phone yourself: both halves of that loop — `powersave` on every core, and the phone's own `schedutil` back — take effect. So the idle frequency is the kernel's job now:

* New option **"Power-save governor while idle"**, on by default, sitting with the other processor options. While the screen is off it sets `powersave` on every cluster, and the **frequency ceilings are deliberately not written** — the governor holds every core at its lowest frequency continuously, which is the same saving done by the kernel instead of once from outside, and it is several fewer blocking writes per screen-off.
* The ceiling mechanism is untouched for everything else: while you are using the phone (and with *Keep power limits while using the phone*) the ceilings are still written exactly as before, because the governor is `schedutil` then.
* The idle report now says which of the two is holding the frequency: `held_by=governor` or `held_by=ceiling`.
* Your own commands are what this does, in the module's own hands: `echo powersave > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` while idle, and the phone's `schedutil` put back when you wake it.

### What your log found in the idle sequence

The v3.4.1 log named the slow steps itself. Four of them were doing work the phone had already done:

| in your log | now |
|---|---|
| `slow: apply deep_doze took 245s`, then `619s` | The command that asks the phone to go idle *waits for it to actually go idle*, which is why everything queued behind it. It is issued in the background with a ceiling of its own, and what the phone did with it is read back. |
| `slow: apply app_restrict took 86s`, then `89s`, in every screen-off | The per-app work runs together instead of one app at a time; the journal is written the same way, in the same order. |
| `slow: apply cpu_offline_big took 23s`, `52s` | A core that is already offline is left alone — re-asking for something that is already true was most of that wait. |
| the whole sequence repeating every screen-off | The background restrictions and the deep-sleep request are applied **once per idle period**. They cannot undo themselves while the phone sleeps, and waking clears the record, so a real wake re-applies both. |

Also from the log, the lines that read like faults but were not:

* `note rotate_lock: no visible change` — rotation was already locked. The note now says so.
* `note bt_off`, `note location_off` — both were already off. The note says so.
* `note statusbar_on: no visible change (optional node missing?)` — this ROM has no `policy_control` at all, so there was nothing to clear. The note says that instead.
* `note app_restrict`, `note deep_doze` — now say what the phone actually reports.

And one honest downgrade: **"Switch the launcher's recents off" is off by default** now. Your log has the module reporting *"this phone did not accept switching com.android.launcher3/com.android.quickstep.RecentsActivity off"* and putting it back — so every activation was spending seconds on a lever this ROM refuses. It stays in the option list with that sentence, for a ROM that accepts it.

### Not changed

No other option's default was touched, and nothing about what the mode does to the phone changed: the same journal, the same guaranteed revert, the same per-change opt-out.

### Files

`release/Axion-SPSM-v3.5.0-RMX3430.zip` — 1,680,153 bytes, sha256
`ad56b1e8ab805c00b1a181e7c96fe409c03b0143ddee6acc42d4c3539036747f`.
APK v3.5.0 (50), 30 options, suite 71 cases / 443 checks green, install test 22/0.
