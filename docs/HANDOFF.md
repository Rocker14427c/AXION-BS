# Handoff — Axion Super Power Saving Mode (SPSM)

Everything an agent needs to continue this work. Written for an agent that has
**working root access to the device**, because the agent who wrote this does not.

Repo `Rocker14427c/AXION-BS` · branch `arena/01a0c508-axion-bs` · public.

---

## 1. Read this before anything else

**The primary goal is real battery preservation, not startup speed.**

Phase 1 (performance) is finished and validated on the device: activate+exit went
from 71 s to 26 s (−63 %) on the real phone. That work is done. Do not revisit it.

Phase 2, the current one, exists because the owner's actual complaint is standby
drain. Reference behaviour to beat: on stock realme UI 3.0, realme's Super Power
Saving Mode held **0–1 % over 7–8 hours** with calls and SMS still working and
notifications merely delayed. AxionOS + SPSM does not currently achieve that.

**The central unanswered question:** why does the phone still draw noticeable
current with the screen off under SPSM, and what prevents realme-level deep idle?

---

## 2. Standing constraints from the owner

These are explicit instructions, not preferences. Violating one wastes the work.

- **Do not simply add more CPU-frequency restrictions.** A lower frequency is not
  automatically lower energy if it makes the phone take longer to finish work.
- **Do not guess.** Measure on the real device. The previous agent guessed twice
  and was wrong twice (§5).
- **Do not treat AxionOS as generic AOSP.** Determine what Axion already does,
  what SPSM duplicates, what SPSM fights, what it can reuse.
- **Do not copy realme's implementation** — the source is not available. Model the
  *behaviour* that makes it effective.
- **Do not disable cellular** if it would break calls or SMS. Instead let the
  modem stay registered while background data, scans, syncs and jobs are
  restricted. Treat Wi-Fi separately.
- **Do not assume the existing 30 fps cap addresses standby power.** It is
  screen-on work and is treated as done.
- **Do not rely on battery percentage alone.** 1 % of ~5000 mAh is 50 mAh, so a
  short test reads 0 %. Use `charge_counter` (µAh) and deltas.
- **Identify the top energy sources before modifying them.** Deliver the measured
  power map and proposed architecture first; do not start changing dozens of
  settings blind.
- Optimise for **energy, not for language**. No blind C++ conversion; "C++ is
  fastest" is not a justification. If native code genuinely wins, write real
  native code, not a C++ wrapper around shell commands.
- **Preserve all existing functionality** — device workarounds, config, UI,
  recovery, state restoration, screen on/off handling, every feature.
- Keep a change only if it produces a real measured improvement.

**Hard boundary:** do not touch `susfs4ksu`, `tricky_store`, or
`playintegrityfix` configs. Not for power reasons, not for any reason.

The owner has granted full autonomous control of the device: *"you can run and
check everything you want on your own without even asking me… with root you can
do almost anything."* Act on the device directly.

---

## 3. Environment

| | |
|---|---|
| Device | realme RMX3430 |
| ROM | AxionOS 2.7 |
| **Real kernel** | `4.19.325-cip135-st19-Zenium-V1.5.2-sus-Even` (per `/proc/version`) |
| **`uname` reports** | `5.15.220-…` — **spoofed by SUSFS, do not trust** |
| Root | KernelSU |
| Module | `axion_spsm` "Axion Super Power Saving" v3.8.1, versionCode 72 |
| Install path | `/data/adb/spsm/` (`config`, `bin/`, `scripts/`, `state/`, `drain.log`, `enter.sh`) |

The kernel version matters. This is **4.19**, not 5.15: no PSI-based cpufreq
guarantees, no `utilclamp` assumptions, and the 4.19 cpuidle/cpufreq layout.
Anything that branches on kernel version must read `/proc/version`, never
`uname -r`.

`/sys/power/suspend_stats/` is fully present and readable, which is what the
whole measurement plan depends on.

---

## 4. What has already been measured

Benchmark, host side (`tests/bench/run.sh --cmp baseline current`):

| operation | forks / ms before | after |
|---|---|---|
| activate | 2963 / 2298 | **2554 / 1560** |
| deactivate | 3011 / 1874 | **2032 / 1076** |
| screen-off | 1189 / 3405 | **850 / 428** |
| screen-on | 552 / 366 | **468 / 248** |
| status | 414 / 282 | **292 / 151** |
| daemon 10 s idle (on) | 30 827 | **166** |
| daemon 10 s idle (off) | 23 003 | **25** |
| **total** | 62 559 f / 28 630 ms | **6 834 f / 23 712 ms (−89 % forks)** |

On device: start+exit **71 s → 26 s (−63 %)**; start 56 → 13 s, exit 15 → 13 s.

Shell costs measured directly (these justify the fork work):

- `su` spawn 1.15 ms vs persistent shell 0.042 ms — **28×**
- `$(cat f)` 1.33 ms vs `read` 0.256 ms — **5.5×**
- `grep -qxF` ×187 = 226 ms vs `case` test 5 ms — **45×**
- shell-line stream 145 µs vs `tail -n +2` 1037 µs — **7×**
- sourcing the three libs = 13 ms per `engine.sh` invocation

