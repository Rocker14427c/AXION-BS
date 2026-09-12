#!/system/bin/sh
# Enter Super Power Saving Mode — max aggressive, Realme-style.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

if [ -f "$DISABLE" ]; then
  log "disable flag present, not entering"
  exit 0
fi

log "===== ENTER SPSM ====="

collect_imes
collect_launchers

# ---------- save original state once ----------
if [ ! -f "$STATE_DIR/saved" ]; then
  log "saving state"
  settings get system screen_brightness > "$STATE_DIR/brightness" 2>/dev/null
  settings get system screen_brightness_mode > "$STATE_DIR/brightness_mode" 2>/dev/null
  settings get system screen_off_timeout > "$STATE_DIR/timeout" 2>/dev/null
  settings get global animator_duration_scale > "$STATE_DIR/anim1" 2>/dev/null
  settings get global transition_animation_scale > "$STATE_DIR/anim2" 2>/dev/null
  settings get global window_animation_scale > "$STATE_DIR/anim3" 2>/dev/null
  settings get global low_power > "$STATE_DIR/low_power" 2>/dev/null
  settings get global low_power_sticky > "$STATE_DIR/low_power_sticky" 2>/dev/null
  settings get global battery_saver_constants > "$STATE_DIR/bs_constants" 2>/dev/null
  settings get secure location_mode > "$STATE_DIR/location" 2>/dev/null
  settings get system haptic_feedback_enabled > "$STATE_DIR/haptic" 2>/dev/null
  settings get global wifi_scan_always_enabled > "$STATE_DIR/wifi_scan" 2>/dev/null
  settings get global ble_scan_always_enabled > "$STATE_DIR/ble_scan" 2>/dev/null
  settings get secure doze_always_on > "$STATE_DIR/aod" 2>/dev/null
  settings get global zen_mode > "$STATE_DIR/zen" 2>/dev/null
  cmd netpolicy get restrict-background 2>/dev/null | head -1 > "$STATE_DIR/restrict_bg"
  detect_home > "$STATE_DIR/home"
  settings get global device_idle_constants > "$STATE_DIR/idle_constants" 2>/dev/null

  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    n=$(basename "$cpu")
    [ -f "$cpu/online" ] && cat "$cpu/online" > "$STATE_DIR/${n}_online"
    if [ -f "$cpu/cpufreq/scaling_governor" ]; then
      cat "$cpu/cpufreq/scaling_governor" > "$STATE_DIR/${n}_gov"
    fi
    if [ -f "$cpu/cpufreq/scaling_max_freq" ]; then
      cat "$cpu/cpufreq/scaling_max_freq" > "$STATE_DIR/${n}_max"
    fi
    if [ -f "$cpu/cpufreq/scaling_min_freq" ]; then
      cat "$cpu/cpufreq/scaling_min_freq" > "$STATE_DIR/${n}_min"
    fi
  done

  # backlight
  for bl in /sys/class/backlight/*/brightness; do
    [ -e "$bl" ] || continue
    cat "$bl" > "$STATE_DIR/bl_value"
    echo "$bl" > "$STATE_DIR/bl_path"
    break
  done

  # GPU
  [ -f /proc/gpufreq/gpufreq_opp_freq ] && cat /proc/gpufreq/gpufreq_opp_freq > "$STATE_DIR/gpu_opp"
  [ -f /proc/gpufreqv2/fix_target_opp_index ] && cat /proc/gpufreqv2/fix_target_opp_index > "$STATE_DIR/gpu_opp2"

  # PPM
  [ -f /proc/ppm/policy/ut_fix_core_num ] && cat /proc/ppm/policy/ut_fix_core_num > "$STATE_DIR/ppm_cores"
  [ -f /proc/ppm/mode ] && cat /proc/ppm/mode > "$STATE_DIR/ppm_mode"

  settings get global auto_sync > "$STATE_DIR/auto_sync" 2>/dev/null

  # bluetooth / nfc
  settings get global bluetooth_on > "$STATE_DIR/bt" 2>/dev/null

  echo 1 > "$STATE_DIR/saved"
fi

# ---------- AOSP battery saver, max policy ----------
settings put global low_power 1
settings put global low_power_sticky 1
settings put global battery_saver_constants "advertise_is_enabled=true,enable_night_mode=true,vibration_disabled=true,animation_disabled=true,soundtrigger_disabled=true,fullbackup_deferred=true,keyvaluebackup_deferred=true,firewall_disabled=false,gps_mode=2,adjust_brightness_disabled=false,adjust_brightness_factor=0.4,data_saver=true,force_all_apps_standby=true,force_background_check=true,optional_sensors_disabled=true,aod_disabled=true,quick_doze_enabled=true,launch_boost_disabled=true,enable_datasaver=true,disable_launch_boost=true"
cmd power set-mode 1 2>/dev/null

settings put global animator_duration_scale 0
settings put global transition_animation_scale 0
settings put global window_animation_scale 0
settings put system screen_brightness_mode 0
settings put system screen_brightness 18
settings put system screen_off_timeout 15000
settings put system haptic_feedback_enabled 0
settings put secure location_mode 0
settings put global wifi_scan_always_enabled 0
settings put global ble_scan_always_enabled 0
settings put secure nearby_scanning_enabled 0 2>/dev/null
settings put secure doze_always_on 0
settings put global adaptive_battery_management_enabled 1
cmd uimode night yes >/dev/null 2>&1
cmd netpolicy set restrict-background true >/dev/null 2>&1
cmd connectivity airplane-mode disable >/dev/null 2>&1
# keep radio for calls/sms; disable BT/NFC
svc bluetooth disable >/dev/null 2>&1
svc nfc disable >/dev/null 2>&1
cmd bluetooth_manager disable >/dev/null 2>&1

# sync off
settings put global auto_sync 0 2>/dev/null
content call --uri content://settings/global --method PUT_global --arg auto_sync --extra value:i:0 >/dev/null 2>&1

# ---------- backlight ----------
if [ -f "$STATE_DIR/bl_path" ]; then
  bl=$(cat "$STATE_DIR/bl_path")
  # 10-15 on typical 255 or 2047 scales: use ~8%
  maxbl=255
  [ -f "$(dirname "$bl")/max_brightness" ] && maxbl=$(cat "$(dirname "$bl")/max_brightness")
  val=$((maxbl / 12))
  [ "$val" -lt 1 ] && val=1
  w "$val" "$bl"
fi

# ---------- CPU: Helio G85 = cpu0-5 little A55, cpu6-7 big A75 ----------
# Offline big cores. Cap little cluster ~1.05–1.15 GHz so the 6-app UI still moves.
for n in 6 7 8 9; do
  [ -f /sys/devices/system/cpu/cpu$n/online ] || continue
  w 0 /sys/devices/system/cpu/cpu$n/hotplug/enable
  w 0 /sys/devices/system/cpu/cpu$n/online
done

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  n=$(basename "$cpu")
  id=${n#cpu}
  [ -f "$cpu/online" ] || continue
  online=$(cat "$cpu/online" 2>/dev/null)
  [ "$online" = "1" ] || continue
  if [ -f "$cpu/cpufreq/scaling_governor" ]; then
    # powersave if available, else schedutil
    govs=$(cat "$cpu/cpufreq/scaling_available_governors" 2>/dev/null)
    case "$govs" in
      *powersave*) w powersave "$cpu/cpufreq/scaling_governor" ;;
      *) w schedutil "$cpu/cpufreq/scaling_governor" ;;
    esac
  fi
  if [ -f "$cpu/cpufreq/scaling_available_frequencies" ]; then
    cap=$(pick_freq_cap 1150000 "$cpu/cpufreq/scaling_available_frequencies")
    min=$(cat "$cpu/cpufreq/cpuinfo_min_freq" 2>/dev/null)
    [ -n "$min" ] && lock_sysfs "$min" "$cpu/cpufreq/scaling_min_freq"
    [ -n "$cap" ] && lock_sysfs "$cap" "$cpu/cpufreq/scaling_max_freq"
  fi
done

# MTK PPM: Low_Power if the node exists
if [ -f /proc/ppm/mode ]; then
  w "Low_Power" /proc/ppm/mode
fi
# cluster0 (little) keep, cluster1 (big) 0 cores — G85 is 6+2
if [ -f /proc/ppm/policy/ut_fix_core_num ]; then
  w "6 0" /proc/ppm/policy/ut_fix_core_num
fi

# GPU lowest OPP
if [ -f /proc/gpufreq/gpufreq_opp_dump ]; then
  # opp 0 is usually highest; last listed is lowest. Lock by writing lowest freq.
  low=$(awk '/freq =/{f=$3} END{print f}' /proc/gpufreq/gpufreq_opp_dump 2>/dev/null)
  # fallback: dump may be "OPP 8: 200000 KHz"
  [ -z "$low" ] && low=$(awk '{print $3}' /proc/gpufreq/gpufreq_opp_dump 2>/dev/null | grep -E '^[0-9]+$' | sort -n | head -1)
  [ -n "$low" ] && w "$low" /proc/gpufreq/gpufreq_opp_freq
fi
if [ -f /proc/gpufreqv2/fix_target_opp_index ]; then
  # highest index = lowest freq on MTK v2
  w 99 /proc/gpufreqv2/fix_target_opp_index
fi
# Mali / ged boosts off
w 0 /sys/module/ged/parameters/gx_game_mode
w 0 /sys/module/ged/parameters/gx_3D_benchmark_on
w 0 /sys/module/ged/parameters/boost_gpu_enable
w 0 /sys/module/ged/parameters/enable_cpu_boost
w 0 /sys/module/ged/parameters/enable_gpu_boost
w 0 /sys/module/ged/parameters/enable_gbe
w 0 /sys/module/ged/parameters/is_GED_KPI_enabled
w 0 /sys/module/ged/parameters/gpu_dvfs_enable
w 0 /sys/module/ged/parameters/gx_force_cpu_boost
# FPSGO off
w 0 /sys/kernel/fpsgo/common/force_onoff
w 0 /sys/kernel/fpsgo/fstb/fstb_enable
w 0 /sys/module/mtk_fpsgo/parameters/perfmgr_enable

# sched boost off
w 0 /sys/devices/system/cpu/sched/sched_boost
w 0 /proc/sys/kernel/sched_boost
w 0 /sys/module/cpu_boost/parameters/input_boost_enabled
w 0 /sys/module/cpu_boost/parameters/boost_ms
w "0:0 1:0 2:0 3:0 4:0 5:0 6:0 7:0" /sys/module/cpu_boost/parameters/input_boost_freq

# perfmgr / powerhal hints
w 0 /proc/perfmgr/boost_ctrl/eas_info/perf_serv
w 0 /proc/perfmgr/boost_ctrl/cpu_ctrl/cfp_enable
w 0 /sys/module/helio_if/parameters/plus_cpu_boost

# I/O quieter
for q in /sys/block/*/queue; do
  w 0 "$q/iostats"
  w 64 "$q/read_ahead_kb"
  w 0 "$q/add_random"
  [ -f "$q/scheduler" ] || continue
  sched=$(cat "$q/scheduler")
  case "$sched" in
    *noop*) w noop "$q/scheduler" ;;
    *none*) w none "$q/scheduler" ;;
    *deadline*) w deadline "$q/scheduler" ;;
  esac
