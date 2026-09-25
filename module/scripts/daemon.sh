#!/system/bin/sh
# Axion SPSM v3 - screen-aware loop.
#
# Why a daemon and not a one-shot: the expensive savings (doze, restricted
# standby buckets, CPU/GPU caps) should only exist while the phone is actually
# idle. Holding them while the screen is on is what made the old version feel
# like treacle and what pinned the little cluster at 500 MHz.
#
# Polling cheaply matters too: the backlight node is the source of truth on
# this device (0 with the screen off, 1..max while it is on), and it is read
# here with a redirection rather than a fork - no process is spawned to look at
# one number. `dumpsys` is never on this path.
#
# Poll rates are asymmetric on purpose: the screen being ON means the phone is
# paying full drain anyway, so a 1s tick buys an immediate reaction to the power
# button for nothing. While asleep the deep phase is already engaged and there
# is nothing to react to, only a wake to catch, so it drops to 3s - the app's
# signal (below) makes that immediate when the app is installed.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"
# The daemon shares the engine's own libraries (the option list to know what was
# asked for, the recents list for the task commands it serves), so it reads the
# same three files the engine does.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/knobs.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/recents.sh"

# The pid file is written here rather than by the caller: the daemon may be
# started through setsid, in which case the caller's $! is not the process that
# ends up running this loop.
printf '%s\n' "$$" > "$SPSM_DIR/daemon.pid" 2>/dev/null

last_state=""

# The core-sleep timer: how long the screen must stay off before cores 2-7
# sleep (the owner asked for a minute), and how long one asleep tick lasts.
# Both are ordinary config, so the test rig can run this same code in seconds.
_CORES_AFTER=$(cfg cores_sleep_after_secs 60)
_ASLEEP_NAP=$(cfg asleep_nap_secs 3)
_CORES_EVERY=$((_CORES_AFTER / _ASLEEP_NAP))
[ "$_CORES_EVERY" -lt 1 ] 2>/dev/null && _CORES_EVERY=1
off_since=0

# The backstop wait used when the monitor is supplying events. It must not be
# longer than the core-sleep delay, or a phone that goes quiet the moment the
# screen is off would have its cores put to sleep late - the one-minute promise
# is the feature. Half the delay guarantees a pass inside it whatever happens,
# and is still twenty times fewer wakeups than the poll it replaces.
_MON_NAP=$((_CORES_AFTER / 2))
[ "$_MON_NAP" -lt 1 ] 2>/dev/null && _MON_NAP=1
_MON_TICK_MAX=$(cfg monitor_tick_secs 30)
[ "$_MON_NAP" -gt "$_MON_TICK_MAX" ] 2>/dev/null && _MON_NAP=$_MON_TICK_MAX

