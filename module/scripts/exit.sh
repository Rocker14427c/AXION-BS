#!/system/bin/sh
# Exit Super Power Saving Mode — restore RMX3430 state.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

log "===== EXIT SPSM ====="
# Stop watchdog from re-applying limits while we restore
echo 1 > "$EXITING"
rm -f "$ACTIVE"

restore_ppm

# Bring every core back first so policy6 exists again
for n in 0 1 2 3 4 5 6 7; do
  if [ -f "$STATE_DIR/cpu${n}_online" ]; then
    w "$(cat "$STATE_DIR/cpu${n}_online")" /sys/devices/system/cpu/cpu$n/online
  else
    w 1 /sys/devices/system/cpu/cpu$n/online
  fi
done

for pol in 0 6; do
  p=/sys/devices/system/cpu/cpufreq/policy$pol
  [ -d "$p" ] || continue
  [ -f "$STATE_DIR/pol${pol}_gov" ] && w "$(cat "$STATE_DIR/pol${pol}_gov")" "$p/scaling_governor"
  [ -f "$STATE_DIR/pol${pol}_min" ] && w "$(cat "$STATE_DIR/pol${pol}_min")" "$p/scaling_min_freq"
  [ -f "$STATE_DIR/pol${pol}_max" ] && w "$(cat "$STATE_DIR/pol${pol}_max")" "$p/scaling_max_freq"
done

# GPU unlock (0 = "Keeping OPP frequency is disabled")
w 0 /proc/gpufreq/gpufreq_opp_freq
if [ -f "$STATE_DIR/gpu_upbound" ]; then
  w "$(cat "$STATE_DIR/gpu_upbound")" /sys/module/ged/parameters/gpu_cust_upbound_freq
else
  w 1200000 /sys/module/ged/parameters/gpu_cust_upbound_freq
fi
w 300000 /sys/module/ged/parameters/gpu_bottom_freq
w 1 /sys/module/ged/parameters/enable_cpu_boost
w 1 /sys/module/ged/parameters/enable_gpu_boost
w 1 /sys/module/ged/parameters/ged_boost_enable
w 1 /sys/module/ged/parameters/gpu_dvfs_enable
w 1 /sys/module/ged/parameters/is_GED_KPI_enabled

if [ -f "$STATE_DIR/cpufreq_power_mode" ]; then
  w "$(cat "$STATE_DIR/cpufreq_power_mode")" /proc/cpufreq/cpufreq_power_mode
else
  w 0 /proc/cpufreq/cpufreq_power_mode
fi

# Axion props
[ -f "$STATE_DIR/p_anim_perf" ] && setprop persist.sys.activity_anim_perf_override "$(cat "$STATE_DIR/p_anim_perf")" >/dev/null 2>&1
[ -f "$STATE_DIR/p_scroll" ] && setprop persist.sys.perf.scroll_opt "$(cat "$STATE_DIR/p_scroll")" >/dev/null 2>&1
[ -f "$STATE_DIR/p_fg" ] && setprop persist.sys.axion_cpu_fg "$(cat "$STATE_DIR/p_fg")" >/dev/null 2>&1
[ -f "$STATE_DIR/p_limit_ui" ] && setprop persist.sys.axion_cpu_limit_ui "$(cat "$STATE_DIR/p_limit_ui")" >/dev/null 2>&1
[ -f "$STATE_DIR/p_svp" ] && setprop persist.sys.axion_cpu_svp "$(cat "$STATE_DIR/p_svp")" >/dev/null 2>&1
[ -f "$STATE_DIR/p_hint_max" ] && setprop vendor.powerhal.interaction.max "$(cat "$STATE_DIR/p_hint_max")" >/dev/null 2>&1
[ -f "$STATE_DIR/p_hint_min" ] && setprop vendor.powerhal.interaction.min "$(cat "$STATE_DIR/p_hint_min")" >/dev/null 2>&1

thaw_google
restore_logs
restore_wake_gestures
restore_framework_extras
restore_vm
start neuralnetworks_hal_service_mtk_neuron >/dev/null 2>&1
start vendor.fps_hal_oplus >/dev/null 2>&1

