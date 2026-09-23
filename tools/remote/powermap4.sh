#!/system/bin/sh
# =============================================================================
# Four-state real-device power map for the RMX3430.
#
#   su -c 'nohup sh /data/local/tmp/powermap4.sh on  </dev/null >/dev/null 2>&1 &'
#        -> state A (screen ON + user active) and state B (screen ON + idle)
#
#   termux-wake-unlock
#   su -c 'nohup sh /data/local/tmp/powermap4.sh off </dev/null >/dev/null 2>&1 &'
#        -> state C (screen OFF, first 10 min) and state D (screen OFF, next 10 min)
#           MUST be run with the tunnel down and the wake lock released, or it
#           measures the tunnel. See docs/POWER-ANALYSIS-2026-09-22.md.
#
# Read-only except for the screen-off timeout, which is saved and restored.
# =============================================================================
MODE=$1
OUT=/data/local/tmp/powermap4-$MODE.out
D=/data/local/tmp
A_WINDOW=${2:-300}
B_WINDOW=${3:-300}
C_WINDOW=${4:-600}
D_WINDOW=${5:-600}
: > "$OUT"; exec >> "$OUT" 2>&1

snap() { # snap <tag>
  _t=$1
  {
    echo "uptime_s=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)"
    echo "sus_success=$(cat /sys/power/suspend_stats/success 2>/dev/null)"
    echo "sus_fail=$(cat /sys/power/suspend_stats/fail 2>/dev/null)"
    echo "sus_last_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null)"
    for f in charge_counter current_now voltage_now capacity status temp; do
      echo "bat_$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"
    done
    _u=0; _tm=0
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/usage; do
      [ -f "$s" ] && _u=$(( _u + $(cat "$s" 2>/dev/null || echo 0) ))
    done
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/time; do
      [ -f "$s" ] && _tm=$(( _tm + $(cat "$s" 2>/dev/null || echo 0) ))
    done
    echo "cpuidle_usage_total=$_u"
    echo "cpuidle_time_us_total=$_tm"
    # per-cluster deep-state residency: cluster little = cpu0, big = cpu6
    for c in cpu0 cpu6; do
      for st in 0 1; do
        _n=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/name 2>/dev/null)
        _us=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/usage 2>/dev/null)
        _ts=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/time 2>/dev/null)
        echo "idle_${c}_s${st}_${_n}_usage=$_us"
        echo "idle_${c}_s${st}_${_n}_time_us=$_ts"
      done
    done
    echo "lowmem_free_kb=$(grep -m1 MemFree /proc/meminfo 2>/dev/null | tr -dc 0-9)"
    echo "thermal_cur_power=$(sed -n 's/^current power = //p' /proc/ppm/policy/thermal_cur_power 2>/dev/null)"
    echo "screen=$(cat /data/adb/spsm/state/screen 2>/dev/null)"
    echo "spsm_active=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )"
  } > "$D/pm4-$_t.txt" 2>/dev/null
  cp /proc/interrupts "$D/pm4-irq-$_t.txt" 2>/dev/null
  # top cpu consumers at the moment of the snapshot (for states A and B)
  ps -A -o %cpu,pid,cmd --sort=-%cpu 2>/dev/null | head -12 > "$D/pm4-ps-$_t.txt" 2>/dev/null
  echo "  snapshot $_t at $(date '+%T')  (sus_success=$(sed -n 's/^sus_success=//p' "$D/pm4-$_t.txt"))"
}