# A plain `sleep` cannot be cut short, and waiting out a poll after the user
# presses the power button is the difference between "instant" and "why is my
# phone stuttering". Two things cut the wait short: the APK signals this process
# (SIGUSR1) when it hears about the change, and the short tick above means the
# poll alone is quick enough when the app is not installed or was force-stopped.
# Neither is trusted on its own - every tick re-reads the panel itself.
# The nap pipe: held open at both ends for the daemon's whole life, so a
# read on it can block without a writer ever closing it. Whole-second naps
# are a read with a timeout - ZERO forks, where `sleep` forked a process
# every single tick (one a second while you use the phone; ~86000 a day).
# A signal - the app's poke - interrupts the read, exactly as it killed the
# sleep. Fractional naps keep the old fork, which is fine: they are rare.
#
# The trap this fell into, and why the check below is not paranoia: opening the
# pipe is NOT proof that `read -t` waits on it. dash accepts `-t`, ignores it,
# and returns non-zero immediately - so on any ROM whose /system/bin/sh is that
# shell, every nap returned in microseconds and this loop became a busy spin at
# 100% of a core, for as long as the mode was on. Measured here before the fix:
# 5400 ticks in two seconds, where one a second is the design. That is the exact
# opposite of what a power-saving module is for, and nothing in the loop could
# notice it - the heartbeat counted ticks, and the ticks were flying by.
#
# So the capability is MEASURED once at startup rather than assumed: nap the
# pipe for one second and see whether a second actually passed. Only a shell
# that really blocks gets the forkless path; everything else keeps the `sleep`
# that has always worked. The probe costs one second, once, at daemon start.
#
# THE EVENT SOURCE, when this phone has one
# -----------------------------------------
# All of the above is still a POLL: the loop wakes up, looks at a number, and
# goes back to sleep, once a second, ~86,000 times a day. Every one of those is
# a timer the SoC has to come out of idle for, which is the exact cost this
# module exists to remove - and no shell can do better, because a shell has
# `sleep` and no way to WAIT on a kernel event.
#
# So that one job is given to a small native helper (native/spsm-screenmon.c)
# which blocks in epoll on the kernel's uevent socket and on the backlight
# attribute itself, and prints a line when something actually happens. The
# daemon reads those lines instead of counting seconds: ~2,880 timer wakeups a
# day instead of ~86,400, and a FASTER reaction to the power button, because an
# event arrives in microseconds where a poll arrives at the end of its second.
#
# It is strictly an optimisation. If the helper is missing, fails to start, or
# dies at any point, `nap` falls straight back to the sleep-based poll that has
# always worked - the loop's logic, its rules and its fallbacks are untouched,
# and every existing test still describes it.
_MON_PID=''
_mon_start() {
  [ -n "${SPSM_NO_SCREENMON:-}" ] && return 1
  # Published by publish_native() into $SPSM_BIN at install and at every boot,
  # for the ABI this phone proved it can run. The module tree is the fallback
  # for a run before any publish has happened (and for the test suite, which
  # points SPSM_BIN at its own copy).
  _mb="$SPSM_BIN/spsm-screenmon"
  [ -x "$_mb" ] || _mb="$SCRIPT_DIR/spsm-screenmon"
  [ -x "$_mb" ] || return 1
  # The monitor's own slow timer is the safety net behind the events; it is set
  # well above the old poll because it is no longer how a change is noticed.
  _mon_fifo="$STATE/monitor"
  rm -f "$_mon_fifo" 2>/dev/null
  mkfifo "$_mon_fifo" 2>/dev/null || return 1
  # Open BOTH ends before the helper is started, and hand it the already-open
  # descriptor rather than the path.
  #
  # The obvious version - start the child with `> "$_mon_fifo"`, then unlink the
  # fifo - is a race that silently disables the whole feature. The child's
  # redirection is performed by the forked shell AFTER the fork returns, so the
  # unlink can win; the child then creates a REGULAR FILE at that path and
  # writes its events into it forever. Everything looks healthy - the helper is
  # running, using no CPU, and the daemon is blocked on a real fifo - but the
  # two are attached to different inodes and not one event is ever delivered.
  # It cost an afternoon; the fix is to stop using the path as the rendezvous.
  #
  # fd 4 is opened read-write so the daemon holds the read end for its whole
  # life (the helper never sees a closed pipe between naps), and fd 5 is the
  # write end given to the child. The daemon closes 5 immediately afterwards:
  # if it kept it, the pipe could never reach EOF and a dead helper would look
  # like a quiet one.
  exec 4<>"$_mon_fifo" 2>/dev/null || { rm -f "$_mon_fifo"; return 1; }
  exec 5>"$_mon_fifo" 2>/dev/null || { exec 4<&-; rm -f "$_mon_fifo"; return 1; }
  # Now the path has no further job, and removing it keeps the state directory
  # clean and stops anything else opening it.
  rm -f "$_mon_fifo" 2>/dev/null
  # Through rp(), so a test tree's panel node is the one watched. stdin is
  # closed: the helper reads nothing, and leaving it attached to the daemon's
  # own input is how a child ends up competing for the daemon's events.
  # The third argument is the daemon's own asleep interval, so that a kernel
  # which never announces anything makes the monitor behave exactly like the
  # poll it replaced rather than three times faster.
  "$_mb" "$(rp "$BL_PATH")" "$(cfg monitor_tick_secs 30)" "$_ASLEEP_NAP" >&5 2>/dev/null <&- &
  _MON_PID=$!
  exec 5>&-
  # Publish the monitor's pid so the APK can poke IT as well as this daemon.
  #
  # This is not redundancy for its own sake. When the daemon is waiting on the
  # monitor's pipe it is blocked in read(), and whether a USR1 trap can break
  # that read is shell-dependent: dash returns from the read and runs the trap,
  # but bash restarts the read and the handler does not run until something
  # actually arrives on the pipe. Measured - a poke to a bash daemon blocked on
  # the pipe never returned at all.
  #
  # Signalling the monitor sidesteps the whole question: it wakes from epoll,
  # writes a line, and the pipe itself unblocks the daemon. The line is what
  # delivers the poke, not the signal, so it works the same on every shell.
  printf '%s\n' "$_MON_PID" > "$STATE/monitor.pid" 2>/dev/null
  return 0
}

