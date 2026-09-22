#!/system/bin/sh
# Axion SPSM — read-only diagnostic dump.
#
# This script WRITES NOTHING. No sysfs writes, no settings changes, no props.
# It only reads, so it is safe to run whether SPSM is on, off, or half-broken.
#
# Run as root. Over ADB this is easiest:
#   adb push DIAG.sh /data/local/tmp/ && adb shell su -c 'sh /data/local/tmp/DIAG.sh' > spsm-diag.txt
# From a terminal app on the phone:
#   su -c 'sh /sdcard/DIAG.sh > /sdcard/spsm-diag.txt'
#
# Note: while SPSM is on, the black home only shows your 6 apps. Add a terminal
# app to a slot, or use ADB from a PC.

echo "===== AXION SPSM DIAG ====="
echo "uid=$(id -u)"
if [ "$(id -u)" != "0" ]; then
  echo "NOT ROOT — re-running through su"
  exec su -c "sh \"$0\""
fi
echo "date=$(date '+%Y-%m-%d %H:%M:%S')"

S=/data/adb/spsm
RD() { cat "$1" 2>/dev/null || echo "(unreadable)"; }

echo
echo "########## 1. DEVICE / ROM ##########"
echo "device=$(getprop ro.product.device) model=$(getprop ro.product.model)"
echo "axion=$(getprop ro.axion.version) lineage=$(getprop ro.lineage.version)"
echo "build=$(getprop ro.build.display.id)"
echo "sdk=$(getprop ro.build.version.sdk) release=$(getprop ro.build.version.release)"
echo "kernel=$(uname -a)"
echo "uptime=$(uptime)"

echo
echo "########## 2. ROOT FLAVOR ##########"
echo "ksu=$(getprop ro.kernelsu.version 2>/dev/null)"
echo "ksud=$(ls -l /data/adb/ksud 2>/dev/null)"
echo "magisk=$(ls -d /data/adb/magisk 2>/dev/null)"
echo "resetprop=$(command -v resetprop 2>/dev/null || echo none)"
echo "module_dir=$(ls -d /data/adb/modules/axion_spsm 2>/dev/null || echo MISSING)"
echo "moddir_file=$(cat $S/moddir 2>/dev/null)"

echo
echo "########## 3. SPSM STATE ##########"
echo "active=$([ -f $S/active ] && echo YES || echo no)"
echo "exiting=$([ -f $S/exiting ] && echo YES || echo no)"
echo "disable=$([ -f $S/disable ] && echo YES || echo no)"
echo "snap_complete=$([ -f $S/snap/complete ] && echo YES || echo no)"
echo "google_frozen=$([ -f $S/snap/google_frozen ] && echo YES || echo no)"
echo "service_processes:"
ps -A 2>/dev/null | grep -E "service\.sh|enter\.sh|exit\.sh|watchdog\.sh|spsm" | grep -v grep
echo "--- log size: $(wc -c < $S/spsm.log 2>/dev/null || echo 0) bytes ---"

echo
echo "########## 4. SPSM LOG (last 120 lines) ##########"
tail -n 120 "$S/spsm.log" 2>/dev/null || echo "(no log)"

echo
echo "########## 5. SNAPSHOT MANIFEST ##########"
cat "$S/snap/MANIFEST" 2>/dev/null || echo "(no manifest)"
echo "--- snapshot files ---"
ls -la "$S/snap" 2>/dev/null | head -60

echo
echo "########## 6. CPU ONLINE / FREQ ##########"
echo "online=$(RD /sys/devices/system/cpu/online)"
echo "offline=$(RD /sys/devices/system/cpu/offline)"
i=0
while [ $i -lt 8 ]; do
  echo "cpu$i online=$(RD /sys/devices/system/cpu/cpu$i/online)"
  i=$((i + 1))
done
for p in 0 6; do
  d=/sys/devices/system/cpu/cpufreq/policy$p
  echo "policy$p gov=$(RD $d/scaling_governor) min=$(RD $d/scaling_min_freq) max=$(RD $d/scaling_max_freq) cur=$(RD $d/scaling_cur_freq)"
  echo "policy$p avail_freqs=$(RD $d/scaling_available_frequencies)"
done
echo "--- per-cpu current freq ---"
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
  [ -f "$c" ] && echo "$c = $(cat $c 2>/dev/null)"
done

echo
echo "########## 7. PPM / MTK (the risky nodes) ##########"
echo "--- /proc/ppm/policy_status ---"
cat /proc/ppm/policy_status 2>/dev/null || echo "(unreadable)"
echo "--- /proc/ppm/policy/ut_fix_core_num ---"
cat /proc/ppm/policy/ut_fix_core_num 2>/dev/null || echo "(unreadable)"
echo "--- /proc/ppm/policy/ut_fix_freq_idx ---"
cat /proc/ppm/policy/ut_fix_freq_idx 2>/dev/null || echo "(unreadable)"
echo "--- /proc/ppm/policy/forcelimit_cpu_core ---"
cat /proc/ppm/policy/forcelimit_cpu_core 2>/dev/null || echo "(unreadable)"
echo "--- hard_userlimit max_cpu_freq ---"
cat /proc/ppm/policy/hard_userlimit_max_cpu_freq 2>/dev/null || echo "(unreadable)"
echo "--- hard_userlimit min_cpu_freq ---"
cat /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null || echo "(unreadable)"
echo "--- cpufreq_power_mode=$(RD /proc/cpufreq/cpufreq_power_mode)"