done

# dirty writeback less often (saves wakeups)
w 1500 /proc/sys/vm/dirty_writeback_centisecs
w 0 /proc/sys/kernel/sched_schedstats
w 0 /proc/sys/kernel/timer_migration

# ---------- freeze almost every app ----------
log "suspending apps"
# dump current suspended so we only unsuspend what we froze
: > "$SPSM_DIR/suspended_by_us.txt"
pm list packages -e 2>/dev/null | sed 's/package://' | while read -r pkg; do
  [ -n "$pkg" ] || continue
  if is_protected "$pkg"; then
    continue
  fi
  pm suspend "$pkg" >/dev/null 2>&1 && echo "$pkg" >> "$SPSM_DIR/suspended_by_us.txt"
  am force-stop "$pkg" >/dev/null 2>&1
  cmd appops set "$pkg" RUN_IN_BACKGROUND ignore >/dev/null 2>&1
  cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
  am set-inactive "$pkg" true >/dev/null 2>&1
done

# nice GMS instead of killing it
gms=$(pidof com.google.android.gms 2>/dev/null)
[ -n "$gms" ] && renice 19 $gms >/dev/null 2>&1
cmd appops set com.google.android.gms RUN_IN_BACKGROUND ignore >/dev/null 2>&1

# ---------- switch HOME to SPSM launcher ----------
log "home was: $(cat "$STATE_DIR/home" 2>/dev/null)"
cmd role add-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
cmd package set-home-activity "dev.axion.spsm/.SpsmHomeActivity" >/dev/null 2>&1
am start -n dev.axion.spsm/.SpsmHomeActivity -a android.intent.action.MAIN -c android.intent.category.HOME --activity-clear-task >/dev/null 2>&1

# collapse status bar
service call statusbar 2 >/dev/null 2>&1

touch "$ACTIVE"
log "===== SPSM ON ====="
exit 0
