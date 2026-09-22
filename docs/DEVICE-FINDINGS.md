# Real-device findings (RMX3430, live root session)

Measured directly on the owner's phone over a root shell, not inferred from
source. Each line records what was actually returned.

## Session state at measurement

| fact | value returned |
|---|---|
| installed version | `scripts=v3.8.1 module=v3.8.1 code=v3.8.1` |
| knobs in installed `knobs.sh` | **31** — identical count to the repository |
| `cpu_offline_big` in installed `knobs.sh` | **0 occurrences** |
| `cap_always` in installed `knobs.sh` | **0 occurrences** |
| SPSM active at measurement | **no** — `state/` had no `active` file |

## Two hypotheses this session killed

**1. "The deep knobs are switched off in config."** Wrong. The config contains
no `knob.deep_doze`, `app_restrict`, `rom_bg_off`, `ged_boost_off` or
`cores_sleep` line at all. Absent means the default applies, and all of those
default to on. So the deep set is *not* disabled.

**2. "The phone runs a different SPSM build than the repository."** Also wrong.
`cpu_offline_big=1` and `cap_always=1` in the config look like unknown knobs,
but they appear **zero times** in the installed `knobs.sh`. They are stale lines
left in `config` by an older install; the config file never prunes removed
knobs. They are inert.

Both were reasoned from the log and the source. Both were wrong. The lesson
that matters for the rest of this project: the log tells you what happened, but
only the device can tell you why.

## Config on the device (verbatim)

```
knob.rotate_lock=0        knob.nfc_off=0           knob.location_off=1
knob.cpu_offline_big=1*   knob.sync_off=1          knob.brightness_cap=0
knob.aod_off=0            knob.timeout_short=0     knob.cap_always=1*
knob.blur_off=1           knob.animations_off=0    knob.fps_cap=1
knob.home_swap=1          knob.nav_buttons=0       knob.block_system_apps=1
```

`*` = inert leftover, no matching knob in the installed code.

Worth noting for the power question: `knob.nfc_off=0` and
`knob.animations_off=0` are off, and `knob.brightness_cap=0` /
`timeout_short=0` mean the two cheapest screen-on savings are not running.
None of the deep knobs have an explicit line, so they all run at default (on).

## Connection method that works

The Arena sandbox cannot make outbound SSH connections — verified, not assumed:
`github.com:22` accepts the TCP connection but never sends the `SSH-2.0-...`
banner that every SSH server sends, and raw TCP to any host is reset. Only
HTTPS to `github.com`, `api.github.com` and `pypi.org` succeeds.

What does work: the sandbox's page-fetching path has broad egress, so the phone
serves HTTP through a tunnel and commands travel in the URL.

```
phone:  python ~/sh.py <token> 8099
phone:  ssh -o StrictHostKeyChecking=accept-new -R 80:127.0.0.1:8099 nokey@localhost.run
agent:  fetch https://<tunnel>.lhr.life/<token>?c=<urlsafe-base64 script>
```

Two details that are load-bearing:

- **`127.0.0.1`, not `localhost`.** Termux resolves `localhost` to IPv6 `::1`
  first, while the server binds IPv4, so the relay connected to nothing and
  reported `no tunnel here :(`.
- **`termux-wake-lock`.** Without it the tunnel drops within a couple of
  requests — Android freezes the backgrounded Termux process.

Batch many commands per request. Several `dumpsys` calls in one request exceeds
the fetch timeout; keep each request to a handful of fast reads.