delta() { # delta <a> <b> <label> <window_seconds>
  echo
  echo "===== DELTA $3 ====="
  _a=$(sed -n 's/^uptime_s=//p' "$D/pm4-$1.txt" | head -1)
  _b=$(sed -n 's/^uptime_s=//p' "$D/pm4-$2.txt" | head -1)
  echo "  window_elapsed_s=$(awk "BEGIN{printf \"%.0f\", $_b - $_a}" 2>/dev/null)"
  for k in sus_success sus_fail cpuidle_usage_total cpuidle_time_us_total; do
    _x=$(sed -n "s/^$k=//p" "$D/pm4-$1.txt" | head -1)
    _y=$(sed -n "s/^$k=//p" "$D/pm4-$2.txt" | head -1)
    [ -n "$_x" ] && [ -n "$_y" ] && printf "  %-26s +%s\n" "$k" "$(( _y - _x ))"
  done
  for c in cpu0 cpu6; do
    for st in 0 1; do
      for kk in usage time_us; do
        _k="idle_${c}_s${st}_"
        _x=$(grep -m1 "^${_k}.*_${kk}=" "$D/pm4-$1.txt" 2>/dev/null | cut -d= -f2)
        _y=$(grep -m1 "^${_k}.*_${kk}=" "$D/pm4-$2.txt" 2>/dev/null | cut -d= -f2)
        _nm=$(grep -m1 "^${_k}.*_${kk}=" "$D/pm4-$1.txt" 2>/dev/null | sed 's/^idle_[a-z0-9]*_s[0-9]_//; s/_usage=.*//; s/_time_us=.*//')
        [ -n "$_x" ] && [ -n "$_y" ] && printf "  idle %s %s s%s %-6s +%s\n" "$c" "$_nm" "$st" "$kk" "$(( _y - _x ))"
      done
    done
  done
  _x=$(sed -n 's/^bat_charge_counter=//p' "$D/pm4-$1.txt" | head -1)
  _y=$(sed -n 's/^bat_charge_counter=//p' "$D/pm4-$2.txt" | head -1)
  [ -n "$_x" ] && [ -n "$_y" ] && printf "  drained_uAh=%s   (positive = discharged)\n" "$(( _x - _y ))"
  _x=$(sed -n 's/^bat_current_now=//p' "$D/pm4-$1.txt" | head -1)
  _y=$(sed -n 's/^bat_current_now=//p' "$D/pm4-$2.txt" | head -1)
  echo "  current_now_uA: $_x -> $_y   (negative = discharging)"
  _t=$(awk "BEGIN{print ($_b - $_a)/60}" 2>/dev/null)
  _d=$(( ${_y} - ${_x} ))
  echo "  --- hardware interrupts that increased (top 10) ---"
  awk -F'\t' 'NR==FNR{a[$1]=$2; next} {d=$2-(a[$1]+0); if (d>0) print d"\t"$1"\t"$3}' \
      /dev/null /dev/null >/dev/null 2>/dev/null
  awk 'NR>1 {irq=$1; sub(":","",irq); c=0; nm="";
        for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/){c+=$i} else {nm=substr($0,index($0,$i)); break} }
        printf "%s\t%d\t%s\n", irq, c, nm}' "$D/pm4-irq-$1.txt" 2>/dev/null | sort > "$D/i-$1.tmp"
  awk 'NR>1 {irq=$1; sub(":","",irq); c=0; nm="";
        for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/){c+=$i} else {nm=substr($0,index($0,$i)); break} }
        printf "%s\t%d\t%s\n", irq, c, nm}' "$D/pm4-irq-$2.txt" 2>/dev/null | sort > "$D/i-$2.tmp"
  awk -F'\t' 'NR==FNR{a[$1]=$2; n[$1]=$3; next} {d=$2-(a[$1]+0); if (d>0) print d"\t"$1"\t"$3}' \
      "$D/i-$1.tmp" "$D/i-$2.tmp" 2>/dev/null | sort -rn | head -10
  echo "  --- top cpu consumers during the window ---"
  head -8 "$D/pm4-ps-$2.txt" 2>/dev/null
}

restore_timeout() { settings put system screen_off_timeout "$SAVED_TIMEOUT" 2>/dev/null; }
SAVED_TIMEOUT=$(settings get system screen_off_timeout 2>/dev/null)
case "$SAVED_TIMEOUT" in ''|null) SAVED_TIMEOUT=60000 ;; esac

echo "################ FOUR-STATE POWER MAP mode=$MODE $(date '+%F %T') ################"
echo "screen_off_timeout_saved=$SAVED_TIMEOUT"
echo "wake locks held at start:"
timeout 30 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | head -6

if [ "$MODE" = on ]; then
  trap 'restore_timeout' EXIT
  settings put system screen_off_timeout 1800000 2>/dev/null

  # ---------------- STATE A: screen ON + user active ----------------
  echo
  echo "################ STATE A — SCREEN ON + USER ACTIVE (${A_WINDOW}s) ################"
  input keyevent 224 2>/dev/null
  sleep 3
  snap A1
  _end=$(( $(date +%s) + A_WINDOW ))
  while [ "$(date +%s)" -lt "$_end" ]; do
    input swipe 360 1200 360 500 200 2>/dev/null
    sleep 2
  done
  snap A2
  delta A1 A2 "STATE A - SCREEN ON + ACTIVE"

  # ---------------- STATE B: screen ON + idle ----------------
  echo
  echo "################ STATE B — SCREEN ON + IDLE (${B_WINDOW}s) ################"
  snap B1
  sleep "$B_WINDOW"
  snap B2
  delta B1 B2 "STATE B - SCREEN ON + IDLE"
  echo "(screen_off_timeout restored to $SAVED_TIMEOUT)"
else
  # ---------------- STATE C: screen OFF, first window ----------------
  echo
  echo "################ STATE C — SCREEN OFF, SHORT IDLE (${C_WINDOW}s) ################"
  input keyevent 26 2>/dev/null
  sleep 5
  snap C1
  sleep "$C_WINDOW"
  snap C2
  delta C1 C2 "STATE C - SCREEN OFF (first ${C_WINDOW}s)"

  # ---------------- STATE D: screen OFF, long idle ----------------
  echo
  echo "################ STATE D — SCREEN OFF, LONG IDLE (${D_WINDOW}s) ################"
  snap D1
  sleep "$D_WINDOW"
  snap D2
  delta D1 D2 "STATE D - SCREEN OFF (next ${D_WINDOW}s, deeper)"

  input keyevent 26 2>/dev/null
fi
echo
echo "################ DONE $(date '+%F %T') ################"
