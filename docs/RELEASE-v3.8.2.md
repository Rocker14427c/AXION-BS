# Axion SPSM v3.8.2 (versionCode 73)

**The keep-alive round: an app this mode stopped can start again, and you choose which ones never stop.**

## Your messages had gone quiet, and the log explains it

The morning after the first overnight measurement, the phone was checked with the mode off — and
**173 packages were still force-stopped**, WhatsApp and the mail client among them. Nothing on
screen said so. The mail client had simply stopped receiving anything.

The cause is a difference the code had treated as a detail:

| what the mode did | how it comes back |
|---|---|
| `pm suspend` — freeze the app | the phone wakes it on the next push. `pm unsuspend` is the undo, and every exit path called it |
| `am force-stop` — stop the app | **nothing wakes it.** Android does not start a stopped package for a push, an alarm or a broadcast. Only a person opening it clears the state |

The second half had no inverse. The module's own comment assumed an app "simply starts again when it
is next opened", which is true for a game and wrong for anything that has to receive messages.

**Fixed:** the force-stopped set is written down as it happens (`state/stopped_by_us.tsv`) and
released with `pm unstop` on the way out — on the ordinary exit, in `six-restore`, and outside the
guard on the suspend record, because the sweep stops packages that record never names. The launcher
is deliberately not in the record: `home_swap` stops it and starts the mode's own home straight
back, so it is stopped-and-running rather than left stopped.

## Background apps — the section you asked for

The six slots already kept six apps alive. You asked for a place to say "these must keep running",
without a limit, and with calls and SMS never in question.

**New screen: Background apps** (the ✓ button on the home screen). Every installed app, tap to keep,
tap again to release. Kept apps are listed first and marked *kept awake*.

What being on that list means — it is honoured by all three of the things this mode does to an app:

* never **suspended**, so its pushes keep arriving;
* never **force-stopped**, so it is never left dead;
* never pushed to the *restricted* standby bucket, and its background-op is left alone.

Adding an app takes effect **at once**, not at the next screen-off: if the mode has that app frozen
or stopped right now, it is released there and then — you can watch it start working again.

**Calls and SMS do not need to be listed and cannot be broken.** They are protected by the phone's
own ROLES (dialer, SMS, emergency) — the same protection that has always been there — so they stay
reachable whatever the list holds. This screen is for the chat apps, the mail apps and everything
else whose messages must not go quiet.

The list is yours, not session state: it survives an exit, a reboot and a re-flash of the module.
Under the hood it is `/data/adb/spsm/keep_awake.txt`, and the same thing is available from a shell:

```
sh /data/adb/spsm/scripts/engine.sh keep list
sh /data/adb/spsm/scripts/engine.sh keep add com.whatsapp
sh /data/adb/spsm/scripts/engine.sh keep remove com.whatsapp
```

## Measured, not assumed

* a kept app is never suspended, never force-stopped and never bucket-restricted, while an app not on
  the list still is — asserted in the test suite;
* `keep add` on an app that is frozen **and** stopped releases both immediately — the unsuspend and
  the `pm unstop` are asserted;
* the list survives an exit, because it is a choice and not session state — asserted;
* the exit releases every app it stopped, and clears its own record so no later exit frees a stop
  that was never ours — asserted.

Suite: **661 passed, 0 failed**; codec 252 checks, 0 failed.
