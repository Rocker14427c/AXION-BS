#!/system/bin/sh
# =============================================================================
# CLEAN screen-off C/D measurement, with the agent's own footprint removed.
#
# Why this exists: every previous screen-off number on this device was taken
# while a Termux tunnel held a PARTIAL_WAKE_LOCK, which prevents suspend
# outright (suspend_stats success stays 0). This run removes that footprint
# first and refuses to report if it cannot.
#
#   su -c 'setsid sh /data/local/tmp/cdclean.sh </dev/null >/dev/null 2>&1 &'
#
# Timeline (wall-clock):
#   0:00  log preconditions, log the wake locks held
#   0:00-2:30  GRACE - run `termux-wake-unlock` in Termux now, if you like
#   2:30  kill the tunnel (ssh/sshd); if a Termux wake lock is still held, kill
#         its holder. Verify. Log loudly if anything is left.
#   3:30  screen off
#   4:30  snapshot C1
#  14:30  snapshot C2   -> window C (10 min, screen off)
#  24:30  snapshot D2   -> window D (10 min more, screen off, deeper)
#  24:30  screen on, batterystats history captured, done
#
# Timeouts use wall-clock deadlines, NOT plain `sleep`: this kernel's sleep is
# CLOCK_MONOTONIC, which does not advance while suspended, so a plain 600s sleep
# on a phone that suspends 96% of the time would take ~4 wall-clock hours.
#
# Read-only apart from: the screen toggle, killing the agent's own processes,
# and the batterystats history capture.
# =============================================================================
OUT=/data/local/tmp/cd.out
D=/data/local/tmp
GRACE=150
SETTLE=60
C_WINDOW=600
D_WINDOW=600
: > "$OUT"; exec >> "$OUT" 2>&1

wait_until() { # wait_until <epoch>
  while [ "$(date +%s)" -lt "$1" ]; do sleep 20; done
}
in_seconds() { echo $(( $(date +%s) + $1 )); }

snap() { # snap <tag>
  _t=$1
  {
    echo "wall_epoch=$(date +%s)"
    echo "uptime_s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    echo "sus_success=$(cat /sys/power/suspend_stats/success 2>/dev/null)"
    echo "sus_fail=$(cat /sys/power/suspend_stats/fail 2>/dev/null)"
    echo "sus_last_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null)"
    echo "sus_last_errno=$(cat /sys/power/suspend_stats/last_failed_errno 2>/dev/null)"
    for f in charge_counter current_now voltage_now capacity status temp; do
      echo "bat_$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"
    done
    for c in cpu0 cpu6; do
      for st in 0 1; do
        _n=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/name 2>/dev/null)
        echo "idle_${c}_s${st}_${_n}_usage=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/usage 2>/dev/null)"
        echo "idle_${c}_s${st}_${_n}_time_us=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/time 2>/dev/null)"
      done
    done
    echo "cores_online=$(cat /sys/devices/system/cpu/online 2>/dev/null)"
    echo "mem_free_kb=$(awk '/^MemFree/{print $2}' /proc/meminfo 2>/dev/null)"
    echo "thermal_cur_power=$(sed -n 's/^current power = //p' /proc/ppm/policy/thermal_cur_power 2>/dev/null)"
    echo "wifi_rssi=$(dumpsys wifi 2>/dev/null | grep -o 'RSSI: [-0-9]*' | head -1)"
  } > "$D/cd-$_t.txt" 2>/dev/null
  cp /proc/interrupts "$D/cd-irq-$_t.txt" 2>/dev/null
  cp /proc/wakelocks "$D/cd-kwl-$_t.txt" 2>/dev/null
  echo "  [$1] $(date '+%T')  epoch=$(sed -n 's/^wall_epoch=//p' $D/cd-$_t.txt)  sus_success=$(sed -n 's/^sus_success=//p' $D/cd-$_t.txt)  charge=$(sed -n 's/^bat_charge_counter=//p' $D/cd-$_t.txt)  uA=$(sed -n 's/^bat_current_now=//p' $D/cd-$_t.txt)"
}

