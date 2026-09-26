#!/system/bin/sh
# Census runner - ONE full daily round with every service command shimmed,
# /proc/stat fork deltas per phase, and steady-state sampling through the
# sleep window. Read-only apart from the mode itself doing its normal work.
CDIR=/data/local/tmp/census
E=/data/adb/spsm/scripts/engine.sh
LOG=$CDIR/session.log
: > "$LOG"
export CENSUS_LOG="$LOG"
export PATH="$CDIR/shims:$PATH"

pforks() { awk '/^processes/ { print $2 }' /proc/stat; }
stamp() { date '+%H:%M:%S'; }

procstat() { # pid label
  [ -n "$1" ] && [ -d "/proc/$1" ] || return 0
  _s=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)
  _u=$(echo "$_s" | awk '{print $12}')
  _t=$(echo "$_s" | awk '{print $13}')
  v=$(awk '/voluntary_ctxt/ {print $2}' "/proc/$1/status" 2>/dev/null | tr '\n' ' ')
  echo "  $2 pid=$1 cpu_ticks(u=$u s=$_t) ctxt(vol nonvol)=$v"
}

getpid() { # name-grep
  ps -A -o PID,NAME 2>/dev/null | awk -v n="$1" '$2 ~ n { print $1; exit }'
}

echo "=== CENSUS $(stamp) ==="
F0=$(pforks); S=$(date +%s); sleep 10; F1=$(pforks)
echo "IDLE fork rate: $(( (F1 - F0) / 10 ))/s (system-wide baseline)"

echo "=== ACTIVATE ==="
F0=$F1; T0=$(date +%s)
sh $E activate; rc=$?
T1=$(date +%s); F1=$(pforks)
echo "ACTIVATE rc=$rc wall=$((T1 - T0))s forks=$((F1 - F0))"
DPID=$(cat /data/adb/spsm/daemon.pid 2>/dev/null)
MPID=$(cat /data/adb/spsm/state/monitor.pid 2>/dev/null)
APID=$(getpid dev.axion.spsm)
echo "pids: daemon=$DPID screenmon=$MPID app=$APID"
sleep 3
echo "GESTURE_MONITORS_now=$(dumpsys input 2>/dev/null | grep -c 'Gesture Monitor')"
echo "launcher3_procs=$(ps -A -o NAME 2>/dev/null | grep -c 'com.android.launcher3')"

echo "=== SCREEN OFF + 200s SLEEP WINDOW ==="
F0=$F1
input keyevent 26
sleep 20
i=0
while [ $i -lt 9 ]; do
  sleep 20; i=$((i + 1))
  FX=$(pforks)
  echo "--- t+$((20 + i * 20))s forks_delta=$((FX - F0)) online=$(cat /sys/devices/system/cpu/online) bl=$(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)"
  procstat "$DPID" daemon
  procstat "$MPID" screenmon
  procstat "$APID" app
  F0=$FX
done
F1=$(pforks)
echo "SLEEP_WINDOW total_forks=$((F1 - F0))"

echo "=== SCREEN ON ==="
F0=$F1; T0=$(date +%s)
input keyevent 26
sleep 20
T1=$(date +%s); F1=$(pforks)
echo "SCREENON_RELEASE wall=$((T1 - T0))s forks=$((F1 - F0))"

echo "=== RECENTS OPEN ==="
F0=$F1; T0=$(date +%s%N)
sh $E recents >/dev/null 2>&1; rc=$?
T1=$(date +%s%N); F1=$(pforks)
echo "RECENTS rc=$rc wall=$(( (T1 - T0) / 1000000 ))ms forks=$((F1 - F0))"

echo "=== ONE SET CALL ==="
F0=$F1; T0=$(date +%s%N)
sh $E set brightness_cap 8 >/dev/null 2>&1; rc=$?
T1=$(date +%s%N); F1=$(pforks)
echo "SET rc=$rc wall=$(( (T1 - T0) / 1000000 ))ms forks=$((F1 - F0))"

echo "=== DEACTIVATE ==="
F0=$F1; T0=$(date +%s)
sh $E deactivate; rc=$?
T1=$(date +%s); F1=$(pforks)
echo "DEACTIVATE rc=$rc wall=$((T1 - T0))s forks=$((F1 - F0))"

echo "=== SHIM LOG ==="
wc -l < "$LOG"
echo "=== done $(stamp) ==="
