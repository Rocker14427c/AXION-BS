#!/system/bin/sh
# Wave 3: debugfs hunt (wakeup sources), node existence checks, PPM, live power-path state.
OUT=/data/local/tmp/audit3.txt
: > "$OUT"; exec >> "$OUT" 2>&1
t() { timeout 12 "$@" 2>/dev/null; }

echo "################ ROM AUDIT WAVE 3  $(date '+%F %T') ################"

echo; echo "===== 1. debugfs at a writable mountpoint ====="
mkdir -p /data/local/tmp/dbg 2>/dev/null
mount -t debugfs debugfs /data/local/tmp/dbg 2>&1 | head -2
echo "mounted=$(mount | grep -c 'local/tmp/dbg')"
t ls /data/local/tmp/dbg 2>/dev/null | head -30
for f in wakeup_sources suspend_stats pm_genpd; do
  [ -e "/data/local/tmp/dbg/$f" ] && echo "  PRESENT /data/local/tmp/dbg/$f"
done
if [ -f /data/local/tmp/dbg/wakeup_sources ]; then
  cp /data/local/tmp/dbg/wakeup_sources /data/local/tmp/wakeup_sources.txt 2>/dev/null
  echo "  --- header ---"; head -1 /data/local/tmp/wakeup_sources.txt
  echo "  --- top 20 by wakeup_count (col5=active_count col6=event_count col7=wakeup_count) ---"
  awk 'NR>1 {print $1, $6, $7, $8}' /data/local/tmp/wakeup_sources.txt | sort -k3 -rn | head -20
fi
t ls /data/local/tmp/dbg/spm 2>/dev/null | head -10

echo; echo "===== 2. do the powerhint nodes actually exist? ====="
for n in \
  /sys/devices/system/cpu/cpufreq/mtk/lcluster_max_freq \
  /sys/devices/system/cpu/cpufreq/mtk/bcluster_max_freq \
  /sys/devices/system/cpu/cpufreq/mtk/lcluster_min_freq \
  /sys/devices/system/cpu/cpufreq/mtk/bcluster_min_freq \
  /dev/stune/top-app/schedtune.boost \
  /proc/touchpanel/double_tap_enable \
  /sys/devices/platform/13040000.mali/js_ctx_scheduling_mode \
  /sys/kernel/ged/hal/dvfs_margin_value ; do
  if [ -e "$n" ]; then echo "  EXISTS  $n = [$(t cat $n)]"; else echo "  MISSING $n"; fi
done
echo "--- what is under cpufreq/mtk ? ---"
t ls /sys/devices/system/cpu/cpufreq/mtk 2>/dev/null | head -20
echo "--- what is under cpufreq ? ---"
t ls /sys/devices/system/cpu/cpufreq 2>/dev/null | head -10
echo "--- is there an lcluster/bcluster interface anywhere? ---"
t find /sys/devices/system/cpu/cpufreq -maxdepth 2 -name '*cluster*' 2>/dev/null | head -10

echo; echo "===== 3. MTK PPM policy (the vendor power manager) ====="
echo "  enabled=$(t cat /proc/ppm/enabled)"
t ls /proc/ppm 2>/dev/null
echo "  --- policy_status ---"; t cat /proc/ppm/policy_status 2>/dev/null | head -20
echo "  --- policy dir ---"; t ls /proc/ppm/policy 2>/dev/null | head -20
echo "  --- dump_power_table (head) ---"; t head -12 /proc/ppm/dump_power_table 2>/dev/null
echo "  --- cpi ---"; t cat /proc/ppm/cpi 2>/dev/null | head -5
echo "  --- policy ---"; t cat /proc/ppm/policy 2>/dev/null | head -20

echo; echo "===== 4. suspend / idle configuration ====="
for n in /sys/power/state /sys/power/mem_sleep /sys/power/pm_async /sys/power/pm_freeze_timeout /sys/power/pm_test /sys/power/wakeup_count /sys/power/autosleep; do
  [ -e "$n" ] && echo "  $(basename $n) = [$(t cat $n)]"
done
echo "--- suspend stats ---"
for f in /sys/power/suspend_stats/*; do echo "  $(basename $f)=$(t cat $f | tr '\n' ' ')"; done

echo; echo "===== 5. who is in each cpuset right now (work classification) ====="
for c in top-app foreground foreground_window systemui ax_foreground background system-background h-background l-background restricted; do
  _p=$(t cat /dev/cpuset/$c/tasks 2>/dev/null | wc -l)
  echo "  cpuset $c: $(t cat /dev/cpuset/$c/cpus) tasks=$_p"
done

echo; echo "===== 6. sensors / location / bt state ====="
echo "  location_mode=$(t settings get secure location_mode)"
echo "  bluetooth=$(t cmd bluetooth_manager is-enabled 2>/dev/null | tr -d '\r')"
echo "  nfc=$(t cmd nfc is-enabled 2>/dev/null | tr -d '\r')"
echo "  gps_provider=$(t settings get secure location_providers_allowed)"
t dumpsys sensorservice 2>/dev/null | grep -iE "sensor list|^ *[0-9]+\)|active" | head -12

echo; echo "===== 7. GMS + background allowlists ====="
echo "  device_idle_whitelist_count=$(t dumpsys deviceidle whitelist | wc -l)"
echo "  allowlist in deviceconfig:"
t settings get global device_idle_constants 2>/dev/null | head -3
echo "  force_app_standby:"
t settings get global force_app_standby 2>/dev/null
echo "  app_standby_enabled=$(t settings get global app_standby_enabled)"
echo "  adaptive_battery_management_enabled=$(t settings get global adaptive_battery_management_enabled)"

echo; echo "################ END $(date '+%F %T') ################"
