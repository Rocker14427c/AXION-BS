#!/system/bin/sh
# arm-tonight.sh -- run a measurement unattended at a wall-clock time, then put
# the phone back so the owner wakes up to working calls and a reachable device.
#
#   usage: arm-tonight.sh <target_epoch> <hard_deadline_epoch> <variant> <window_s>
#
# Why this wrapper exists beside the harness:
#
#   1. TIME. It is armed hours early and `sleep` is CLOCK_MONOTONIC - it stalls
#      while the phone is suspended, so plain sleeps would fire hours late. The
#      RTC wakealarm is set for the start (the SoC wakes even from deep suspend)
#      and the wall clock is re-checked every cycle, so ordinary maintenance
#      wakeups work as backups to the RTC.
#
#   2. SURVIVAL. idleexp.sh deliberately kills every Termux process (footprint
#      removal) and holds no wake locks. This wrapper lives outside all of that:
#      its command line contains no com.termux path, so the footprint sweep does
#      not touch it, and it is plain userspace so it never blocks suspend.
#
#   3. PROMISES. Whatever the harness does, the morning must arrive with calls
#      and SMS working (airplane back to its original state), sshd listening
#      again, and the endpoint tunnel relaunched exactly as the owner runs it.
#      The hard deadline reaches even a wedged harness: TERM triggers the
#      harness's own restore trap; SIGKILL is followed by enforcement here.
D=/data/local/tmp
IDLE=$D/idleexp.sh
LOG=$D/arm-tonight.log
TARGET=$1; DEADLINE=$2; VARIANT=$3; WIN=$4
[ -n "$TARGET" ] && [ -n "$DEADLINE" ] && [ -n "$VARIANT" ] && [ -n "$WIN" ] || {
  echo "usage: arm-tonight.sh <target_epoch> <deadline_epoch> <variant> <window_s>" >&2; exit 2; }
echo "$(date '+%F %T') armed: target=$TARGET deadline=$DEADLINE variant=$VARIANT window=${WIN}s" >> "$LOG"

# The start alarm, then the wait. A suspended phone freezes this loop mid-sleep;
# the RTC wakes it at TARGET and the next re-check passes.
echo "$TARGET" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null \
  && echo "$(date '+%F %T') rtc wakealarm set for $TARGET" >> "$LOG" \
  || echo "$(date '+%F %T') rtc wakealarm unavailable - relying on maintenance wakeups" >> "$LOG"
while [ "$(date +%s)" -lt "$TARGET" ]; do sleep 20; done
echo "$(date '+%F %T') firing" >> "$LOG"
echo "$DEADLINE" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

sh "$IDLE" "$VARIANT" "$WIN" 1800 150 15 >> "$LOG" 2>&1 &
IP=$!
while kill -0 "$IP" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "$(date '+%F %T') hard deadline - signalling the harness (its TERM trap restores the phone)" >> "$LOG"
    kill "$IP" 2>/dev/null; sleep 8; kill -9 "$IP" 2>/dev/null
    break
  fi
  sleep 30
done
wait "$IP" 2>/dev/null

# ---- the morning contract, enforced independently of the harness ----
. "$D/ie-orig.env" 2>/dev/null
if [ "${ORIG_APLANE:-0}" != "1" ]; then
  settings put global airplane_mode_on 0 >/dev/null 2>&1
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
  sleep 3
  echo "$(date '+%F %T') airplane enforcement: read-back $(settings get global airplane_mode_on 2>/dev/null)" >> "$LOG"
fi
echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

# sshd: the harness stops it as footprint (an ssh session holds a Termux wake
# lock that would invalidate the run). Restart it as the Termux user - su can
# drop to that uid here (verified), and the daemon picks up the same
# authorized_keys the owner's own sshd uses.
if ! pgrep -f "sshd" >/dev/null 2>&1; then
  su 10252 -c '/data/data/com.termux/files/usr/bin/sshd' >/dev/null 2>&1 \
    && echo "$(date '+%F %T') sshd restarted as uid 10252" >> "$LOG" \
    || echo "$(date '+%F %T') sshd restart FAILED - owner must open Termux" >> "$LOG"
else
  echo "$(date '+%F %T') sshd already running" >> "$LOG"
fi

# The endpoint tunnel, exactly as the owner runs it (captured at arm time in
# publisher.cmd). Only if it is really gone: his own automation may have beaten
# us to it, and two forwards would fight over the gist.
if [ -s "$D/publisher.cmd" ] && ! pgrep -f "a.pinggy.io" >/dev/null 2>&1; then
  su 10252 -c "cd /data/data/com.termux/files/home && nohup $(cat "$D/publisher.cmd") >$D/publisher.out 2>&1 &" >/dev/null 2>&1
  sleep 5
  pgrep -f "a.pinggy.io" >/dev/null 2>&1 \
    && echo "$(date '+%F %T') publisher relaunched" >> "$LOG" \
    || echo "$(date '+%F %T') publisher relaunch FAILED - owner must open Termux" >> "$LOG"
else
  echo "$(date '+%F %T') publisher left alone (running already, or no saved command)" >> "$LOG"
fi

echo "$(date '+%F %T') arm-tonight done - the phone is yours" >> "$LOG"
notify_owner() { timeout 20 cmd notification post -S bigtext -t "$1" spsm "$2" >/dev/null 2>&1; }
notify_owner "Measurement finished" "The phone is yours again - radios are back. Results are in /data/local/tmp/ie.out"
exit 0
