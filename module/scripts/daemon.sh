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
_nap_ok=''
nap() { # nap seconds - interruptible, forkless for whole seconds
  case "$1" in
    ''|*[!0-9]*) sleep "$1" & wait $!; return 0 ;;
  esac
  if [ -n "$_nap_ok" ]; then
    IFS= read -r -t "$1" _napc <&3 2>/dev/null
    return 0
  fi
  sleep "$1" &
  wait $!
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
  printf '%s %s\n' "$_lvl" "$(date +%s)" > "$STATE/drain_mark" 2>/dev/null
}

drain_report() { # drain_report - say what the sleep cost
  [ -f "$STATE/drain_mark" ] || return 0
  _then=$(cat "$STATE/drain_mark" 2>/dev/null)
  rm -f "$STATE/drain_mark"
  _l0=$(echo "$_then" | awk '{print $1}')
  _t0=$(echo "$_then" | awk '{print $2}')
  _l1=$(battery_level)
  _t1=$(date +%s)
  [ -n "$_l0" ] && [ -n "$_l1" ] && [ -n "$_t0" ] || return 0
  _mins=$(( (_t1 - _t0) / 60 ))
  _drop=$(( _l0 - _l1 ))
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
fi

# TERM is how this loop is stopped when the mode is switched off, and a shell
# that traps TERM carries on running unless the handler says otherwise - so this
# one exits.
trap 'exit 0' TERM INT

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

while true; do
  ticks=$((ticks + 1))
  if [ ! -f "$ACTIVE" ]; then
    log "daemon: mode is off, exiting"
    break
  fi
  if [ -f "$STATE/request_deactivate" ]; then
    log "daemon: deactivate requested"
    sh "$SCRIPT_DIR/engine.sh" deactivate >>"$LOG" 2>&1
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
      off_since=$(date +%s)
      # Detached on purpose. Run inline, the deep phase held this loop for as
      # long as it took - seven minutes on the owner's phone - and starved
      # the one-minute core timer of the very minute that is its point. The
      # child runs on its own now; the loop keeps ticking, the timer fires on
      # schedule, and a wake is answered the moment it happens.
      sh "$SCRIPT_DIR/engine.sh" screen-off >>"$LOG" 2>&1 &
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
      until sh "$SCRIPT_DIR/engine.sh" screen-on >>"$LOG" 2>&1; do
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

  # Awake: react to the power button within a second, because the caps being
  # held for even a moment while somebody is using the phone is the difference
  # between this mode and treacle. Asleep: 3s, which still catches a wake long
  # before the phone is in anyone's hand.
  if [ "$now" = "on" ]; then nap 1; else nap "$_ASLEEP_NAP"; fi

  # The owner's minute timer: once the screen has been off for a whole minute
  # of continuous sleep, cores 2-7 go to sleep until the next wake (the
  # cores_sleep option). The firing lives here rather than in the deep phase
  # because the whole point is the wait - and engine.sh core-sleep re-checks
  # the mode, the screen and the journal under the lock before it takes a
  # core, so a wake that lands during the firing simply wins. The date fork
  # below runs once a minute of sleep, not once a tick.
  if [ "$now" = "off" ] && [ "$off_since" != 0 ] \
     && [ $((ticks % _CORES_EVERY)) -eq 0 ] \
     && [ ! -f "$STATE/cores_asleep" ] \
     && [ "$(date +%s)" -ge "$((off_since + _CORES_AFTER))" ] \
     && knob_enabled cores_sleep "$(knob_default cores_sleep)"; then
    : > "$STATE/cores_asleep" 2>/dev/null
    sh "$SCRIPT_DIR/engine.sh" core-sleep >>"$LOG" 2>&1 &
  fi

  # The heartbeat. While asleep it is the proof that the mode is awake and
  # watching even though nothing is happening - three minutes of silence and the
  # line says the screen is off, the caps are in place, and this process is the
  # one that says so.
  if [ "$HEARTBEAT_TICKS" -gt 0 ] 2>/dev/null && [ $((ticks % HEARTBEAT_TICKS)) -eq 0 ]; then
    log "daemon alive: panel=${PANEL:--} state=$now deep=$(deep_word) caps_little=$(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) ticks=$ticks"
  fi
done

echo "daemon exiting" >>"$LOG" 2>/dev/null
