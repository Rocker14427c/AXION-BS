#!/system/bin/sh
# Enter Super Power Saving Mode — RMX3430 / Helio G85 max-aggressive.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

if [ -f "$DISABLE" ]; then
  log "disable flag present, not entering"
  exit 0
fi

rm -f "$EXITING"
log "===== ENTER SPSM ====="

collect_imes
collect_launchers

if [ ! -f "$STATE_DIR/saved" ]; then
  log "saving state"
  sget system screen_brightness > "$STATE_DIR/brightness"
  sget system screen_brightness_mode > "$STATE_DIR/brightness_mode"
  sget system screen_off_timeout > "$STATE_DIR/timeout"
  sget global animator_duration_scale > "$STATE_DIR/anim1"
  sget global transition_animation_scale > "$STATE_DIR/anim2"
  sget global window_animation_scale > "$STATE_DIR/anim3"
  sget global low_power > "$STATE_DIR/low_power"
  sget global low_power_sticky > "$STATE_DIR/low_power_sticky"
  sget global battery_saver_constants > "$STATE_DIR/bs_constants"
  sget secure location_mode > "$STATE_DIR/location"
  sget system haptic_feedback_enabled > "$STATE_DIR/haptic"
  sget global wifi_scan_always_enabled > "$STATE_DIR/wifi_scan"
  sget global ble_scan_always_enabled > "$STATE_DIR/ble_scan"
  sget secure doze_always_on > "$STATE_DIR/aod"
  sget global auto_sync > "$STATE_DIR/auto_sync"
  sget global bluetooth_on > "$STATE_DIR/bt"
  sget global wifi_on > "$STATE_DIR/wifi_on"
  detect_home > "$STATE_DIR/home"

  cat "$BL_PATH" > "$STATE_DIR/bl_value" 2>/dev/null
  echo "$BL_PATH" > "$STATE_DIR/bl_path"

  getprop persist.sys.activity_anim_perf_override > "$STATE_DIR/p_anim_perf"
  getprop persist.sys.perf.scroll_opt > "$STATE_DIR/p_scroll"
  getprop persist.sys.axion_cpu_fg > "$STATE_DIR/p_fg"
  getprop persist.sys.axion_cpu_limit_ui > "$STATE_DIR/p_limit_ui"
  getprop persist.sys.axion_cpu_svp > "$STATE_DIR/p_svp"
  getprop vendor.powerhal.interaction.max > "$STATE_DIR/p_hint_max"
  getprop vendor.powerhal.interaction.min > "$STATE_DIR/p_hint_min"

  cat /proc/ppm/policy_status > "$STATE_DIR/ppm_status" 2>/dev/null
  cat /proc/ppm/policy/ut_fix_core_num > "$STATE_DIR/ppm_cores" 2>/dev/null
  cat /proc/ppm/policy/ut_fix_freq_idx > "$STATE_DIR/ppm_freqidx" 2>/dev/null
  cat /proc/gpufreq/gpufreq_opp_freq > "$STATE_DIR/gpu_opp" 2>/dev/null
  cat /sys/module/ged/parameters/gpu_cust_upbound_freq > "$STATE_DIR/gpu_upbound" 2>/dev/null
  cat /sys/module/ged/parameters/enable_cpu_boost > "$STATE_DIR/ged_cpu_boost" 2>/dev/null
  cat /sys/module/ged/parameters/enable_gpu_boost > "$STATE_DIR/ged_gpu_boost" 2>/dev/null
  cat /sys/module/ged/parameters/ged_boost_enable > "$STATE_DIR/ged_boost" 2>/dev/null
  cat /proc/cpufreq/cpufreq_power_mode > "$STATE_DIR/cpufreq_power_mode" 2>/dev/null

  for pol in 0 6; do
    p=/sys/devices/system/cpu/cpufreq/policy$pol
    [ -d "$p" ] || continue
    cat "$p/scaling_governor" > "$STATE_DIR/pol${pol}_gov" 2>/dev/null
    cat "$p/scaling_min_freq" > "$STATE_DIR/pol${pol}_min" 2>/dev/null
    cat "$p/scaling_max_freq" > "$STATE_DIR/pol${pol}_max" 2>/dev/null
  done
  for n in 0 1 2 3 4 5 6 7; do
    cat /sys/devices/system/cpu/cpu$n/online > "$STATE_DIR/cpu${n}_online" 2>/dev/null
  done

  echo 1 > "$STATE_DIR/saved"
fi

save_framework_extras
save_vm

# AOSP saver (may binder-fail; hardware path below still runs)
sput global low_power 1
sput global low_power_sticky 1
sput global battery_saver_constants "$BS_CONSTANTS"
cmd power set-mode 1 >/dev/null 2>&1
sput global animator_duration_scale 0
sput global transition_animation_scale 0
sput global window_animation_scale 0
sput system screen_brightness_mode 0
sput system screen_off_timeout 15000
sput system haptic_feedback_enabled 0
sput secure location_mode 0
sput global wifi_scan_always_enabled 0
sput global ble_scan_always_enabled 0
sput secure nearby_scanning_enabled 0
sput secure doze_always_on 0
sput global auto_sync 0
cmd uimode night yes >/dev/null 2>&1
cmd netpolicy set restrict-background true >/dev/null 2>&1
svc bluetooth disable >/dev/null 2>&1
svc nfc disable >/dev/null 2>&1
cmd bluetooth_manager disable >/dev/null 2>&1

apply_axion_props
apply_hw
apply_framework_extras
enable_quick_doze
silence_logs
trim_caches

# HALs that only burn power on this dump — stopped by US, not another module
stop neuralnetworks_hal_service_mtk_neuron >/dev/null 2>&1
stop vendor.fps_hal_oplus >/dev/null 2>&1
stop statsd >/dev/null 2>&1
stop traced >/dev/null 2>&1
stop dumpstate >/dev/null 2>&1

w 5 /proc/sys/vm/laptop_mode
w 6000 /proc/sys/vm/dirty_writeback_centisecs
w 6000 /proc/sys/vm/dirty_expire_centisecs
w 1 /sys/module/workqueue/parameters/power_efficient
w 0 /proc/sys/kernel/sched_schedstats
for q in /sys/block/*/queue; do
  w 0 "$q/iostats"
  w 64 "$q/read_ahead_kb"
  w 0 "$q/add_random"
done

# Home first so the black screen is up before the long suspend pass
log "home was: $(cat "$STATE_DIR/home" 2>/dev/null)"
pm enable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1
cmd role add-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
cmd package set-home-activity "dev.axion.spsm/.SpsmHomeActivity" >/dev/null 2>&1
am start -n dev.axion.spsm/.SpsmHomeActivity -a android.intent.action.MAIN -c android.intent.category.HOME --activity-clear-task >/dev/null 2>&1
service call statusbar 2 >/dev/null 2>&1
touch "$ACTIVE"

log "suspending apps"
: > "$SPSM_DIR/suspended_by_us.txt"
pm list packages -e 2>/dev/null | sed 's/package://' | while read -r pkg; do
  [ -n "$pkg" ] || continue
  is_protected "$pkg" && continue
  pm suspend "$pkg" >/dev/null 2>&1 && echo "$pkg" >> "$SPSM_DIR/suspended_by_us.txt"
  am force-stop "$pkg" >/dev/null 2>&1
  cmd appops set "$pkg" RUN_IN_BACKGROUND ignore >/dev/null 2>&1
  cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
  am set-inactive "$pkg" true >/dev/null 2>&1
done

freeze_google

log "===== SPSM ON ====="
exit 0
