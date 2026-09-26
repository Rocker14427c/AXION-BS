# Session state - read this first

**CURRENT (2026-09-26): v3.10.0 committed on Rewrite = the measurement round +
gesture nav.** A sandbox rewind ate the session that built it; the work was
recovered from GitHub (`git reset --hard origin/Rewrite` after re-adding the
remote - `.git/config` does not survive snapshots). What is proven: suites
green (740 main / 95 sections, codec, install, daemon 19), gesturemon
semantics proven on the host, census measured on the phone (6,354 calls /
488s - the churn of per-app deep passes is THE cost). What is PENDING and was
never done: **on-phone deployment + benchmark round + the real-finger gesture
proof** (docs/RELEASE-v3.10.0.md keeps the honest ledger). The phone still
runs v3.9.0 scripts (field-measured: ON 33s/21 knobs, OFF 21-24s, drift=0).
The tunnel is DOWN (gist endpoint unregistered) - and after the owner's
Termux reinstall (F-Droid -> Play) BOTH whitelists must be re-checked: the
deviceidle entry dies with the uninstall, and the Data Saver whitelist was
UID-based (10252 may be stale). Full story: docs/ARCH-PERF-PLAN.md,
docs/RELEASE-v3.9.0.md, docs/RELEASE-v3.10.0.md.

NIGHT-2 (airplane) DONE and DECISIVE: radios-off drain = radios-on drain =
3.00%/6.8h ~26 mA. The floor is the PLATFORM, not the radios. 0-1% is physics-
impossible until the floor drops 3x. See docs/POWER-OVERNIGHT-2.md.

Toolchain that must be rebuilt after deep rewinds: `bash tools/ensure-jdk.sh`
(extracts /home/user/jdk4py.whl into sdk/jdk - snapshots cap near 128 MB and eat
the extracted tree), then `bash build.sh --bootstrap` (jars + toolchain.env),
always `JAVA_HOME=$PWD/sdk/jdk`. Zip-only builds need no JDK: `tools/makezip.sh`.

