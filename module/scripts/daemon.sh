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
# The daemon is where the phone's own recents screen is watched for (the option
# list is needed to know whether three-button navigation was asked for, and the
# recents list to hand that screen over), so it reads the same three files the
# engine does.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/knobs.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/recents.sh"

# The pid file is written here rather than by the caller: the daemon may be
# started through setsid, in which case the caller's $! is not the process that
# ends up running this loop.
printf '%s\n' "$$" > "$SPSM_DIR/daemon.pid" 2>/dev/null

last_state=""

# A plain `sleep` cannot be cut short, and waiting out a poll after the user
# presses the power button is the difference between "instant" and "why is my
# phone stuttering". Two things cut the wait short: the APK signals this process
# (SIGUSR1) when it hears about the change, and the short tick above means the
# poll alone is quick enough when the app is not installed or was force-stopped.
# Neither is trusted on its own - every tick re-reads the panel itself.
nap() { # nap seconds - interruptible
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

# The Recents button, while the mode is on.
#
# With three-button navigation the Recents button is the phone's, and on this ROM
# it opens the launcher's own recents screen. That screen is watched for on the
# phone's own event log - the events buffer only, a trickle rather than the
# firehose of the main log buffer, because this runs on a phone whose whole point
# is not spending power - and every line that names it is handed to recents_guard,
# which opens this mode's list and takes the phone's screen down.
#
# The watcher is a child of this process: it is killed on the way out, and it
# also stops of its own accord the moment the mode is off (it checks the active
# flag on every line).
watch_recents() {
  has logcat || return 0
  log "recents: watching the phone's event log for its own recents screen"
  # Which screen the phone's Recents button opens, read once: it cannot change
  # while the mode is on, and asking per line would be a dumpsys per line. The
  # guard reads it from here and falls back to asking itself.
  RECENTS_HOST=$(host_recents_component 2>/dev/null)
  export RECENTS_HOST
  # -T now, and not the whole buffer.
  #
  # logcat prints what is already in the buffer before it follows, so the first
  # lines here can be from before the mode was ever switched on. The v3.6.1 log
  # has exactly that shape: the one recents line in a nine-hour session arrived
  # in the same second the daemon started, which is what a replayed old line
  # looks like - and it was answered with a handover for a press that had
  # happened while the phone was still in gesture navigation.
  logcat -b events -v brief -T "$(date '+%m-%d %H:%M:%S.000')" 2>/dev/null | while read -r _l; do
    [ -f "$ACTIVE" ] || break
    # Everything that mentions recents, in either spelling: the guard decides
    # what it is and writes down the ones it refuses, so a button that opens the
    # phone's recents screen can never fail silently here.
    case "$_l" in *ecents*|*ECENTS*) ;; *) continue ;; esac
    recents_guard "$_l"
  done
}

WATCH_PID=""
WATCH_TOUCH_PID=""
# Gated on what the phone is actually drawing, not on our own option: our
# option is what usually puts the phone on three buttons, but the user may
# equally have chosen it himself, and the button has to work either way. A phone
# on gesture navigation has no Recents button at all, so there is nothing to
# watch and nothing to hand over.
if [ "$(nav_now)" = three ]; then
  # Two watchers, because a button can be quiet in one of them and not the other.
  # The log says what the phone is doing; the touchscreen says what the finger
  # did. v3.6.1 had only the first and the phone never said anything - so the
  # second is the one that has to work, and the first is what makes the log
  # readable when it does not.
  watch_recents &
  WATCH_PID=$!
  recents_watch_touch &
  WATCH_TOUCH_PID=$!
  # "watching" is a promise, and a watcher that dies the second it starts has
  # broken it while the log still says it. The v3.6.2 device log said "watching"
  # and never another word: the awk between getevent and the handover buffered
  # every tap. This does not catch that case (the watcher lives, the pipe does
  # not), but it catches the other way a watcher dies - getevent unable to read
  # the touchscreen at all - and says so rather than leaving silence.
  sleep 2
  if ! kill -0 "$WATCH_TOUCH_PID" 2>/dev/null; then
    log "recents: the Recents button watcher died at once - getevent could not read the touchscreen"
  fi
fi

daemon_exit() {
  # The watchers are pipelines: killing the shell that runs the loop leaves the
  # producer (logcat, getevent) alive with nothing reading it - an orphan every
  # session, still listening. The children go first, then the shell itself.
  for _w in "$WATCH_PID" "$WATCH_TOUCH_PID"; do
    [ -n "$_w" ] || continue
    has pkill && pkill -P "$_w" 2>/dev/null
    kill "$_w" 2>/dev/null
  done
  return 0
}
# TERM is how this loop is stopped when the mode is switched off, and a shell
# that traps TERM carries on running unless the handler says otherwise - so this
# one exits after it has taken the watcher with it.
trap 'daemon_exit' EXIT
trap 'daemon_exit; exit 0' TERM INT

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
      sh "$SCRIPT_DIR/engine.sh" screen-off >>"$LOG" 2>&1
      drain_note
    else
      # Waking up is the moment that has to feel instant, so this runs before
      # anything else can delay it.
      sh "$SCRIPT_DIR/engine.sh" screen-on >>"$LOG" 2>&1
      drain_report
    fi
    last_state=$now
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
  if [ "$now" = "on" ]; then nap 1; else nap 3; fi

  # The heartbeat. While asleep it is the proof that the mode is awake and
  # watching even though nothing is happening - three minutes of silence and the
  # line says the screen is off, the caps are in place, and this process is the
  # one that says so.
  if [ "$HEARTBEAT_TICKS" -gt 0 ] 2>/dev/null && [ $((ticks % HEARTBEAT_TICKS)) -eq 0 ]; then
    log "daemon alive: panel=${PANEL:--} state=$now deep=$(deep_word) caps_little=$(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) ticks=$ticks"
  fi
done

echo "daemon exiting" >>"$LOG" 2>/dev/null
