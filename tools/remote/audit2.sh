#!/system/bin/sh
# AxionOS 2.7 power audit, wave 2: live state of every mechanism found in wave 1.
OUT=/data/local/tmp/audit2.txt
: > "$OUT"; exec >> "$OUT" 2>&1
t() { timeout 12 "$@" 2>/dev/null; }
f() { timeout 6 cat "$1" 2>/dev/null; }

echo "################ ROM AUDIT WAVE 2  $(date '+%F %T') ################"

echo; echo "===== 1. debugfs: can it be mounted? (this is where wakeup_sources lives) ====="
mount -t debugfs debugfs /sys/kernel/debug 2>&1 | head -2
echo "debugfs_mounted=$(mount | grep -c debugfs)"
t ls /sys/kernel/debug 2>/dev/null | head -25
for f2 in /sys/kernel/debug/wakeup_sources /sys/kernel/debug/suspend_stats /sys/kernel/debug/pm_genpd; do
  [ -e "$f2" ] && echo "  PRESENT $f2"
done

echo; echo "===== 2. MTK SPM / suspend debug ====="
t ls /sys/kernel/debug/spm 2>/dev/null | head -12
t ls /proc/spm 2>/dev/null | head -6
echo "wake_lock=[$(f /sys/power/wake_lock)]"
echo "wake_unlock=[$(f /sys/power/wake_unlock)]"
for f2 in /proc/wakeup_sources /sys/kernel/debug/wakeup_sources; do
  [ -e "$f2" ] && echo "--- $f2 head ---" && t head -12 "$f2"
done

echo; echo "===== 3. CPU: caps, cpusets, uclamp, schedule ====="
echo "--- MTK cluster cap nodes (the clean cap interface) ---"
echo "  lcluster_max_freq=$(f /sys/devices/system/cpu/cpufreq/mtk/lcluster_max_freq)"
echo "  bcluster_max_freq=$(f /sys/devices/system/cpu/cpufreq/mtk/bcluster_max_freq)"
echo "  lcluster_min_freq=$(f /sys/devices/system/cpu/cpufreq/mtk/lcluster_min_freq)"
echo "  bcluster_min_freq=$(f /sys/devices/system/cpu/cpufreq/mtk/bcluster_min_freq)"
echo "--- cpusets (live) ---"
for c in /dev/cpuset/*/cpus; do echo "  $c = $(f $c)"; done
echo "--- cpuctl uclamp (live) ---"
for c in /dev/cpuctl/*/cpu.uclamp.max; do echo "  $c = $(f $c)"; done
echo "--- governors / rate limits ---"
for p in policy0 policy6; do
  echo "  $p gov=$(f /sys/devices/system/cpu/cpufreq/$p/scaling_governor) up=$(f /sys/devices/system/cpu/cpufreq/$p/schedutil/up_rate_limit_us) down=$(f /sys/devices/system/cpu/cpufreq/$p/schedutil/down_rate_limit_us)"