wakeups_now() { timeout 60 dumpsys batterystats --charged 2>/dev/null | sed -n '/All wakeup reasons/,/^$/p'; }
irq_delta() { # irq_delta <a> <b> <label>
  for f in /proc/interrupts; do :; done
  awk 'NR>1 {irq=$1; sub(":","",irq); c=0; nm="";
        for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/){c+=$i} else {nm=substr($0,index($0,$i)); break} }
        printf "%s\t%d\t%s\n", irq, c, nm}' "$D/cd-irq-$1.txt" 2>/dev/null | sort > "$D/ci-$1.tmp"
  awk 'NR>1 {irq=$1; sub(":","",irq); c=0; nm="";
        for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/){c+=$i} else {nm=substr($0,index($0,$i)); break} }
        printf "%s\t%d\t%s\n", irq, c, nm}' "$D/cd-irq-$2.txt" 2>/dev/null | sort > "$D/ci-$2.tmp"
  echo "  --- interrupts that fired, top 14 ---"
  awk -F'\t' 'NR==FNR{a[$1]=$2; next} {d=$2-(a[$1]+0); if (d>0) print d"\t"$1"\t"$3}' \
      "$D/ci-$1.tmp" "$D/ci-$2.tmp" 2>/dev/null | sort -rn | head -14
}
wake_delta() { # wake_delta <a> <b>
  awk 'NR>1 {print $1, $6, $7}' /dev/null >/dev/null 2>&1
  sed -n 's/^ *Wakeup reason \(.*\): .* (\([0-9]*\) times).*/\2|\1/p' "$D/cd-wake-$1.txt" 2>/dev/null | sort -t'|' -k2 > "$D/cw-$1.tmp"
  sed -n 's/^ *Wakeup reason \(.*\): .* (\([0-9]*\) times).*/\2|\1/p' "$D/cd-wake-$2.txt" 2>/dev/null | sort -t'|' -k2 > "$D/cw-$2.tmp"
  echo "  --- wakeup reasons that increased, top 12 ---"
  awk -F'|' 'NR==FNR{a[$2]=$1; next} {d=$1-(a[$2]+0); if (d>0) printf "%6d  %s\n", d, $2}' \
      "$D/cw-$1.tmp" "$D/cw-$2.tmp" 2>/dev/null | sort -rn | head -12
}
report() { # report <a> <b> <label>
  _a=$(sed -n 's/^wall_epoch=//p' "$D/cd-$1.txt" | head -1)
  _b=$(sed -n 's/^wall_epoch=//p' "$D/cd-$2.txt" | head -1)
  _w=$(( _b - _a ))
  echo
  echo "===== $3 ====="
  echo "  wall_window_s=$_w"
  for k in sus_success sus_fail; do
    _x=$(sed -n "s/^$k=//p" "$D/cd-$1.txt" | head -1)
    _y=$(sed -n "s/^$k=//p" "$D/cd-$2.txt" | head -1)
    printf "  %-14s +%s\n" "$k" "$(( _y - _x ))"
  done
  for c in cpu0 cpu6; do
    for st in 0 1; do
      _x=$(grep -m1 "^idle_${c}_s${st}_" "$D/cd-$1.txt" | grep -m1 '_time_us=' | cut -d= -f2)
      _y=$(grep -m1 "^idle_${c}_s${st}_" "$D/cd-$2.txt" | grep -m1 '_time_us=' | cut -d= -f2)
      _nm=$(grep -m1 "^idle_${c}_s${st}_" "$D/cd-$1.txt" | sed 's/^idle_[^_]*_s[0-9]_//; s/_time_us=.*//')
      _xu=$(grep -m1 "^idle_${c}_s${st}_" "$D/cd-$1.txt" | grep -m1 '_usage=' | cut -d= -f2)
      _yu=$(grep -m1 "^idle_${c}_s${st}_" "$D/cd-$2.txt" | grep -m1 '_usage=' | cut -d= -f2)
      if [ -n "$_x" ] && [ -n "$_y" ]; then
        _pct=$(awk "BEGIN{printf \"%.1f\", ($_y - $_x) / ($_w * 10000)}")
        printf "  idle %s %-6s: +%s entries, +%s ms, %.1f%% of the window\n" "$c" "$_nm" "$(( _yu - _xu ))" "$(( (_y - _x) / 1000 ))" "$_pct"
      fi
    done
  done
  _x=$(sed -n 's/^bat_charge_counter=//p' "$D/cd-$1.txt" | head -1)
  _y=$(sed -n 's/^bat_charge_counter=//p' "$D/cd-$2.txt" | head -1)
  printf "  drained_uAh=%s  (= %s%% of a 6000000 uAh battery; gauge resolution is 60000 uAh = 1%%)\n" "$(( _x - _y ))" "$(awk "BEGIN{printf \"%.2f\", ($_x - $_y)/60000}")"
  printf "  current_now_uA: %s -> %s\n" "$(sed -n 's/^bat_current_now=//p' "$D/cd-$1.txt" | head -1)" "$(sed -n 's/^bat_current_now=//p' "$D/cd-$2.txt" | head -1)"
  echo "  thermal_cur_power: $(sed -n 's/^thermal_cur_power=//p' "$D/cd-$1.txt" | head -1) -> $(sed -n 's/^thermal_cur_power=//p' "$D/cd-$2.txt" | head -1)"
  irq_delta "$1" "$2"
  wake_delta "$1" "$2"
}