_mon_alive() {
  [ -n "$_MON_PID" ] || return 1
  [ -d "/proc/$_MON_PID" ] || return 1
  return 0
}

_nap_ok=''
nap() { # nap seconds - interruptible, forkless for whole seconds
  case "$1" in
    ''|*[!0-9]*) sleep "$1" & wait $!; return 0 ;;
  esac
  # The event path: block until the monitor says something, or until the nap
  # would have expired anyway. Whatever it says, the caller re-reads the panel
  # itself - this only decides WHEN to look, never what the answer is, so a
  # helper that is wrong can cost a wasted look and nothing else.
  if _mon_alive; then
    if [ -n "$_nap_ok" ]; then
      # A working `read -t` is still used when there is one: it caps the wait
      # even if the monitor were to die mid-nap, without needing _mon_alive to
      # be re-checked here.
      IFS= read -r -t "$1" _napc <&4 2>/dev/null
    else
      # No usable timeout in this shell - and none needed. The monitor's timer
      # guarantees a line within its tick, so this blocks with no CPU and no
      # fork until either a real screen event or that backstop arrives. If the
      # monitor dies the pipe reaches EOF and the read returns at once, and the
      # loop's next _mon_alive check drops back to polling.
      IFS= read -r _napc <&4 2>/dev/null || _mon_recheck=1
    fi
    return 0
  fi
  if [ -n "$_nap_ok" ]; then
    IFS= read -r -t "$1" _napc <&3 2>/dev/null
    return 0
  fi
  sleep "$1" &
  wait $!
}

# Does `read -t` on the nap pipe actually wait? Answered by the clock, not by
# the exit status - a shell that ignores the timeout can return any status it
# likes, and the only honest question is whether time passed.
nap_probe() {
  [ -n "$_nap_ok" ] || return 1
  _np0=$(now_epoch)
  IFS= read -r -t 1 _napc <&3 2>/dev/null
  _np1=$(now_epoch)
  [ "$((_np1 - _np0))" -ge 1 ] 2>/dev/null && return 0
  return 1
}

# The point of the mode is the number, so the daemon measures it instead of
# asking anyone to trust a claim. The level is noted when the screen goes off
# and the difference is logged when it comes back on: /data/adb/spsm/drain.log.
battery_level() {
  has dumpsys || return 0
  dumpsys battery 2>/dev/null | sed -n 's/.*level: *\([0-9][0-9]*\).*/\1/p' | head -1
}

drain_note() { # drain_note - remember the level as the screen went off
  # One mark per sleep. If the state flaps (screen off, on, off again) the
  # measurement must still describe the whole time the phone was asleep, not
  # start over from whichever transition happened to be last.
  [ -f "$STATE/drain_mark" ] && return 0
  _lvl=$(battery_level)
  [ -n "$_lvl" ] || return 0
  printf '%s %s\n' "$_lvl" "$(now_epoch)" > "$STATE/drain_mark" 2>/dev/null
}