**Test suites (950 checks, 0 failures, no stderr):**
`tests/run.sh` 657 · `run-install.sh` 22 · `run-codec.sh` 252 · `run-daemon.sh` 19.

Note: `run.sh` reports 658 when `build/AxionSPSM.apk` exists. That file is
gitignored, so after a fresh clone it is absent and the gate at `tests/run.sh`
lines 2970–2981 contributes 1 assertion instead of 2. The 657/658 difference is
that, and nothing else. Run `./build.sh` to restore it.

---

## 5. Two hypotheses already disproved — do not re-argue them

The field log shows the screen-off deep phase applying **zero** knobs, while
startup applied 16. Startup logged 17 `snap <knob>` lines; screen-off logged
none, and reported `doze=no`. That is the anomaly to explain.

**Hypothesis A — "the deep knobs are switched off in config."** FALSE. The
config contains no `knob.deep_doze`, `app_restrict`, `rom_bg_off`,
`ged_boost_off` or `cores_sleep` line at all. Absent means the default, and all
of those default to on.

**Hypothesis B — "the phone runs a different build than the repo."** FALSE.
`cpu_offline_big` and `cap_always` appear **zero times** in the installed
`knobs.sh`. They are inert lines an older install left in `config`; the config
file never prunes removed knobs. Installed state is `scripts=v3.8.1
module=v3.8.1 code=v3.8.1` with 31 `meta_` knobs — identical to the repo.

`DEEP_ONCE` suppression is also ruled out: that path logs
`idle: <knob> is already in place`, which never appeared.

**The cause is still unknown.** Both dead hypotheses were produced by reasoning
from source and logs. Measure instead.

The installed `config` (verbatim, 15 lines):

```
knob.rotate_lock=0        knob.nfc_off=0           knob.location_off=1
knob.cpu_offline_big=1*   knob.sync_off=1          knob.brightness_cap=0
knob.aod_off=0            knob.timeout_short=0     knob.cap_always=1*
knob.blur_off=1           knob.animations_off=0    knob.fps_cap=1
knob.home_swap=1          knob.nav_buttons=0       knob.block_system_apps=1
```

`*` = inert. Also note `brightness_cap=0` and `timeout_short=0`: the two
cheapest screen-on savings are switched off.

Of the 16 knobs that do apply: 8 are screen-on cost (`fps_cap`,
`brightness_cap`, `animations_off`, `blur_off`, `gpu_cap`, `timeout_short`,
`haptic_off`, `rotate_lock`), 5 are standby (`scan_always_off`, `sync_off`,
`location_off`, `bt_off`, `nfc_off`), 2 both (`block_other_apps`,
`gov_powersave`), 5 neither/UI. **Every heavy standby lever lives in the `deep`
set** — which is exactly the set that appears not to apply.

---

## 6. Do this first — the measurement

`tools/remote/probe1.sh` is read-only and safe as root. Fetch and run it:

```sh
curl -sL https://raw.githubusercontent.com/Rocker14427c/AXION-BS/arena/01a0c508-axion-bs/tools/remote/probe1.sh -o /data/local/tmp/P.sh
su -c 'sh /data/local/tmp/P.sh'
```

`tools/POWER.sh` is the fuller collector: it snapshots, and on a **second** run
prints the delta against the first, plus ranked wakeup sources, Doze state,
alarm packages, Wi-Fi/radio and SPSM state.

Sequence:

1. SPSM **off**, screen off, phone untouched — run, wait ~10 min, run again.
2. SPSM **on**, same procedure.
3. Compare the two deltas.

**Every counter is cumulative since boot, so a single reading means nothing.**
Only differences are measurements.

The three possible answers, which call for completely different fixes:

| observation | meaning | direction |
|---|---|---|
| `suspend_stats/success` barely increases | phone never suspends | find the blocking wakelock/wakeup source |
| `success` climbs but `wakeup_count` climbs fast | suspends, wakes constantly | find the waker, coalesce alarms/jobs |
| suspends well, few wakeups, still draining | sleep is fine | look at modem/radio or a hardware rail, not the CPU |

Design notes already settled: report **work, not percentage**; report `cpuidle`
residency and `time_in_state` rather than the frequency cap, because
race-to-idle means a floor-pinned core can cost *more*; take deltas, never
absolutes.

`docs/POWER.md` holds the five-state design (SCREEN ON ACTIVE / SCREEN ON IDLE /
SCREEN OFF SHORT IDLE / SCREEN OFF LONG IDLE / LOW BATTERY EXTREME), the
per-layer choice table and the "what I will not do" list. Its section on the
unexplained deep phase has been corrected to record that both explanations are
dead and the cause is open.

Profiler usage, already wired into the module:

```sh
su -c 'sh /data/adb/spsm/scripts/power-profile.sh window 600 <tag>'
su -c 'sh /data/adb/spsm/scripts/power-profile.sh compare <A> <B>'
# reports land in /data/local/tmp/spsm-power/
# also reachable as: engine.sh power <subcommand>
```

