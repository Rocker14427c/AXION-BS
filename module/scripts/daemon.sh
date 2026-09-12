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
    else
      # Waking up is the moment that has to feel instant, so this runs before
      # anything else can delay it.
      sh "$SCRIPT_DIR/engine.sh" screen-on >>"$LOG" 2>&1
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