putg() {
  [ -f "$3" ] || return 0
  val=$(cat "$3")
  [ "$val" = "null" ] && return 0
  sput "$1" "$2" "$val"
}
putg system screen_brightness "$STATE_DIR/brightness"
putg system screen_brightness_mode "$STATE_DIR/brightness_mode"
putg system screen_off_timeout "$STATE_DIR/timeout"
putg global animator_duration_scale "$STATE_DIR/anim1"
putg global transition_animation_scale "$STATE_DIR/anim2"
putg global window_animation_scale "$STATE_DIR/anim3"
putg global low_power "$STATE_DIR/low_power"
putg global low_power_sticky "$STATE_DIR/low_power_sticky"
putg system haptic_feedback_enabled "$STATE_DIR/haptic"
putg secure location_mode "$STATE_DIR/location"
putg global wifi_scan_always_enabled "$STATE_DIR/wifi_scan"
putg global ble_scan_always_enabled "$STATE_DIR/ble_scan"
putg secure doze_always_on "$STATE_DIR/aod"
putg global auto_sync "$STATE_DIR/auto_sync"

if [ -f "$STATE_DIR/bs_constants" ]; then
  val=$(cat "$STATE_DIR/bs_constants")
  if [ "$val" = "null" ] || [ -z "$val" ]; then
    settings delete global battery_saver_constants >/dev/null 2>&1
  else
    sput global battery_saver_constants "$val"
  fi
else
  settings delete global battery_saver_constants >/dev/null 2>&1
fi
if [ ! -f "$STATE_DIR/low_power" ] || [ "$(cat "$STATE_DIR/low_power" 2>/dev/null)" = "null" ]; then
  sput global low_power 0
  sput global low_power_sticky 0
fi

cmd power set-mode 0 >/dev/null 2>&1
cmd uimode night auto >/dev/null 2>&1
cmd netpolicy set restrict-background false >/dev/null 2>&1
dumpsys deviceidle unforce >/dev/null 2>&1

if [ -f "$STATE_DIR/bl_value" ]; then
  w "$(cat "$STATE_DIR/bl_value")" "$BL_PATH"
fi

if [ -f "$STATE_DIR/bt" ]; then
  case "$(cat "$STATE_DIR/bt")" in
    1|true|on) svc bluetooth enable >/dev/null 2>&1 ;;
  esac
fi
if [ -f "$STATE_DIR/wifi_on" ]; then
  case "$(cat "$STATE_DIR/wifi_on")" in
    1|true|on) svc wifi enable >/dev/null 2>&1 ;;
  esac
fi

if [ -f "$SPSM_DIR/suspended_by_us.txt" ]; then
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    pm unsuspend "$pkg" >/dev/null 2>&1
    cmd appops set "$pkg" RUN_IN_BACKGROUND default >/dev/null 2>&1
    cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND default >/dev/null 2>&1
    am set-inactive "$pkg" false >/dev/null 2>&1
  done < "$SPSM_DIR/suspended_by_us.txt"
fi
pm list packages --suspended 2>/dev/null | sed 's/package://' | while read -r pkg; do
  [ -n "$pkg" ] || continue
  pm unsuspend "$pkg" >/dev/null 2>&1
done

home=$(cat "$STATE_DIR/home" 2>/dev/null)
log "restoring home: $home"
cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
if [ -n "$home" ] && [ "$home" != "dev.axion.spsm" ]; then
  cmd role add-role-holder android.app.role.HOME "$home" >/dev/null 2>&1
  case "$home" in
    */*) cmd package set-home-activity "$home" >/dev/null 2>&1 ;;
  esac
else
  cmd role add-role-holder android.app.role.HOME com.android.launcher3 >/dev/null 2>&1
  cmd package set-home-activity "com.android.launcher3/.uioverrides.QuickstepLauncher" >/dev/null 2>&1
fi
# Hide SPSM home from the launcher picker while the mode is off
pm disable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1
am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1

rm -f "$STATE_DIR/saved" "$STATE_DIR/fw_saved" "$STATE_DIR/wake_saved" "$STATE_DIR/vm_saved" "$STATE_DIR/gms_components_done"
rm -f "$EXITING"
log "===== SPSM OFF ====="
exit 0