echo
echo "########## 8. GPU / GED ##########"
echo "gpufreq_opp_freq=$(RD /proc/gpufreq/gpufreq_opp_freq)"
echo "gpu_cur=$(RD /proc/gpufreq/gpufreq_cur_freq)"
echo "cust_upbound=$(RD /sys/module/ged/parameters/gpu_cust_upbound_freq)"
echo "bottom_freq=$(RD /sys/module/ged/parameters/gpu_bottom_freq)"
echo "enable_cpu_boost=$(RD /sys/module/ged/parameters/enable_cpu_boost)"
echo "enable_gpu_boost=$(RD /sys/module/ged/parameters/enable_gpu_boost)"
echo "ged_boost_enable=$(RD /sys/module/ged/parameters/ged_boost_enable)"
echo "is_GED_KPI_enabled=$(RD /sys/module/ged/parameters/is_GED_KPI_enabled)"
echo "gpu_dvfs_enable=$(RD /sys/module/ged/parameters/gpu_dvfs_enable)"
echo "--- all readable ged params ---"
for f in /sys/module/ged/parameters/*; do
  [ -r "$f" ] && echo "$(basename $f)=$(cat $f 2>/dev/null)"
done 2>/dev/null | head -40

echo
echo "########## 9. BACKLIGHT ##########"
for f in /sys/class/leds/lcd-backlight/brightness \
         /sys/class/leds/lcd-backlight/max_brightness \
         /sys/class/backlight/panel0-backlight/brightness; do
  [ -e "$f" ] && echo "$f = $(cat $f 2>/dev/null)"
done
echo "settings system screen_brightness=$(settings get system screen_brightness 2>/dev/null)"
echo "settings system screen_brightness_mode=$(settings get system screen_brightness_mode 2>/dev/null)"
echo "settings system screen_off_timeout=$(settings get system screen_off_timeout 2>/dev/null)"
echo "--- screen state ---"
dumpsys power 2>/dev/null | grep -E "mWakefulness=|mScreenOn|Display Power" | head -5

echo
echo "########## 10. DT2W / GESTURE ##########"
for k in double_tap_to_wake tap_to_wake wake_gesture_enabled; do
  echo "secure.$k=$(settings get secure $k 2>/dev/null)  system.$k=$(settings get system $k 2>/dev/null)"
done
for f in /proc/touchpanel/double_tap_enable /proc/touchpanel/double_tap \
         /proc/touchpanel/gesture_enable /proc/touchpanel/enable_dt2w \
         /proc/tp_gesture /proc/ilitek/gesture /proc/ilitek/double_tap \
         /sys/touchpanel/double_tap /sys/class/touch/tp_gesture \
         /sys/class/touch/tp_dev/gesture_on \
         /sys/devices/virtual/touch/tp_dev/gesture_on \
         /sys/devices/platform/soc/soc:touch/gesture_on \
         /sys/class/ms-touchscreen-mtk/device/gesture_wakeup; do
  [ -e "$f" ] && echo "$f = $(cat $f 2>/dev/null)"
done

echo
echo "########## 11. NETWORK / RADIO ##########"
echo "wifi_on=$(settings get global wifi_on 2>/dev/null) (1=on)"
echo "bluetooth_on=$(settings get global bluetooth_on 2>/dev/null)"
echo "--- telephony ---"
getprop | grep -E "gsm.sim.state|gsm.network.type|gsm.operator.alpha|ril.*state" | head -10
echo "--- data ---"
dumpsys telephony.registry 2>/dev/null | grep -E "mDataConnectionState|mServiceState" | head -5
echo "svc wifi: $(dumpsys wifi 2>/dev/null | head -1)"
echo "ip addrs:"
ip -o addr 2>/dev/null | grep -v " lo " | head -6

echo
echo "########## 12. GOOGLE PACKAGES ##########"
for p in com.google.android.gms com.google.android.gsf com.android.vending \
         com.google.android.googlequicksearchbox com.google.android.tts com.google.android.as; do
  st=$(dumpsys package "$p" 2>/dev/null | grep -m1 -E "enabled=|suspended=" | sed 's/^ *//')
  echo "$p | $st"
done
echo "--- whitelist.txt (written by app, nothing reads it) ---"
cat "$S/whitelist.txt" 2>/dev/null || echo "(none)"

echo
echo "########## 13. POWER / THERMAL / DOZE ##########"
echo "low_power=$(settings get global low_power 2>/dev/null)  low_power_sticky=$(settings get global low_power_sticky 2>/dev/null)"
echo "battery_saver_constants=$(settings get global battery_saver_constants 2>/dev/null)"
echo "restrict_background=$(cmd netpolicy get restrict-background 2>/dev/null)"
echo "deviceidle mode:"
dumpsys deviceidle 2>/dev/null | head -12
echo "--- thermals ---"
for z in /sys/class/thermal/thermal_zone*/temp; do
  n=$(cat "$(dirname $z)/type" 2>/dev/null)
  echo "$n=$(cat $z 2>/dev/null)"
done 2>/dev/null | head -12
echo "--- top wakelocks ---"
dumpsys power 2>/dev/null | grep -A1 -E "Wake Locks" | head -12
echo "--- cpu time by process (top 12) ---"
top -n 1 -b 2>/dev/null | head -16

echo
echo "########## 14. ANIMATION / SETTINGS DRIFT ##########"
for k in animator_duration_scale transition_animation_scale window_animation_scale; do
  echo "global.$k=$(settings get global $k 2>/dev/null)"
done
echo "persist.log.tag=[$(getprop persist.log.tag)]  logd=$(getprop init.svc.logd)"
echo "home_role=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | head -1)"
echo "spsm_home_enabled=$(dumpsys package dev.axion.spsm 2>/dev/null | grep -A2 SpsmHomeActivity | grep -m1 -E "enabled=" | sed 's/^ *//')"

echo
echo "===== DIAG END — paste everything above back ====="
