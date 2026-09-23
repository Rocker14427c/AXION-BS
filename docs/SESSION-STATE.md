# Session state — read this first

Last updated: 2026-09-23 ~06:00 UTC (this sandbox's clock) by the agent.

## The thing to know: this sandbox can rewind

A workspace snapshot was restored mid-session and the working tree came back **older than the
branch** (repo at `1f36d7d` while GitHub had `c967396`+, and `.tailscale-state` had vanished). The
recovery is always the same, and it works because every commit gets pushed:

```sh
cd /home/user/work/AXION-BS
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
| repo | `Rewrite` at `416c910` (v3.8.2 zip committed on top of `7e88cb6`) |
| GitHub release | **v3.8.2** published; zip asset rebuilt with the drop_line fix (asset replaced) |
| APK | `module/app/AxionSPSM.apk` = v3.8.2 (73), 105 355 bytes, md5 `3deaffa2d0a568d8a3219c1e4af00fd5` |
| phone | scripts **v3.8.2 + drop_line fix** (frozen until after tonight run), app **v3.8.3 (74)** with precision battery live; keep-list empty |
| suites | 674/0 main, 252/0 codec, 22/0 install (single-entry remove now asserted) |
| connection | **Pinggy + gist endpoint**: fetch `https://gist.githubusercontent.com/Rocker14427c/a0ef0786c6474c07982a4a3c3b995322/raw/pinggy.txt` -> one `tcp://HOST:PORT`, rotates ~hourly; NEVER retry a dead host - re-fetch first |

## Connecting to the phone

1. Sandbox network needs one routable address (the interface is link-local only otherwise, and
   Tailscale's link monitor then reports *no network*, starts, and never asks for a login URL):
   `sudo ip addr add 10.77.0.21/24 dev eth0`
2. `tailscaled` (userspace networking; **no TUN, no root needed**):
   `/home/user/ts/tailscaled --tun=userspace-networking --state=/home/user/ts/state/tailscaled.state --socket=/home/user/ts/state/tailscaled.sock --port=41641 --socks5-server=localhost:1055 &`
3. `/home/user/ts/tailscale --socket=/home/user/ts/state/tailscaled.sock up --hostname=arena-sandbox`
   — prints an approval URL the first time only; the owner clicks it.
4. `status` → the phone appears as a peer. Then SSH through the userspace stack:
   `ssh -o ProxyCommand="/home/user/ts/tailscale --socket=/home/user/ts/state/tailscaled.sock nc %h %p" -i ~/.ssh/arena_agent2 u0_a252@<phone>`

The owner publishes the CURRENT endpoint at the gist URL above (one `tcp://HOST:PORT`).
After ANY ssh failure: re-fetch the gist, parse the new host/port, reconnect with `~/.ssh/arena_agent2`
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