echo "################ CLEAN C/D SCREEN-OFF RUN  $(date '+%F %T') ################"

echo; echo "===== PRECONDITIONS ====="
echo "  status=$(cat /sys/class/power_supply/battery/status) (must be Discharging)"
echo "  level=$(cat /sys/class/power_supply/battery/capacity)%  usb_online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)"
echo "  charge_counter=$(cat /sys/class/power_supply/battery/charge_counter)"
echo "  spsm_active=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )"
echo "  wake locks before:"
timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | head -8

echo; echo "===== GRACE ${GRACE}s: run 'termux-wake-unlock' in Termux now if you want a gentle release ====="
wait_until "$(in_seconds $GRACE)"

echo; echo "===== REMOVING THE AGENT'S FOOTPRINT ====="
# The tunnel: an ssh client speaking to the relay, plus the Termux sshd.
for p in $(ps -A -o PID,CMD 2>/dev/null | grep -E "pinggy|localhost\.run|ssh .*-R " | grep -v grep | awk '{print $1}'); do
  echo "  killing tunnel pid $p"
  kill -9 "$p" 2>/dev/null
done
pkill -9 -f "/data/data/com.termux/files/usr/bin/sshd" 2>/dev/null && echo "  sshd stopped" || echo "  (sshd not running)"

# A wake lock held by the Termux uid blocks suspend outright. Release it; if the
# holder cannot be talked out of it, take its process.
_wl=$(timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | grep -c "termux")
if [ "${_wl:-0}" -gt 0 ]; then
  _pid=$(timeout 40 dumpsys power 2>/dev/null | sed -n 's/.*termux.*pid=\([0-9]*\).*/\1/p' | head -1)
  echo "  a Termux wake lock is still held by pid ${_pid:-?} - killing that process to release it"
  [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
  sleep 5
fi
# Also stop anything else of ours that could hold the phone awake.
pkill -9 -f "com.termux" 2>/dev/null && echo "  (remaining com.termux processes cleared)" || echo "  (no com.termux processes left)"

sleep 20
echo; echo "===== WAKE LOCKS AFTER REMOVAL (must be empty or non-agent) ====="
timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | head -8
_wl2=$(timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | grep -c "termux")
if [ "${_wl2:-0}" -gt 0 ]; then
  echo "  !! STILL HOLDING A TERMUX WAKE LOCK - this window may not suspend. Reporting anyway."
else
  echo "  clean: no Termux wake lock is held, so suspend is unblocked"
fi
echo "  suspend counters now: success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"

echo; echo "===== SCREEN OFF ====="
input keyevent 26 2>/dev/null
wait_until "$(in_seconds $SETTLE)"
echo "  screen state per kernel: $(cat /sys/power/state 2>/dev/null | head -c 40)"

echo
echo "################ WINDOW C — SCREEN OFF, FIRST ${C_WINDOW}s ################"
snap C1
wakeups_now > "$D/cd-wake-C1.txt" 2>/dev/null
wait_until "$(in_seconds $C_WINDOW)"
snap C2
wakeups_now > "$D/cd-wake-C2.txt" 2>/dev/null
report C1 C2 "WINDOW C - screen off, first $((C_WINDOW/60)) min"

echo
echo "################ WINDOW D — SCREEN OFF, NEXT ${D_WINDOW}s (deeper) ################"
wait_until "$(in_seconds $D_WINDOW)"
snap D2
wakeups_now > "$D/cd-wake-D2.txt" 2>/dev/null
report C2 D2 "WINDOW D - screen off, next $((D_WINDOW/60)) min"

echo; echo "===== SCREEN ON ====="
input keyevent 26 2>/dev/null
echo "  screen timeout still: $(settings get system screen_off_timeout)"

echo; echo "===== BATTERYSTATS HISTORY (raw, for current sampling) ====="
timeout 90 dumpsys batterystats --history > "$D/cd-history.txt" 2>/dev/null
echo "  saved $(wc -l < $D/cd-history.txt) lines to /data/local/tmp/cd-history.txt"

echo; echo "===== FINAL ====="
echo "  sus_success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"
echo "  last_failed_dev=[$(cat /sys/power/suspend_stats/last_failed_dev)] errno=$(cat /sys/power/suspend_stats/last_failed_errno)"
echo "  charge_counter=$(cat /sys/class/power_supply/battery/charge_counter) capacity=$(cat /sys/class/power_supply/battery/capacity)%"
echo "  tail of /proc/interrupts saved for wlan0/ccci/silfp:"
grep -E "wlan0|ccci|silfp|touchpanel" /proc/interrupts 2>/dev/null | head -8
echo; echo "################ DONE $(date '+%F %T') — reopen Termux and restart the tunnel ################"