done
echo "--- stune ---"
for s in /dev/stune/*/schedtune.boost; do echo "  $s = $(f $s)"; done

echo; echo "===== 4. perfmgr / perfserv nodes (live) ====="
for n in /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_fg_boost /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_ta_boost /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_bg_boost /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_uclamp_min /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_ta_uclamp_min /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_fg_uclamp_min /proc/perfmgr/boost_ctrl/eas_ctrl/perfserv_bg_uclamp_min /proc/perfmgr/boost_ctrl/eas_ctrl/m_sched_migrate_cost_n /proc/perfmgr/boost_ctrl/dram_ctrl/ddr /proc/cpufreq/cpufreq_cci_mode; do
  [ -e "$n" ] && echo "  $(basename $n) = $(f $n)" || echo "  absent $n"
done
echo "--- fbt / fpsgo ---"
for n in /sys/module/fbt_cpu/parameters/floor_bound /sys/module/fbt_cpu/parameters/variance /sys/module/fbt_cpu/parameters/bhr /sys/module/fbt_cpu/parameters/bhr_opp /sys/kernel/fpsgo/fbt/boost_ta /sys/kernel/fpsgo/common/gpu_block_boost /sys/kernel/fpsgo/common/fpsgo_enable; do
  [ -e "$n" ] && echo "  $(basename $n) = $(f $n)" || echo "  absent $n"
done

echo; echo "===== 5. GED / GPU (live) ====="
for n in /sys/kernel/ged/hal/dvfs_margin_value /sys/kernel/ged/hal/timer_base_dvfs_margin /sys/kernel/ged/hal/loading_base_dvfs_step /sys/module/ged/parameters/enable_cpu_boost /sys/module/ged/parameters/enable_gpu_boost /sys/module/ged/parameters/gx_dfps /sys/module/ged/parameters/gx_frc_mode /sys/module/ged/parameters/ged_smart_boost /sys/module/ged/parameters/boost_gpu_enable; do
  [ -e "$n" ] && echo "  $(basename $n) = $(f $n)" || echo "  absent $n"
done
echo "--- mali / gpu governor ---"
for n in /sys/devices/platform/13040000.mali/js_ctx_scheduling_mode /sys/devices/platform/13040000.mali/js_scheduling_period /sys/devices/platform/13040000.mali/dvfs_period /sys/class/devfreq/13040000.mali/governor; do
  [ -e "$n" ] && echo "  $(basename $n) = $(f $n)"
done

echo; echo "===== 6. Axion CPU-partition props (who uses them?) ====="
t getprop 2>/dev/null | grep -E "axion_cpu" | head -20
echo "--- grep the framework/services for the prop name ---"
t grep -rl "axion_cpu_limit_bg" /system/framework /system_ext/framework /system/bin /system_ext/bin 2>/dev/null | head -5
echo "--- AxionParts / AxionFx contents ---"
t ls /system_ext/priv-app/AxionParts /system_ext/priv-app/AxionFx 2>/dev/null | head -12

echo; echo "===== 7. WiFi power behaviour ====="
t cmd wifi status 2>/dev/null | head -3
t dumpsys wifi 2>/dev/null | grep -iE "power save|powersave|low power|Suspend|scan mode|SetSuspendOptimizations" | head -10
echo "  wifi_scan_always_enabled=$(t settings get global wifi_scan_always_enabled)"
echo "  wifi_scan_throttle=$(t settings get global wifi_scan_throttle_enabled)"
echo "  wifi_power_save(prop)=$(t getprop wifi.supplicant_scan_interval)"

echo; echo "===== 8. Doze: whitelist + history ====="
echo "whitelist_count=$(t dumpsys deviceidle whitelist | wc -l)"
t dumpsys deviceidle whitelist 2>/dev/null | head -40
echo "--- idling history ---"
t dumpsys deviceidle 2>/dev/null | sed -n '/Idling history/,/^$/p' | head -12
echo "--- current state ---"
t dumpsys deviceidle get deep; t dumpsys deviceidle get light

echo; echo "===== 9. Thermal configuration ====="
for f2 in /vendor/etc/.tp/thermal.conf /vendor/etc/thermal_manager.conf /vendor/etc/thermal.conf /vendor/etc/.tp/.ht120.mtc; do
  [ -f "$f2" ] && echo "  FOUND $f2 ($(wc -c < $f2) bytes)"
done
t find /vendor/etc -maxdepth 3 -iname '*thermal*' 2>/dev/null | head -12
echo "thermal_zone_count=$(t ls /sys/class/thermal | grep -c thermal_zone)"

echo; echo "===== 10. What realme/oplus doze overlay configures ====="
t dumpsys deviceidle 2>/dev/null | grep -iE "wait_for_unlock|use_window_alarms|use_mode_manager|light_after_inactive|inactive_to|idle_to|min_time_to_alarm" | head -10

echo; echo "################ END $(date '+%F %T') ################"