Last updated: 2026-09-25 ~08:30 UTC (this sandbox's clock) by the agent.

## The thing to know: this sandbox can rewind

A workspace snapshot was restored mid-session and the working tree came back **older than the
branch** (repo at `1f36d7d` while GitHub had `c967396`+, and `.tailscale-state` had vanished). The
recovery is always the same, and it works because every commit gets pushed:

```sh
cd /home/user/AXION-BS            # sandbox layout can change; find the clone first
git fetch https://github.com/Rocker14427c/AXION-BS.git Rewrite
git reset --hard FETCH_HEAD          # safe: the tree is byte-identical to the tip
```

Consequences to design around:

* **Keep nothing unpushed.** Commit and push each piece of work; a "I'll push it later" is how work
  gets lost here.
* **Keep state in non-hidden paths.** `/home/user/ts/state/` holds the Tailscale node state;
  `/home/user/.tailscale-state` did not survive and cost a re-login.
* Re-`chmod +x` after any restore: `chmod +x ~/.ssh/arena_agent* /home/user/ts/tailscale* build.sh tools/*.sh tools/remote/*.sh`.

## What is deployed where (as of this file)

| thing | state |
|---|---|
| repo | `Rewrite` at the v3.10.0 bump commit on top of `3ed7f10` (gesturemon ABI fix) |
| GitHub release | **v3.9.0 published** (field-measured daily round); **v3.10.0 published** from the recovered HEAD - measurement round + gesture nav, on-phone benchmark PENDING (ledger in its notes) |
| APK | `module/app/AxionSPSM.apk` unchanged since v3.8.4(75) on the phone; new since: `module/bin/spsm-tool.jar` (batch JVM) + `module/bin/*/spsm-gesturemon` (native, both ABIs) |
| phone | scripts **v3.9.0** live (field-measured, drift=0), max-emergency config armed; **v3.10.0 NOT yet deployed**; v3.8.2 backup at `/data/local/tmp/spsm382_scripts_backup`; AFTER THE TERMUX REINSTALL: re-verify `dumpsys deviceidle whitelist +com.termux` and the netpolicy UID whitelist (`pm list packages -U com.termux` -> `cmd netpolicy add restrict-background-whitelist <uid>`) before the next sleep test, else the tunnel dies at screen-off again |
| suites | **740/0 main (95 sections), codec, install, daemon 19/0** at HEAD |
| connection | **Pinggy + gist endpoint**: fetch `https://gist.githubusercontent.com/Rocker14427c/a0ef0786c6474c07982a4a3c3b995322/raw/pinggy.txt` -> one `tcp://HOST:PORT`, rotates ~hourly AND EXPIRES (free tier ~60min) - a dead hostname means the phone-side tunnel is down; only the owner can revive it (open Termux, start pinggy, the gist updates). NEVER retry a dead host - re-fetch first; >2 failures -> ask the owner. Sandbox helper: `/home/user/pinggy_connect.sh`; `sshpass` must be reinstalled after any sandbox restore (`sudo apt-get install -y sshpass`); the edge-IP cache `/home/user/.secrets/pinggy_edge_ip` must hold an IPv4 (no IPv6 route in the sandbox). SSH password in `/home/user/.secrets/u0_a252_ssh_pass` - if the owner re-setup Termux, confirm it still matches. scp targets the Termux home (`/data/local/tmp` is not writable by u0_a252), then `su -c cp` into place |

## Connecting to the phone

**Pinggy is the way (2026-09-25).** The owner publishes the CURRENT endpoint at the gist URL
(one `tcp://HOST:PORT` line). The sandbox helper does the whole dance per call:

```sh
/home/user/pinggy_connect.sh '<remote command>'    # ssh u0_a252@phone via the fresh endpoint
```

It re-fetches the gist on EVERY run (endpoints rotate ~hourly and a dead hostname NXDOMAINs -
never cache, never retry a dead host), resolves via DoH when the sandbox resolver fails, and
falls back to the edge IP with Host-header routing when DNS is hopeless. Password auth from
`/home/user/.secrets/u0_a252_ssh_pass` (mode 600; the GitHub token lives beside it in
`/home/user/.secrets/gh_token` - the owner was advised to rotate it after it transited a chat).

Root on the phone is `su -c "..."` inside the SSH session (KernelSU). scp lands in the Termux
home; `/data/local/tmp` is not writable by u0_a252, so installs go `scp ~/spsm390/ && su -c cp`.

The tunnel itself runs from Termux on the phone. It DIES during SPSM sleep unless Termux is
exempt from doze AND Data Saver (v3.9.0 field-tested both whitelists - see DEVICE-FINDINGS):
`dumpsys deviceidle whitelist +com.termux` and `cmd netpolicy add restrict-background-whitelist 10252`.
If the tunnel is dead anyway (screen-off froze it), only a phone-side wake revives it: ask the
owner; do not burn retries (more than two failures -> ask).

The old Tailscale route (tailscaled userspace + `~/.ssh/arena_agent2`) is kept in git history;
it needs the owner to approve a login URL again after every sandbox rewind, which is why Pinggy
replaced it.
as `u0_a252` on that host/port.

## Installing v3.8.2 on the phone

```sh
# stage the payload
D=/data/local/tmp/spsm382
ssh … 'su -c "mkdir -p $D"'
scp module/scripts/{knobs.sh,engine.sh,lib.sh} module/app/AxionSPSM.apk module/module.prop …:$D/
# deploy to BOTH copies (the running one and the module one service.sh re-publishes at boot)
ssh … 'su -c "sh /data/local/tmp/deploy-keep.sh $D"'
```

`tools/remote/deploy-keep.sh` does the copy, the `pm install -r`, the keep-list creation (never
overwriting an existing one) and the read-backs that prove each part landed.

## Where the project actually stands

* **Measured baseline:** 3.00 % over 6.7 h screen-off (180 mAh, 26.8 mA average), 98.1 % suspended,
  522 wakes, median awake episode 0.74 s. Target is 0–1 %/6.5 h. Details: `docs/POWER-OVERNIGHT-1.md`.
* **The finding that matters:** ~150 mAh of that night was spent *with the AP suspended* (22–24 mA) —
  the modem, the Wi-Fi association, the PMIC and DRAM. Zero wakeups would still cost ~2.5 %, so the
  suspended floor has to come down, not just the wakeup count. Also: the cell is weak
  (RSRP −104 dBm, SNR 4 dB) and that sets an environmental floor.
* **Next measurements:** the settling phase (88 mA for the first 41 minutes, a third of the night's
  energy); Wi-Fi-off-vs-on overnight (cellular stays up, so calls/SMS work); the platform floor with
  airplane mode (diagnostic only, with the owner's permission, never a shipped policy).
* **Open with the owner:** revoke the pasted PATs (`ghp_2cfM…` twice now); a deploy-key or Tailscale
  auth key would stop secrets going through chat.
