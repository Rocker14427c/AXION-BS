# Session state - read this first

**v3.9.0 SHIPPED AND FIELD-MEASURED (2026-09-25, commit `ece2d15` on Rewrite):**
ON 67s -> 33s (with 21 knobs instead of 13 - the full emergency posture),
OFF 24-47s -> 21-24s across three cycles, `block_other_apps` 41s -> 7s, the
187-app release 14s -> 4s, deep phase 48s -> 38s (freeze switches last),
wake release 24s -> 20s (thaw first), `verify checked=27 drift=0` on every
cycle. The journal's false "no visible change" over 187 pm-confirmed
suspensions is gone (after-read built from pm's own record). Full tables and
anatomy: docs/RELEASE-v3.9.0.md. Device-side resolutions (sticky battery
saver = Android's own + PPM PWR_THRO; tunnel deaths = Data Saver blocking
Termux, now whitelisted both lists): docs/DEVICE-FINDINGS.md, 2026-09-25.

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
| repo | `Rewrite` at `ece2d15` (v3.9.0 code+tests) + docs commit on top |
| GitHub release | v3.8.2 published; **v3.9.0 zip built via `tools/makezip.sh`** (publish when the owner asks) |
| APK | `module/app/AxionSPSM.apk` unchanged this release (no app-side changes in v3.9.0); phone app **v3.8.4 (75)**, precision feature REMOVED (owner request), SPSM only |
| phone | scripts **v3.9.0** live in `/data/adb/spsm/scripts` + module dir (md5-matched, `state/script_version`=v3.9.0), module.prop v3.9.0/76; v3.8.2 scripts backed up at `/data/local/tmp/spsm382_scripts_backup`; config = max emergency posture (gov_powersave, wifi/bt/nfc off, brightness cap, 15s timeout, AOD/animations/blur off, fps cap, battery_saver, block knobs; retired cpu_offline_big/cap_always lines removed); Termux whitelisted in deviceidle + netpolicy (uid 10252); sticky battery saver cleared (`low_power=0 low_power_sticky=0`) |
| suites | **687/0 main (incl. new section 91), 252/0 codec, 22/0 install, 5/0 daemon** |
| connection | **Pinggy + gist endpoint**: fetch `https://gist.githubusercontent.com/Rocker14427c/a0ef0786c6474c07982a4a3c3b995322/raw/pinggy.txt` -> one `tcp://HOST:PORT`, rotates ~hourly; NEVER retry a dead host - re-fetch first. Sandbox helper: `/home/user/pinggy_connect.sh '<remote cmd>'` (re-fetches gist per run, DoH, edge-IP fallback); SSH password in `/home/user/.secrets/u0_a252_ssh_pass` (600). scp must target the Termux home (`/data/local/tmp` is not writable by u0_a252), then `su -c cp` into place |

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
