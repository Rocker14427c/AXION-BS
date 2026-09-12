#!/system/bin/sh
# Axion SPSM v3 - screen-aware loop.
#
# Why a daemon and not a one-shot: the expensive savings (doze, restricted
# standby buckets, CPU/GPU caps) should only exist while the phone is actually
# idle. Holding them while the screen is on is what made the old version feel
# like treacle and what pinned the little cluster at 500 MHz.
#
# Polling cheaply matters too: the backlight node is a single small read, and
# the APK pushes the state instantly over a marker file, so this loop does not
# spin up `dumpsys` on every tick.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

last_state=""

# A plain `sleep` cannot be cut short, and waiting out an 8 second poll after
# the user presses the power button is the difference between "instant" and
# "why is my phone stuttering". The APK signals this process (SIGUSR1) the
# moment the screen changes; the wait below returns immediately and the loop
# re-reads the real state. The poll stays as the fallback for when the app is
# not installed or was force-stopped.
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
while true; do
  if [ ! -f "$ACTIVE" ]; then
    log "daemon: mode is off, exiting"
    break
  fi
  if [ -f "$STATE/request_deactivate" ]; then
    log "daemon: deactivate requested"
    sh "$SCRIPT_DIR/engine.sh" deactivate >>"$LOG" 2>&1
    break
  fi

  now=$(screen_state)
  if [ "$now" != "$last_state" ]; then
    log "screen $last_state -> $now"
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
  fi

  # Anything poked in while we were working means the screen changed again
  # already - re-check instead of sleeping through it.
  if [ "$poked" = "1" ]; then
    poked=0
    continue
  fi

  # Sleep longer while asleep: every wakeup is drain, and nothing needs the
  # caps re-asserted while the phone is idle.
  nap 8
done

echo "daemon exiting" >>"$LOG" 2>/dev/null