drain_report() { # drain_report - say what the sleep cost
  [ -f "$STATE/drain_mark" ] || return 0
  _then=$(cat "$STATE/drain_mark" 2>/dev/null)
  rm -f "$STATE/drain_mark"
  _l0=$(echo "$_then" | awk '{print $1}')
  _t0=$(echo "$_then" | awk '{print $2}')
  _l1=$(battery_level)
  _t1=$(now_epoch)
  [ -n "$_l0" ] && [ -n "$_l1" ] && [ -n "$_t0" ] || return 0
  _mins=$(( (_t1 - _t0) / 60 ))
  _drop=$(( _l0 - _l1 ))
  # A charging phone "drains" upward: the -60%/h this logged on 2026-09-25
  # while the phone sat plugged in is noise, not a measurement. A level that
  # came back up says nothing about what the sleep cost - stay quiet.
  [ "$_drop" -ge 0 ] || return 0
  if [ "$_mins" -ge 1 ]; then
    _rate=$(awk -v d="$_drop" -v m="$_mins" 'BEGIN { printf "%.2f", d * 60 / m }')
  else
    _rate="n/a"
  fi
  printf '%s screen off %s%% -> %s%% in %s min (%s%%/h)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$_l0" "$_l1" "$_mins" "$_rate" >> "$SPSM_DIR/drain.log" 2>/dev/null
  log "drain: $_l0% -> $_l1% in ${_mins}min (${_rate}%/h)"
}

# The flag matters as much as the signal: a poke can arrive while the engine is
# already working (turn the screen off, change your mind, turn it on again), and
# a trap is only delivered at the next command boundary. Remembering that it
# happened stops the loop from sleeping through a screen change it has not
# acted on yet.
poked=0
trap 'poked=1' USR1
log "daemon start (pid $$)"
# The nap channel (see nap above). If the pipe cannot be made - a read-only
# state dir, an old shell without <> - the nap quietly keeps forking sleep,
# which is the behaviour that always worked.
rm -f "$STATE/nap" 2>/dev/null
if mkfifo "$STATE/nap" 2>/dev/null && exec 3<>"$STATE/nap" 2>/dev/null; then
  _nap_ok=1
  # Opening it proved nothing (see nap_probe): confirm the shell really waits,
  # or fall back to sleep. Getting this wrong is a busy loop, so it is checked.
  if nap_probe; then
    log "daemon: forkless naps (this shell honours read -t)"
  else
    _nap_ok=''
    exec 3<&- 2>/dev/null
    rm -f "$STATE/nap" 2>/dev/null
    log "daemon: this shell ignores read -t - using sleep for naps"
  fi
fi

# The event source, if this build carries one and this kernel allows it.
#
# Note what this does NOT require: a shell with a working `read -t`. The monitor
# carries its own timerfd backstop, so it is guaranteed to emit a line every
# tick whether anything happened or not - which means a PLAIN BLOCKING read on
# its pipe already has a bounded wait built in. The timeout does not have to
# come from the shell, because the writer supplies it.
#
# That matters most exactly where the module hurt most: a ROM whose /system/bin/
# sh silently ignores `read -t` had no way to wait on anything and fell back to
# forking `sleep` forever (and, before the fix above, to a busy loop). Those
# shells now get the event path too, and it is the cheapest of the three.
if _mon_start; then
  # _MON_NAP is only an upper bound on one wait, not the wakeup rate: the loop
  # turns over whenever the monitor sends a line, so the daemon automatically
  # follows whatever rate the monitor has settled on (fast until this kernel's
  # events prove themselves, slow afterwards - see native/spsm-screenmon.c).
  log "daemon: screen events from spsm-screenmon (pid $_MON_PID) - waiting on events, backstop ${_MON_TICK_MAX}s"
else
  _MON_PID=''
  log "daemon: no event monitor - polling the panel (${_ASLEEP_NAP}s asleep, 1s awake)"
fi

# TERM is how this loop is stopped when the mode is switched off, and a shell
# that traps TERM carries on running unless the handler says otherwise - so this
# one exits.
#
# The monitor is ended with it. It belongs to this daemon - it writes into a
# fifo only this daemon reads - and a helper left running after its daemon has
# gone would hold that pipe against the next one and keep a process alive on a
# phone that thinks the mode is off. This is the ONLY TERM/INT trap in the
# file: setting a second one later would silently replace this handler and
# leak the monitor, which is how the first version of this change was wrong.
trap 'kill "$_MON_PID" 2>/dev/null; exit 0' TERM INT