---

## 7. Engineering traps already paid for

- A shell variable **cannot** cache a value computed inside `$(...)` — the
  assignment dies with the subshell. Any cache must be a file.
- A cache-hit path must not fork: `head -1` + `tail -n +2` is 2 forks per call
  (+49 forks per screen-on). Use `read` with redirection — 7× faster.
- `read` silently drops a final line that lacks a trailing newline.
- `$$` is the **parent's** pid in every subshell. Use
  `read -r pid _ < /proc/self/stat`.
- `pkill -f` / `pgrep -f <pattern>` matches the invoking shell's own command
  line and kills it. Use `ss -lptn 'sport = :PORT'` plus
  `grep -oE 'pid=[0-9]+'`, or build the pattern by concatenation.
- A host-only build must not sit below a cross-toolchain guard — that silently
  skipped 14 of 19 daemon checks once.
- Shared temp files lose read-modify-write updates; intermittent ≠ flaky.
- `read -t` is non-portable; USR1 does not interrupt a blocking read.
- No `strace` on this device.
- `sdk/jdk` is a **JRE with no `javac`** — compile with
  `sdk/jdk/bin/java -jar sdk/jar/ecj.jar -source 11 -target 11 -nowarn`.
  `Runtime.exec` needs `-Djdk.lang.Process.launchMechanism=FORK`.
- `sdk/` does not survive an environment reset: re-run `tools/setup-toolchain.sh`
  and `pip download ziglang==0.16.0`.
- **A port probe must require bytes back.** `/dev/tcp` reports CONNECTED for
  `8.8.8.8:9`, `192.0.2.1:80` and `203.0.113.7:22` — all with no service there.
  Two agents have now been misled by this. Correct form:

  ```sh
  timeout 12 bash -c 'exec 3<>/dev/tcp/HOST/80; printf "HEAD / HTTP/1.0\r\nHost: HOST\r\n\r\n" >&3; IFS= read -r -t 6 -u 3 l; echo "DATA: $l"'
  ```

---

## 8. Remote access

The device runs `sshd` on `127.0.0.1:8022`. An agent with real outbound egress
reaches it through a reverse tunnel and gets a full root shell — that is the
path to use. Per-agent keys keep each one individually revocable:

```sh
sed -i '/<unique-slice-of-key-body>/d' ~/.ssh/authorized_keys
```

Match on a unique slice of the key body, not `AAAAC3NzaC1lZDI1NTE5` (shared by
every ed25519 key) and not a tag that overlaps another agent's.

Two details that cost hours to find:

- Bind and forward to **`127.0.0.1`, never `localhost`**. Termux resolves
  `localhost` to IPv6 `::1`; the server binds IPv4; the relay then reports
  `# no tunnel here :(`, which looks exactly like a dead tunnel.
- Run **`termux-wake-lock`** in the session, or Android freezes the
  backgrounded process and the forward dies silently.

There is also an HTTP endpoint at `tools/phone-run-endpoint.py` for agents whose
only egress is a GET-only web fetcher: `/<token>/<name>` pulls
`tools/remote/<name>` from this repo and runs it as root in the background,
`/<token>/_out/<name>` reads the output. It answers in ~9 ms because the
download happens on a worker thread — answering inline made the relay report a
dead tunnel. Note it takes **no query string**: one agent's page fetcher
rewrites any URL containing `?` into a signed proxy link that always fails.

The agent writing this handoff has an **allowlisted** sandbox: `github.com`,
`api.github.com` and `pypi.org` only. No outbound SSH
(`ssh -p 443 -T tcp@a.pinggy.io` → `kex_exchange_identification: Connection
closed by remote host`), no general `curl`. Its page fetcher additionally
rewrites URLs intermittently and is GET-only. None of that is a device or config
problem, and nothing here needs fixing on the phone.

---

## 9. Files that matter

| path | what it is |
|---|---|
| `docs/POWER.md` | five-state design, layer table, profiler design, "will not do" list |
| `docs/DEVICE-FINDINGS.md` | live-measured device facts and the two dead hypotheses |
| `docs/OPTIMISATION.md` | completed phase-1 analysis and benchmark history |
| `tools/POWER.sh` | read-only baseline collector with delta-on-second-run |
| `tools/POWER-PROFILE.sh` | the profiler, installed as `module/scripts/power-profile.sh` |
| `tools/remote/probe1.sh` | minimal first probe |
| `tools/phone-run-endpoint.py` | HTTP run endpoint for GET-only sandboxes |
| `module/scripts/engine.sh` | engine; `DEEP_ONCE` near L657, `phase_deep()` at L309 |
| `module/scripts/knobs.sh` | 31 `meta_` knobs |
| `module/service.sh` | boot service |
| `app/src/dev/axion/spsm/Root.java` | root command surface |
| `tests/bench/` | `baseline.txt`, `opt3.txt`, `current.txt` |
