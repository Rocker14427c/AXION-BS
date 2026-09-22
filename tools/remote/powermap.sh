#!/system/bin/sh
# Read-only power map for RMX3430. Every read is time-guarded: this device's
# `settings` and some dumpsys calls can block for minutes.
OUT=/data/local/tmp/powermap.txt
: > "$OUT"
exec >> "$OUT" 2>&1

t() { timeout 8 "$@" 2>/dev/null; }          # guarded command
tf() { timeout 8 cat "$1" 2>/dev/null; }     # guarded file read

echo "################ $(date '+%F %T') POWER MAP ################"

echo; echo "===== 0. meta ====="
echo "uptime_s=$(cut -d' ' -f1 /proc/uptime)"
echo "sus_success=$(tf /sys/power/suspend_stats/success)"
echo "sus_fail=$(tf /sys/power/suspend_stats/fail)"
echo "real_kernel=$(t cut -d' ' -f3 /proc/version)"
echo "boottime_prop=$(t getprop ro.boottime.init)"

echo; echo "===== 1. battery ====="
t dumpsys battery | grep -E "level|Charge counter|voltage|temperature|status|health|USB powered|AC powered" | head -12
echo "charge_counter_uAh=$(tf /sys/class/power_supply/battery/charge_counter)"
echo "current_now=$(tf /sys/class/power_supply/battery/current_now)"

echo; echo "===== 2. cpuidle residency (cpu0) ====="
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
  [ -d "$s" ] || continue
  echo "  $(basename $s) name=$(tf $s/name) usage=$(tf $s/usage) time_us=$(tf $s/time) disabled=$(tf $s/disable)"
done
_u=0; _tt=0
for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/usage; do [ -f "$s" ] && _u=$(( _u + $(cat "$s" 2>/dev/null || echo 0) )); done
for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/time;  do [ -f "$s" ] && _tt=$(( _tt + $(cat "$s" 2>/dev/null || echo 0) )); done
echo "cpuidle_all_usage=$_u"
echo "cpuidle_all_time_us=$_tt"
_off=0; for s in /sys/devices/system/cpu/cpu*/online; do [ "$(tf "$s")" = 0 ] && _off=$((_off+1)); done
echo "cores_offline=$_off"

echo; echo "===== 3. cpufreq ====="
for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
  echo "  $(basename $p) gov=$(tf $p/scaling_governor) cur=$(tf $p/scaling_cur_freq) min=$(tf $p/scaling_min_freq) max=$(tf $p/scaling_max_freq)"
done

echo; echo "===== 4. wakeup sources (top 25 by wakeup_count) ====="
mount | grep -q " /sys/kernel/debug " || t mount -t debugfs none /sys/kernel/debug
if [ -f /sys/kernel/debug/wakeup_sources ]; then
  cp /sys/kernel/debug/wakeup_sources /data/local/tmp/wakeup_sources.raw 2>/dev/null
  echo "  (header) $(head -1 /data/local/tmp/wakeup_sources.raw)"
  awk 'NR>1 {print $5, $6, $1}' /data/local/tmp/wakeup_sources.raw | sort -rn | head -25
else
  echo "  NO wakeup_sources in debugfs"
fi

echo; echo "===== 5. interrupts (top 20 by count) ====="
awk 'NR>1 && $2 ~ /^[0-9]/ {n=$1; sub(":","",n); s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s, n}' /proc/interrupts 2>/dev/null | sort -rn | head -20

echo; echo "===== 6. deviceidle / Doze ====="
t dumpsys deviceidle | head -22

echo; echo "===== 7. alarms ====="
t dumpsys alarm | sed -n '/Alarm Stats/,/^$/p' | head -18

echo; echo "===== 8. jobscheduler ====="
t dumpsys jobscheduler | grep -E "Registered jobs|Total jobs|Jobs running|num" | head -8
t dumpsys jobscheduler | sed -n '/Registered jobs/,/^$/p' | head -14

echo; echo "===== 9. power / wake locks ====="
t dumpsys power | grep -E "mWakefulness|mDeviceIdleMode|Wake Locks:" | head -6
t dumpsys power | sed -n '/Wake Locks:/,/^$/p' | head -25

echo; echo "===== 10. wifi ====="
t cmd wifi status | head -5
t dumpsys wifi | grep -iE "mWifiState|scan|suspend|powersave|power save" | head -12

echo; echo "===== 11. telephony ====="
t dumpsys telephony.registry | grep -E "mServiceState|mSignalStrength|mDataConnectionState|mCallState|mDataConnectionApn" | head -10

echo; echo "===== 12. sensors ====="
t dumpsys sensorservice | head -20

echo; echo "===== 13. thermal ====="
t dumpsys thermalservice | head -20

echo; echo "===== 14. top cpu ====="
t ps -A -o %cpu,pid,rss,cmd --sort=-%cpu | head -14

echo; echo "===== 15. gpu / ged ====="
for f in enable_cpu_boost enable_gpu_boost gx_dfps gx_frc_mode; do
  echo "  ged_$f=$(tf /sys/module/ged/parameters/$f)"
done
echo "  backlight=$(tf /sys/class/backlight/panel0-backlight/brightness)"

echo; echo "===== 16. axion services ====="
t dumpsys -l | grep -iE "axion|axp|columbus|sense" | head -8

echo; echo "===== 17. disk io / stat ====="
head -6 /proc/diskstats 2>/dev/null
head -1 /proc/stat 2>/dev/null
echo "vmstat: $(head -2 /proc/vmstat 2>/dev/null | tr '\n' ' ')"

echo; echo "===== 18. spsm ====="
cat /data/adb/spsm/config 2>/dev/null
echo "screen=$(tf /data/adb/spsm/state/screen)  active=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )"

echo; echo "################ END $(date '+%F %T') ################"
