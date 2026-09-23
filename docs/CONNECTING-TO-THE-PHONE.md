# Reaching the owner's phone

Two ways. One is what we have been using; the other is the permanent answer, and it is already half
built.

## A. Pinggy reverse tunnel (what we have been using)

In Termux, on the phone:

```
sshd                                  # nothing listens without this - "Connection closed" means this
ssh -p 443 -R0:localhost:8022 tcp@a.pinggy.io
```

The phone prints a line like `tcp://<host>.run.pinggy-free.link:<port>`; the agent connects with
the key in `~/.ssh/arena_agent2` (chmod 600 after any environment reset).

Limits, all of them experienced rather than read:

* **60 minutes per session.** The session ends and the hostname stops resolving — with no warning.
* **A new hostname every time**, so the owner has to paste it again after each restart.
* The tunnel dies when Termux is frozen, and **the clean-measurement harness kills it on purpose**
  (an ssh session's wake lock blocks suspend and silently invalidates a run).
* `Connection closed by <ip> port <n>` right after connecting means sshd is not running, not that
  the tunnel is broken.

Good for: a working session where the owner is awake and watching.

## B. Tailscale (no limit, no pasting, survives screen-off)

Both ends join a private network. Once it is up, the agent reaches the phone at a fixed address for
as long as both are online — no hourly restart, no new hostname, and no tunnel process in Termux
holding the phone awake.

### Once, by the owner

1. Open the approval link the agent prints and sign in.
2. Install **Tailscale** on the phone (Play Store), sign in with the same account, switch it on.
3. Leave `sshd` running in Termux (Tailscale carries the connection; sshd is still what answers).

### Every session, by the agent

```sh
sudo ip addr add 10.77.0.21/24 dev eth0          # see the note below
mkdir -p ~/.tailscale-state
~/ts/tailscaled --tun=userspace-networking \
  --state=$HOME/.tailscale-state/tailscaled.state \
  --socket=$HOME/.tailscale-state/tailscaled.sock \
  --port=41641 --socks5-server=localhost:1055 &
~/ts/tailscale --socket=$HOME/.tailscale-state/tailscaled.sock status
```

Then reach the phone through the userspace stack — `tailscale nc` bridges stdin/stdout, which is
exactly what an SSH `ProxyCommand` wants:

```sh
ssh -o ProxyCommand="$HOME/ts/tailscale --socket=$HOME/.tailscale-state/tailscaled.sock nc %h %p" \
    -i ~/.ssh/arena_agent2 u0_a252@<phone-tailnet-name-or-100.x.y.z>
```

**The note on the address.** This sandbox's `eth0` carries only the link-local `169.254.0.21`, and
Tailscale's link monitor treats a link-local-only interface as *no network*: the daemon starts, then
sits at `SetNetworkUp(false)` and never asks the control plane for a login URL (`url=false` in its
log). Adding one routable address on the same interface is enough — `SetNetworkUp(true)`, and the
login proceeds. Egress is unaffected (verified: the sandbox's own outbound IP is unchanged).
The address does not survive a snapshot, so add it again at the start of each session; the Tailscale
state file does survive, so **no re-login is needed**.

### What to watch for

* **Battery.** WireGuard sends keepalives to hold the NAT mapping open — on the phone that is a
  periodic transmit, i.e. exactly the kind of wakeup the measurement work is trying to remove.
  Measure it before trusting it: a night with Tailscale on versus the known 3.00 % baseline. For a
  *measured* window, the cleanest thing is to switch the phone's Tailscale off (or have the harness
  do it), and leave it on the rest of the time.
* **It is a VPN on the phone.** Android shows it in the status bar. Nothing about calls or SMS
  changes, but the owner will see it, and that is reasonable — it says the agent can reach the phone.
* The agent's sandbox does not keep processes between turns either, so `tailscaled` is restarted
  at the start of a session like any other long-running helper.
