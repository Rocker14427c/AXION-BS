#!/system/bin/sh
# One-shot undo for leftover Axion SPSM. Does NOT enable power saving.

echo "===== SPSM UNDO start ====="
echo "uid=$(id -u)  context=$(id 2>/dev/null | head -1)"
if [ "$(id -u)" != "0" ]; then
  echo "NOT ROOT (that is why Permission denied). Asking SukiSU..."
  exec su -c "sh \"$0\""
fi
echo "Running as root. OK."

# Stop any leftover SPSM loop
rm -f /data/adb/spsm/active /data/adb/spsm/exiting
touch /data/adb/spsm/disable 2>/dev/null

ew() {
  [ -e "$2" ] || return 0
  echo "$1" > "$2" 2>/dev/null
}

# --- CPU: all 8 cores, schedutil, full freq (G85 dump) ---
for n in 0 1 2 3 4 5 6 7; do
  ew 1 /sys/devices/system/cpu/cpu$n/online
done
ew schedutil /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
ew 500000 /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
ew 1800000 /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
ew schedutil /sys/devices/system/cpu/cpufreq/policy6/scaling_governor
ew 850000 /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq
ew 2000000 /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq

# PPM unlock (G85)
ew "-1 -1" /proc/ppm/policy/ut_fix_core_num
ew "-1 -1" /proc/ppm/policy/ut_fix_freq_idx
ew "6 1" /proc/ppm/policy_status
ew "9 0" /proc/ppm/policy_status
ew "0 0" /proc/ppm/policy/hard_userlimit_max_cpu_freq
ew "1 0" /proc/ppm/policy/hard_userlimit_max_cpu_freq
ew "0 0" /proc/ppm/policy/hard_userlimit_min_cpu_freq
ew "1 0" /proc/ppm/policy/hard_userlimit_min_cpu_freq
ew "0 -1" /proc/ppm/policy/forcelimit_cpu_core
ew "1 -1" /proc/ppm/policy/forcelimit_cpu_core
ew 0 /proc/cpufreq/cpufreq_power_mode

# GPU unlock
ew 0 /proc/gpufreq/gpufreq_opp_freq
ew 1200000 /sys/module/ged/parameters/gpu_cust_upbound_freq
ew 300000 /sys/module/ged/parameters/gpu_bottom_freq
ew 1 /sys/module/ged/parameters/enable_cpu_boost
ew 1 /sys/module/ged/parameters/enable_gpu_boost
ew 1 /sys/module/ged/parameters/ged_boost_enable
ew 1 /sys/module/ged/parameters/gpu_dvfs_enable
ew 1 /sys/module/ged/parameters/is_GED_KPI_enabled
ew 0 /sys/module/ged/parameters/gx_game_mode

# Axion props from your dump (before SPSM)
setprop persist.sys.activity_anim_perf_override true
setprop persist.sys.perf.scroll_opt true
setprop persist.sys.axion_cpu_fg "0-5,6-7"
setprop persist.sys.axion_cpu_limit_ui "0-2"
setprop persist.sys.axion_cpu_svp "6-7"
setprop persist.sys.axion_cpu_big "6,7"
setprop persist.sys.axion_cpu_small "0,1,2,3,4,5"
setprop vendor.powerhal.interaction.max 50
setprop vendor.powerhal.interaction.min 10

# Logs (Logfox "waiting" = persist.log.tag=S + logd stopped)
rpdel() {
  key="$1"
  resetprop --delete "$key" >/dev/null 2>&1
  resetprop -p --delete "$key" >/dev/null 2>&1
  setprop "$key" "" >/dev/null 2>&1
}
rpdel persist.log.tag
rpdel log.tag
rpdel persist.logd.logpersistd
rpdel persist.logd.size
setprop persist.logd.size 262144
ew "4 4 1 7" /proc/sys/kernel/printk
setprop ctl.start logd
setprop ctl.start logd-reinit
setprop ctl.restart logd
start logd 2>/dev/null
start logd-reinit 2>/dev/null
start statsd 2>/dev/null
start traced 2>/dev/null
start traced_probes 2>/dev/null
start neuralnetworks_hal_service_mtk_neuron 2>/dev/null
start vendor.fps_hal_oplus 2>/dev/null

# Framework (these are the leftover "dark mode / no animation" bits)
settings put global animator_duration_scale 1
settings put global transition_animation_scale 1
settings put global window_animation_scale 1
settings put global low_power 0
settings put global low_power_sticky 0
settings delete global battery_saver_constants
settings put system screen_brightness_mode 1
settings put system screen_off_timeout 30000
settings put system haptic_feedback_enabled 1
settings put system accelerometer_rotation 1
settings put secure doze_always_on 0
settings put global auto_sync 1
settings put global captive_portal_mode 1
settings put global stay_on_while_plugged_in 0
cmd power set-mode 0
cmd uimode night no
cmd netpolicy set restrict-background false
dumpsys deviceidle unforce
cmd wifi set-scan-always-available enabled

# VM
ew 0 /proc/sys/vm/laptop_mode
ew 500 /proc/sys/vm/dirty_writeback_centisecs
ew 300 /proc/sys/vm/dirty_expire_centisecs

# Unsuspend everything
pm list packages --suspended 2>/dev/null | sed 's/package://' | while read -r p; do
  [ -n "$p" ] || continue
  pm unsuspend "$p" >/dev/null 2>&1
  am set-inactive "$p" false >/dev/null 2>&1
done

# Google back
for p in com.google.android.gms com.google.android.gsf com.google.android.gsf.login \
         com.android.vending com.google.android.googlequicksearchbox \
         com.google.android.tts com.google.android.as; do
  pm enable "$p" >/dev/null 2>&1
  pm unsuspend "$p" >/dev/null 2>&1
done

# Home back to launcher
cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
cmd role add-role-holder android.app.role.HOME com.android.launcher3 >/dev/null 2>&1
cmd package set-home-activity "com.android.launcher3/.uioverrides.QuickstepLauncher" >/dev/null 2>&1
pm disable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1

# Remove leftover app (user copy from pm install)
pm uninstall --user 0 dev.axion.spsm >/dev/null 2>&1
pm uninstall dev.axion.spsm >/dev/null 2>&1

rm -rf /data/adb/spsm

echo "===== SPSM UNDO done ====="
echo "Reboot once. Then: Settings → Display → Dark theme OFF, animations if still odd."
echo "CPU now:"
cat /sys/devices/system/cpu/online 2>/dev/null
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
cat /sys/devices/system/cpu/cpufreq/policy6/scaling_governor 2>/dev/null
echo "cpu6=$(cat /sys/devices/system/cpu/cpu6/online 2>/dev/null) cpu7=$(cat /sys/devices/system/cpu/cpu7/online 2>/dev/null)"
