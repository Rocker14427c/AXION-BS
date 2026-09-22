#!/system/bin/sh
# SPSM power baseline - one shot, no server, no tunnel.
#
#   su -c 'sh /data/local/tmp/POWER.sh' | tee /data/local/tmp/power.txt
#
# Everything here is a read. Nothing is changed. The point is to answer one
# question with numbers instead of opinions: does this phone actually suspend,
# and if not, what is holding it awake?
#
# Counters are cumulative since boot, so a single reading of any of them says
# nothing on its own. Run this TWICE with a gap between the runs and the
# difference is the measurement. That is what the "delta" lines at the end are
# for - the second run reads the first run's saved numbers and subtracts.

OUT=/data/local/tmp/power-prev.txt
NOW=/data/local/tmp/power-now.txt

snap() {
  echo "### $(date '+%F %T')"
  echo "uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  for f in /sys/power/suspend_stats/*; do
    echo "sus_$(basename "$f")=$(cat "$f" 2>/dev/null)"
  done
  echo "wakeup_count=$(cat /sys/power/wakeup_count 2>/dev/null)"
  for f in current_now voltage_now capacity charge_counter status; do
    echo "bat_$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"
  done
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    for s in "$c"/cpuidle/state[0-9]*; do
      [ -d "$s" ] || continue
      echo "idle_$(basename "$c")_$(basename "$s")=$(cat "$s/usage" 2>/dev/null)/$(cat "$s/time" 2>/dev/null)"
    done
  done
  for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
    echo "gov_$(basename "$p")=$(cat "$p/scaling_governor" 2>/dev/null) cur=$(cat "$p/scaling_cur_freq" 2>/dev/null)"
  done
}

snap > "$NOW" 2>/dev/null

echo "=========== SNAPSHOT ==========="
cat "$NOW"

echo
echo "=========== DELTA vs previous run ==========="
if [ -s "$OUT" ]; then
  # Only the numbers that mean something as a difference.
  for k in uptime wakeup_count bat_charge_counter bat_current_now; do
    a=$(sed -n "s/^$k=//p" "$OUT" 2>/dev/null | head -1)
    b=$(sed -n "s/^$k=//p" "$NOW" 2>/dev/null | head -1)
    echo "$k: ${a:-?} -> ${b:-?}"
  done
  # Suspend attempts and failures - the direct answer to "did it sleep".
  for k in sus_success sus_fail sus_failed_freeze sus_failed_suspend; do
    a=$(sed -n "s/^$k=//p" "$OUT" 2>/dev/null | head -1)
    b=$(sed -n "s/^$k=//p" "$NOW" 2>/dev/null | head -1)
    [ -n "$a" ] && [ -n "$b" ] && echo "$k: +$((b - a))"
  done
  # Per-CPU idle entries and microseconds, which is the race-to-idle question.
  for k in $(sed -n 's/^idle_\([^=]*\)=.*/\1/p' "$NOW" 2>/dev/null); do
    a=$(sed -n "s/^idle_$k=//p" "$OUT" 2>/dev/null | head -1)
    b=$(sed -n "s/^idle_$k=//p" "$NOW" 2>/dev/null | head -1)
    [ -n "$a" ] && [ -n "$b" ] && echo "idle_$k: ${a} -> ${b}"
  done
else
  echo "(no previous run saved - run this again later to get a delta)"
fi

echo
echo "=========== TOP WAKEUP SOURCES ==========="
if [ -r /sys/kernel/debug/wakeup_sources ]; then
  head -1 /sys/kernel/debug/wakeup_sources
  tail -n +2 /sys/kernel/debug/wakeup_sources | sort -k2 -rn | head -20
else
  for d in /sys/class/wakeup/wakeup*; do
    [ -d "$d" ] || continue
    echo "$(cat "$d/active_count" 2>/dev/null) $(cat "$d/name" 2>/dev/null) prev=$(cat "$d/prevent_suspend_time_ms" 2>/dev/null)"
  done | sort -rn | head -20
fi

echo
echo "=========== DOZE ==========="
dumpsys deviceidle 2>/dev/null | grep -E "mState|mLightState|mScreenOn|mForceIdle|mActiveReason" | head -8

echo
echo "=========== DOZE WHITELIST (count) ==========="
dumpsys deviceidle whitelist 2>/dev/null | wc -l

echo
echo "=========== TOP ALARM PACKAGES ==========="
dumpsys alarm 2>/dev/null | grep -oE "com\.[a-zA-Z0-9._]+|android" | sort | uniq -c | sort -rn | head -12

echo
echo "=========== WIFI / RADIO ==========="
dumpsys wifi 2>/dev/null | grep -E "mWifiState|Wi-Fi is|mScreenOn|Scan Throttle" | head -6
dumpsys telephony.registry 2>/dev/null | grep -E "mServiceState=|mDataConnectionState" | head -3

echo
echo "=========== SPSM STATE ==========="
echo "active=$([ -f /data/adb/spsm/state/active ] && echo yes || echo no)"
echo "screen=$(cat /data/adb/spsm/state/screen 2>/dev/null)"
echo "deep=$(cat /data/adb/spsm/state/deep_report 2>/dev/null)"
echo "state_dir=$(ls /data/adb/spsm/state/ 2>/dev/null | tr '\n' ' ')"

cp -f "$NOW" "$OUT" 2>/dev/null
echo
echo "(this run saved; run again later for a delta)"
