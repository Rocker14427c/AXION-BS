# Axion SPSM v3.7.5 (versionCode 63)

**The options, rebuilt around what you asked — one hand on the CPU, the GPU always at its floor, and the core sleep you designed.**

## What you asked for, and what changed

You told me the Processor options were impossible to tell apart — and you were
right, because three of them were the same lever under different names. Your
asks, in your words:

> "I really want that gpu stay at minimum frequency no matter screen is on or off"
> "some option make cpu to cap maximum at 1100mhz which i don't want... remove that
> option or simply that part from the option"
> "apply just powersave governer manage cpu frequencies itself no need to worry,
> all the time is good enough whether screen is on or off"

So:

- **"Power-save governor, always"** — the kernel's powersave governor holds
  every CPU core at its lowest speed for as long as the mode is on,
  **screen on and off**. It is now the **only** thing that manages CPU speed.
- **"Graphics at minimum, always"** — the GPU stays at its floor the whole
  time the mode is on, **screen on and off**.
- **Removed: "Limit the processor while asleep"** — this was the 1100 MHz cap
  (it wrote `scaling_max_freq` = 1100000 on the little cluster, 1300000 on the
  big one, and with "Keep power limits" it held them while you used the
  phone). No frequency ceiling is ever written by hand now.
- **Removed: "Keep the processor in Low Power mode"** — the platform's Low
  Power mode is a speed limit like the cap (and it could pin a cluster's
  governor against the powersave governor). This module never writes the power
  mode node at all now — if something else set it, it stays exactly as they
  left it.
- **Removed: "Keep power limits while using the phone"** — it existed only to
  keep the caps on while you use the phone. There are no caps; "always" is
  what the two remaining options mean by themselves.

## New option: "Sleep cores 2 to 7 after a minute" (on by default)

Your design, exactly: when the screen goes off and you don't turn it back on
within **1 minute**, cores 2–7 switch off and **only cores 0 and 1 stay
awake**. The moment you turn the screen on, **every core comes back** — before
anything else runs, because six missing cores are the one thing you'd feel.

- The first minute of sleep belongs to whatever the phone is still finishing
  (the memory sweep, notifications in flight) — nothing is taken then.
- The timing is watched by the mode's own daemon (it re-checks that the mode
  is still on, the screen is still off, and nothing changed, before a single
  core is touched — a wake that lands during the firing simply wins).
- It fires once per sleep, and a crash or reboot can never leave cores asleep
  (the boot safety net brings them back).

## The Processor options now, in one line each

| Option | What it holds down | When |
|---|---|---|
| Power-save governor, always | the CPU's speed | the whole time the mode is on |
| Graphics at minimum, always | the GPU's speed | the whole time the mode is on |
| Stop performance boosts | touch/scroll speed spikes | while the screen is off |
| Sleep cores 2 to 7 after a minute | six of eight cores | after a minute asleep, until wake |

"Hand back background memory" stays what it was: RAM, not speed.

## Also

- A regression test now pins the v3.7.4 slot-swap fix: an app taken out of the
  six slots while you are using the phone is re-blocked at once.
- The Options screen regenerates itself from the same list the scripts run, so
  the removed switches disappear from the app on their own.

## Install

Same as every build: flash `Axion-SPSM-v3.7.5-RMX3430.zip` in ResukiSU (mode
off first), reboot. Reverting stays guaranteed, knob by knob.

## Harness

547 checks, 0 failed.