# A mode that saves nothing and a mode that is not running look identical from
# the outside, which is a bad way to find out that a daemon died. Two things
# answer it: a heartbeat line every so many ticks, and the panel/marker evidence
# on every decision. Both are cheap - the heartbeat counter is an integer and the
# comparison is not even a fork.
HEARTBEAT_TICKS=$(cfg heartbeat_ticks 60)
ticks=0

# Whether the deep phase is in place, without touching the CPU nodes.
deep_word() {
  [ -f "$STATE/deep_report" ] && printf 'applied' || printf 'released'
}

# Every engine run below closes fds 3 and 4 (3<&- 4<&-).
#
# Those are the daemon's nap pipe and the monitor pipe, and a child inherits
# them. That is not merely untidy: an engine worker holding the read end of the
# monitor pipe COMPETES for its lines, and a single line delivered to the child
# instead of the daemon is a wakeup the daemon never sees. The symptom is a
# daemon that blocks for its full backstop while the monitor is chattering away
# once a second, and a screen change that lands seconds late. The engine has no
# use for either descriptor.
while true; do
  ticks=$((ticks + 1))
  if [ ! -f "$ACTIVE" ]; then
    log "daemon: mode is off, exiting"
    break
  fi
  if [ -f "$STATE/request_deactivate" ]; then
    log "daemon: deactivate requested"
    sh "$SCRIPT_DIR/engine.sh" deactivate >>"$LOG" 2>&1 3<&- 4<&-
    break
  fi

  # Read the panel, then let the one set of rules decide. Both steps only touch
  # variables - a tick costs a syscall, not two processes. A value that is not a
  # number means the node was unreadable this tick, and screen_decide falls
  # through to the other sources rather than trusting the last known state.
  panel_read
  screen_decide "$PANEL" "$last_state"
  now=$SCREEN_STATE
  if [ "$now" != "$last_state" ]; then
    # Say what decided, not just what was decided: this line is what tells a log
    # reader whether the panel answered or something else did.
    if [ -z "$last_state" ]; then
      log "daemon: screen is $now (panel=${PANEL:--} via $SCREEN_SRC marker=$(marker_word))"
    else
      log "screen $last_state -> $now (panel=${PANEL:--} via $SCREEN_SRC)"
    fi
    if [ "$now" = "off" ]; then
      off_since=$(now_epoch)
      # Detached on purpose. Run inline, the deep phase held this loop for as
      # long as it took - seven minutes on the owner's phone - and starved
      # the one-minute core timer of the very minute that is its point. The
      # child runs on its own now; the loop keeps ticking, the timer fires on
      # schedule, and a wake is answered the moment it happens.
      sh "$SCRIPT_DIR/engine.sh" screen-off >>"$LOG" 2>&1 3<&- 4<&- &
      drain_note
    else
      # Waking up is the moment that has to feel instant, so this runs before
      # anything else can delay it - six sleeping cores most of all, which is
      # why the marker is cleared before the engine is called.
      off_since=0
      rm -f "$STATE/cores_asleep"
      # The detached deep phase may still hold the lock; the wake waits for
      # its turn instead of giving up - thirty tries, minutes of patience,
      # and the cores marker is already gone so the timer cannot re-arm.
      _wk=0
      until sh "$SCRIPT_DIR/engine.sh" screen-on >>"$LOG" 2>&1 3<&- 4<&-; do
        _wk=$((_wk + 1))
        [ "$_wk" -ge 30 ] && break
        nap 3
      done
      if [ "$_wk" -gt 0 ]; then
        log "wake: waited for the deep phase to let go"
      fi
      drain_report
      _woke=yes
      [ "$_wk" -ge 30 ] && _woke=no
    fi
    # A wake that could not get the lock is not a wake yet: leave the believed
    # state as it was, so the next tick tries again.
    [ "${_woke:-yes}" = "yes" ] && last_state=$now
    # The transition itself takes time (the deep phase applies or releases), so
    # the world may have moved on while it ran. Re-read before sleeping.
    continue
  fi

  # Anything poked in while we were working means the screen changed again
  # already - re-check instead of sleeping through it.
  if [ "$poked" = "1" ]; then
    poked=0
    continue
  fi

  # How long to wait before looking again.
  #
  # Without an event source this is a POLL and the interval IS the reaction
  # time, so it is short: 1s awake (the caps being held for even a moment while
  # somebody is using the phone is the difference between this mode and
  # treacle) and 3s asleep.
  #
  # With the monitor running, the interval is no longer the reaction time - the
  # power button arrives as an event and cuts the wait short in microseconds -
  # so it becomes nothing but a backstop, and holding it short would keep
  # exactly the wakeups the monitor was added to remove. It is therefore
  # lengthened to the monitor's own tick, which is what turns ~86,400 wakeups a
  # day into ~2,880 without making anything slower. Every decision below is
  # unchanged: the panel is still re-read on every pass, whatever woke it.
  # No _nap_ok requirement here: nap() handles a shell without a working
  # `read -t` by blocking on the monitor's pipe instead, which is bounded by
  # the monitor's own timer. Demanding _nap_ok sent exactly those shells down
  # the polling branch below - so the monitor was started, and then never read
  # from, and the screen went back to being noticed by a `sleep` loop.
  if _mon_alive; then
    nap "$_MON_NAP"
  elif [ "$now" = "on" ]; then
    nap 1
  else
    nap "$_ASLEEP_NAP"
  fi

  # The owner's minute timer: once the screen has been off for a whole minute
  # of continuous sleep, cores 2-7 go to sleep until the next wake (the
  # cores_sleep option). The firing lives here rather than in the deep phase
  # because the whole point is the wait - and engine.sh core-sleep re-checks
  # the mode, the screen and the journal under the lock before it takes a
  # core, so a wake that lands during the firing simply wins. The date fork
  # below runs once a minute of sleep, not once a tick.
  #
  # The `ticks % _CORES_EVERY` throttle in front of the date fork only made
  # sense while every tick was the same length: it counted naps to work out
  # that a minute had passed. With the monitor running a tick is an EVENT, so
  # tick counting measures nothing, and the deadline has to be read from the
  # clock. That is one `date` per pass while asleep - and while asleep with the
  # monitor there are two passes a minute, not twenty, so the fork this
  # throttle was avoiding costs less than the throttle did.
  if [ "$now" = "off" ] && [ "$off_since" != 0 ] \
     && { _mon_alive || [ $((ticks % _CORES_EVERY)) -eq 0 ]; } \
     && [ ! -f "$STATE/cores_asleep" ] \
     && [ "$(now_epoch)" -ge "$((off_since + _CORES_AFTER))" ] \
     && knob_enabled cores_sleep "$(knob_default cores_sleep)"; then
    : > "$STATE/cores_asleep" 2>/dev/null
    sh "$SCRIPT_DIR/engine.sh" core-sleep >>"$LOG" 2>&1 3<&- 4<&- &
  fi

  # The heartbeat. While asleep it is the proof that the mode is awake and
  # watching even though nothing is happening - three minutes of silence and the
  # line says the screen is off, the caps are in place, and this process is the
  # one that says so.
  if [ "$HEARTBEAT_TICKS" -gt 0 ] 2>/dev/null && [ $((ticks % HEARTBEAT_TICKS)) -eq 0 ]; then
    log "daemon alive: panel=${PANEL:--} state=$now deep=$(deep_word) caps_little=$(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) ticks=$ticks"
  fi
done

# The loop can also leave by `break` - the mode was switched off, or a
# deactivate was requested - and a break does not run the TERM trap. The
# monitor has to be ended on that path too, or switching the mode off would
# leave a helper process running against a daemon that no longer exists.
[ -n "$_MON_PID" ] && kill "$_MON_PID" 2>/dev/null
echo "daemon exiting" >>"$LOG" 2>/dev/null
