#!/system/bin/sh
# Exit Super Power Saving Mode — restore saved state.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

log "===== EXIT SPSM ====="
rm -f "$ACTIVE"

# ---------- unlock CPU/GPU sysfs ----------
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  n=$(basename "$cpu")
  unlock_sysfs "$cpu/cpufreq/scaling_max_freq"
  unlock_sysfs "$cpu/cpufreq/scaling_min_freq"
  unlock_sysfs "$cpu/cpufreq/scaling_governor"
  if [ -f "$STATE_DIR/${n}_online" ]; then
    w "$(cat "$STATE_DIR/${n}_online")" "$cpu/online"
  else
    w 1 "$cpu/online"
  fi
  [ -f "$STATE_DIR/${n}_gov" ] && w "$(cat "$STATE_DIR/${n}_gov")" "$cpu/cpufreq/scaling_governor"
  [ -f "$STATE_DIR/${n}_min" ] && w "$(cat "$STATE_DIR/${n}_min")" "$cpu/cpufreq/scaling_min_freq"
  [ -f "$STATE_DIR/${n}_max" ] && w "$(cat "$STATE_DIR/${n}_max")" "$cpu/cpufreq/scaling_max_freq"
done

if [ -f "$STATE_DIR/ppm_mode" ]; then
  w "$(cat "$STATE_DIR/ppm_mode")" /proc/ppm/mode
else
  w "Performance" /proc/ppm/mode
  # many kernels use: echo 0 to leave user mode
fi
[ -f "$STATE_DIR/ppm_cores" ] && w "$(cat "$STATE_DIR/ppm_cores")" /proc/ppm/policy/ut_fix_core_num
# 0 often means "free" on gpufreq_opp_freq
if [ -f /proc/gpufreq/gpufreq_opp_freq ]; then
  w 0 /proc/gpufreq/gpufreq_opp_freq
fi
if [ -f /proc/gpufreqv2/fix_target_opp_index ]; then
  w -1 /proc/gpufreqv2/fix_target_opp_index
fi

w 1 /sys/module/ged/parameters/gpu_dvfs_enable
w 1 /sys/module/ged/parameters/is_GED_KPI_enabled

# ---------- restore settings ----------
putg() {
  # putg namespace key file
  [ -f "$3" ] || return 0
  val=$(cat "$3")
  [ "$val" = "null" ] && return 0
  settings put "$1" "$2" "$val" 2>/dev/null
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
    settings put global battery_saver_constants "$val" >/dev/null 2>&1
  fi
else
  settings delete global battery_saver_constants >/dev/null 2>&1
fi

# default: turn battery saver off if we have no saved value
if [ ! -f "$STATE_DIR/low_power" ] || [ "$(cat "$STATE_DIR/low_power" 2>/dev/null)" = "null" ]; then
  settings put global low_power 0
  settings put global low_power_sticky 0
fi

cmd power set-mode 0 2>/dev/null
cmd uimode night auto >/dev/null 2>&1
cmd netpolicy set restrict-background false >/dev/null 2>&1
dumpsys deviceidle unforce >/dev/null 2>&1
dumpsys deviceidle disable >/dev/null 2>&1
dumpsys deviceidle enable >/dev/null 2>&1

if [ -f "$STATE_DIR/bl_path" ] && [ -f "$STATE_DIR/bl_value" ]; then
  w "$(cat "$STATE_DIR/bl_value")" "$(cat "$STATE_DIR/bl_path")"
fi

# BT restore
if [ -f "$STATE_DIR/bt" ]; then
  case "$(cat "$STATE_DIR/bt")" in
    1|true|on) svc bluetooth enable >/dev/null 2>&1 ;;
  esac
fi

# ---------- unsuspend apps we froze ----------
if [ -f "$SPSM_DIR/suspended_by_us.txt" ]; then
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    pm unsuspend "$pkg" >/dev/null 2>&1
    cmd appops set "$pkg" RUN_IN_BACKGROUND default >/dev/null 2>&1
    cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND default >/dev/null 2>&1
    am set-inactive "$pkg" false >/dev/null 2>&1
  done < "$SPSM_DIR/suspended_by_us.txt"
fi
# belt and suspenders
pm list packages --suspended 2>/dev/null | sed 's/package://' | while read -r pkg; do
  [ -n "$pkg" ] || continue
  pm unsuspend "$pkg" >/dev/null 2>&1
done

# ---------- restore HOME ----------
home=$(cat "$STATE_DIR/home" 2>/dev/null)
log "restoring home: $home"
if [ -n "$home" ] && [ "$home" != "dev.axion.spsm" ]; then
  cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
  cmd role add-role-holder android.app.role.HOME "$home" >/dev/null 2>&1
  # activity-qualified form
  case "$home" in
    */*) cmd package set-home-activity "$home" >/dev/null 2>&1 ;;
    *)
      # try launcher3 common
      cmd package set-home-activity "$home/.Launcher" >/dev/null 2>&1
      ;;
  esac
else
  cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
  # Axion default
  cmd role add-role-holder android.app.role.HOME com.android.launcher3 >/dev/null 2>&1
  cmd package set-home-activity "com.android.launcher3/.uioverrides.QuickstepLauncher" >/dev/null 2>&1
fi

am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1

rm -f "$STATE_DIR/saved"
log "===== SPSM OFF ====="
exit 0
