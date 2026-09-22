#!/system/bin/sh
# =============================================================================
# SPSM standby A/B — measured on the device, survives a dead tunnel.
#
#   su -c 'nohup sh /data/local/tmp/ab.sh 600 </dev/null >/dev/null 2>&1 &'
#   # leave the phone COMPLETELY alone for ~25 minutes, then:
#   su -c 'cat /data/local/tmp/ab.out'
#
# Window A: SPSM off,  screen off, untouched
# Window B: SPSM on,   screen off, untouched
# SPSM is restored to the state it had when the script started.
#
# PRECONDITION, not optional: no wake lock may be held during a window.
# Run `termux-wake-unlock` before starting and keep the tunnel down, or the
# measurement is measuring the tunnel. (`suspend_stats.success` stays 0 while a
# partial wake lock is held - see docs/POWER-ANALYSIS-2026-09-22.md.)
#
# Nothing here polls during a window: a sampler that wakes every few seconds
# would itself prevent the suspend being measured, so each window takes one
# snapshot before and one after, and every counter is cumulative, so only the
# difference carries information.
# =============================================================================
WINDOW=${1:-600}
OUT=/data/local/tmp/ab.out
LOG=/data/adb/spsm/spsm.log
D=/data/local/tmp
exec >> "$OUT" 2>&1
trap 'sh /data/adb/spsm/scripts/engine.sh deactivate >/dev/null 2>&1' EXIT

# --- one snapshot, no polling afterwards --------------------------------------
snap() { # snap <tag>
  _t=$1
  {
    echo "uptime_s=$(cut -d' ' -f1 /proc/uptime)"
    for f in success fail failed_freeze failed_suspend last_failed_dev; do
      echo "sus_$f=$(cat /sys/power/suspend_stats/$f 2>/dev/null)"
    done
    echo "wakeup_count=$(cat /sys/power/wakeup_count 2>/dev/null)"
    for f in charge_counter current_now voltage_now capacity status; do
      echo "bat_$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"
    done
    _u=0; _tm=0
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/usage; do
      [ -f "$s" ] && _u=$(( _u + $(cat "$s" 2>/dev/null || echo 0) ))
    done
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/time; do
      [ -f "$s" ] && _tm=$(( _tm + $(cat "$s" 2>/dev/null || echo 0) ))
    done
    echo "cpuidle_usage=$_u"
    echo "cpuidle_time_us=$_tm"
    echo "screen=$(cat /data/adb/spsm/state/screen 2>/dev/null)"
    echo "spsm_active=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )"
  } > "$D/ab-$_t.txt" 2>/dev/null

  # wakeup ledger, kept raw so a reason that was not present in the first snapshot
  # is still counted in the difference
  timeout 90 dumpsys batterystats --charged 2>/dev/null \
    | sed -n '/All wakeup reasons/,/^$/p' > "$D/ab-wake-$_t.txt" 2>/dev/null
  # interrupt totals, for the per-hardware (wlan0 / ccci / touch) picture
  awk 'NR>1 {irq=$1; sub(":","",irq); c=0; nm="";
        for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/){c+=$i} else {nm=substr($0,index($0,$i)); break} }
        printf "%s\t%d\t%s\n", irq, c, nm}' /proc/interrupts > "$D/ab-irq-$_t.txt" 2>/dev/null
  echo "  snapshot $_t taken $(date '+%T')"
}

delta() { # delta <a> <b> <label>
  echo
  echo "===== DELTA $3 ====="
  for k in uptime_s sus_success sus_fail wakeup_count bat_charge_counter cpuidle_usage cpuidle_time_us; do
    _a=$(sed -n "s/^$k=//p" "$D/ab-$1.txt" | head -1)
    _b=$(sed -n "s/^$k=//p" "$D/ab-$2.txt" | head -1)
    [ -n "$_a" ] && [ -n "$_b" ] && printf "  %-22s +%s\n" "$k" "$(( _b - _a ))"
  done
  _a=$(sed -n 's/^bat_charge_counter=//p' "$D/ab-$1.txt" | head -1)
  _b=$(sed -n 's/^bat_charge_counter=//p' "$D/ab-$2.txt" | head -1)
  [ -n "$_a" ] && [ -n "$_b" ] && printf "  %-22s %s uAh (positive = discharged)\n" "drained" "$(( _a - _b ))"

  echo "  --- wakeup reasons that appeared/increased (top 12 by count) ---"
  sed -n 's/^ *Wakeup reason \(.*\): .* (\([0-9]*\) times).*/\2\t\1/p' "$D/ab-wake-$1.txt" 2>/dev/null | sort > "$D/w-$1.tmp"
  sed -n 's/^ *Wakeup reason \(.*\): .* (\([0-9]*\) times).*/\2\t\1/p' "$D/ab-wake-$2.txt" 2>/dev/null | sort > "$D/w-$2.tmp"
  awk -F'\t' 'NR==FNR{a[$2]=$1; next} {d=$1-(a[$2]+0); if (d>0) printf "%8d  %s\n", d, $2}' \
      "$D/w-$1.tmp" "$D/w-$2.tmp" 2>/dev/null | sort -rn | head -12

  echo "  --- hardware interrupts that increased (top 10) ---"
  awk -F'\t' 'NR==FNR{a[$1]=$2; n[$1]=$3; next}
       {d=$2-(a[$1]+0); if (d>0) printf "%10d  %-6s %s\n", d, $1, $3}' \
      "$D/ab-irq-$1.txt" "$D/ab-irq-$2.txt" 2>/dev/null | sort -rn | head -10
}

started_active=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )
echo
echo "################ $(date '+%F %T')  A/B  window=${WINDOW}s  spsm_started=$started_active ################"
echo "wake locks held at start:"
timeout 30 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | head -8

# ---------------------------------------------------------------- window A
echo
echo "################ WINDOW A — SPSM OFF ################"
[ "$started_active" = yes ] && sh /data/adb/spsm/scripts/engine.sh deactivate >/dev/null 2>&1
sleep 5
snap "A1"
echo "  screen off now — do not touch the phone for the window"
input keyevent 26 2>/dev/null
sleep "$WINDOW"
snap "A2"
delta "A1" "A2" "WINDOW A (SPSM OFF)"

# ---------------------------------------------------------------- window B
echo
echo "################ WINDOW B — SPSM ON ################"
input keyevent 26 2>/dev/null          # wake briefly so activation can run
sleep 8
sh /data/adb/spsm/scripts/engine.sh activate 2>&1 | tail -3
sleep 25
snap "B1"
echo "  screen off now — do not touch the phone for the window"
input keyevent 26 2>/dev/null
sleep "$WINDOW"
snap "B2"
echo "  deep_report: $(cat /data/adb/spsm/state/deep_report 2>/dev/null)"
delta "B1" "B2" "WINDOW B (SPSM ON)"

# ---------------------------------------------------------------- restore
echo
echo "################ RESTORE ################"
input keyevent 26 2>/dev/null
sleep 10
sh /data/adb/spsm/scripts/engine.sh deactivate 2>&1 | tail -3
if [ "$started_active" = yes ]; then
  sh /data/adb/spsm/scripts/engine.sh activate >/dev/null 2>&1
  echo "(SPSM re-activated: that was its state before the test)"
fi
echo "spsm_now=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )"
echo
echo "################ DONE $(date '+%F %T') ################"
echo "reminder: run 'termux-wake-lock' again now that the windows are over"
