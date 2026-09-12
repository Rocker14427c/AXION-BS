#!/system/bin/sh
# Shared helpers — tuned from RMX3430 Axion 2.7 dump (MT6769V/CZ Helio G85)

SPSM_DIR="/data/adb/spsm"
STATE_DIR="$SPSM_DIR/state"
LOG="$SPSM_DIR/spsm.log"
WHITELIST="$SPSM_DIR/whitelist.txt"
ACTIVE="$SPSM_DIR/active"
DISABLE="$SPSM_DIR/disable"
EXITING="$SPSM_DIR/exiting"

# G85 (dump): policy0 = A55 cpu0-5 (500-1800), policy6 = A75 cpu6-7 (850-2000)
# Little freqs: 1800 1625 1500 1450 1375 1325 1275 1175 1100 1050 999 950 900 850 774 500
# Screen-on cap 850 MHz (idx 13). Screen-off lock 500 MHz (idx 15).
LITTLE_ON_KHZ=850000
LITTLE_OFF_KHZ=500000
BIG_MIN_KHZ=850000
GPU_MIN_KHZ=300000
BL_PATH="/sys/class/leds/lcd-backlight/brightness"
BL_SPSM=160
BL_MAX=4095

mkdir -p "$SPSM_DIR" "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  if [ -f "$LOG" ]; then
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 200000 ] && tail -c 80000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

w() {
  [ -n "$2" ] && [ -e "$2" ] || return 0
  echo "$1" > "$2" 2>/dev/null
}

sput() {
  # sput namespace key value  — settings often binder-fails from some su contexts
  settings put "$1" "$2" "$3" >/dev/null 2>&1
  content call --uri "content://settings/$1" --method "PUT_$1" --arg "$2" --extra "value:s:$3" >/dev/null 2>&1
}

sget() {
  settings get "$1" "$2" 2>/dev/null
}

screen_is_off() {
  bl=$(cat "$BL_PATH" 2>/dev/null)
  [ -z "$bl" ] && bl=1
  [ "$bl" = "0" ]
}

is_protected() {
  p="$1"
  [ -z "$p" ] && return 0
  case "$p" in
    android|dev.axion.spsm) return 0 ;;
    com.android.systemui|com.android.systemui.*) return 0 ;;
    com.android.shell|com.android.settings|com.android.settings.intelligence) return 0 ;;
    com.android.phone|com.android.server.telecom|com.android.incallui) return 0 ;;
    com.android.dialer|com.google.android.dialer|org.lineageos.dialer) return 0 ;;
    # Launchers are frozen while SPSM home is active (restored on exit).
    com.android.deskclock|com.google.android.deskclock) return 0 ;;
    org.lineageos.backgrounds|org.lineageos.overlay*|com.android.wallpaper*) return 0 ;;
    com.android.contacts|com.android.contacts.*) return 0 ;;
    com.android.mms.service|com.android.providers.telephony|com.android.providers.contacts) return 0 ;;
    com.android.providers.settings|com.android.providers.media|com.android.providers.media.module) return 0 ;;
    com.android.nfc|com.android.bluetooth|com.android.bluetoothmidiservice) return 0 ;;
    com.android.keychain|com.android.se|com.android.location.fused) return 0 ;;
    com.android.permissioncontroller|com.google.android.permissioncontroller) return 0 ;;
    com.android.packageinstaller|com.google.android.packageinstaller) return 0 ;;
    com.android.safetycenter*|com.android.permissioncontroller.*) return 0 ;;
    com.android.inputmethod*|com.google.android.inputmethod*|com.touchtype.swiftkey*) return 0 ;;
    com.android.webview|com.google.android.webview) return 0 ;;
    com.google.android.ext.services|com.google.android.ext.shared) return 0 ;;
    com.android.networkstack*|com.android.wifi*|com.android.connectivity*) return 0 ;;
    com.android.cellbroadcast*|com.android.emergency|com.android.smspush|com.android.stk) return 0 ;;
    com.android.ims*|com.android.imsservice*|org.codeaurora.ims|com.mediatek.ims) return 0 ;;
    com.android.vpndialogs|com.android.externalstorage|com.android.localtransport) return 0 ;;
    com.android.intentresolver|com.android.documentsui) return 0 ;;
    com.android.modulemetadata|com.android.dynsystem|com.android.rkpd*) return 0 ;;
    com.android.microdroid*|com.android.virtualization*|com.android.uwb*) return 0 ;;
    com.android.ons|com.android.proxyhandler|com.android.pacprocessor) return 0 ;;
    com.android.theme*|com.android.internal.*|android.overlay*|com.android.overlay*) return 0 ;;
    *overlay*|*Overlay*) return 0 ;;
    com.mediatek.*|vendor.mediatek.*|com.android.mtk*) return 0 ;;
    me.weishu.kernelsu|com.rifsxd.ksunext|me.bmax.apatch|com.sukisu.ultra|io.github.huskydg.magisk|com.topjohnwu.magisk) return 0 ;;
    com.termux|com.termux.*) return 0 ;;
  esac
  echo "$p" | grep -qiE 'magisk|kernelsu|sukisu|ksunext|apatch|lsposed|zygisk|riru|edxposed|superuser|ksud' && return 0
  if [ -f "$SPSM_DIR/ime.txt" ] && grep -qx "$p" "$SPSM_DIR/ime.txt" 2>/dev/null; then
    return 0
  fi
  if [ -f "$WHITELIST" ] && grep -qx "$p" "$WHITELIST" 2>/dev/null; then
    return 0
  fi
  return 1
}

collect_imes() {
  ime list -s 2>/dev/null | awk -F/ '{print $1}' | sort -u > "$SPSM_DIR/ime.txt"
}

collect_launchers() {
  pm query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
    | awk '{print $1}' | awk -F/ '{print $1}' | grep -v '^dev.axion.spsm$' | sort -u > "$SPSM_DIR/launchers.txt"
  echo "com.android.launcher3" >> "$SPSM_DIR/launchers.txt"
}

detect_home() {
  h=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | head -1)
  [ -z "$h" ] && h=$(cmd shortcut get-default-home 2>/dev/null | head -1)
  echo "$h"
}

# ---- hardware apply (called from enter + watchdog) ----

ppm_write() {
  w "$1" "$2"
}

apply_ppm_limits() {
  # idx 6 SYS_BOOST off, idx 9 LCM_OFF on (dump: LCM_OFF was disabled)
  ppm_write "6 0" /proc/ppm/policy_status
  ppm_write "9 1" /proc/ppm/policy_status

  # cluster0=6 little, cluster1=0 big
  ppm_write "6 0" /proc/ppm/policy/ut_fix_core_num
  ppm_write "1 0" /proc/ppm/policy/forcelimit_cpu_core

  if screen_is_off; then
    # lowest OPP both clusters (little idx 15 = 500 MHz, big idx 15 = 850 MHz unused)
    ppm_write "15 15" /proc/ppm/policy/ut_fix_freq_idx
    ppm_write "0 $LITTLE_OFF_KHZ" /proc/ppm/policy/hard_userlimit_max_cpu_freq
    ppm_write "0 $LITTLE_OFF_KHZ" /proc/ppm/policy/hard_userlimit_min_cpu_freq
    ppm_write "0 $LITTLE_OFF_KHZ $LITTLE_OFF_KHZ" /proc/ppm/policy/hard_userlimit_cpu_freq
    ppm_write "1 $BIG_MIN_KHZ" /proc/ppm/policy/hard_userlimit_max_cpu_freq
    ppm_write "1 $BIG_MIN_KHZ $BIG_MIN_KHZ" /proc/ppm/policy/hard_userlimit_cpu_freq
  else
    # usable 6-app UI: little 500-850 MHz
    ppm_write "13 15" /proc/ppm/policy/ut_fix_freq_idx
    ppm_write "0 $LITTLE_ON_KHZ" /proc/ppm/policy/hard_userlimit_max_cpu_freq
    ppm_write "0 500000" /proc/ppm/policy/hard_userlimit_min_cpu_freq
    ppm_write "0 500000 $LITTLE_ON_KHZ" /proc/ppm/policy/hard_userlimit_cpu_freq
    ppm_write "1 $BIG_MIN_KHZ" /proc/ppm/policy/hard_userlimit_max_cpu_freq
    ppm_write "1 $BIG_MIN_KHZ $BIG_MIN_KHZ" /proc/ppm/policy/hard_userlimit_cpu_freq
  fi
}

apply_cpu() {
  # Real kernel is 4.19.325 (uname 5.15 is susfs). Do NOT offline A55
  # cores — MTK 4.19 RIL/hotplug often hangs if cpu2-5 go down.
  # A75 cpu6-7 offline is safe and is the big win.
  for n in 6 7; do
    w 0 "/sys/devices/system/cpu/cpu${n}/online"
  done
  for n in 0 1 2 3 4 5; do
    w 1 "/sys/devices/system/cpu/cpu${n}/online"
  done

  if screen_is_off; then
    cap=$LITTLE_OFF_KHZ
  else
    cap=$LITTLE_ON_KHZ
  fi

  # policy0 (little)
  w powersave /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
  w 500000 /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
  w "$cap" /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq

  # policy6 (big) — if still online, pin min
  w powersave /sys/devices/system/cpu/cpufreq/policy6/scaling_governor
  w $BIG_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq
  w $BIG_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq

  # MTK cpufreq power mode (1 = low power on many Helio kernels)
  w 1 /proc/cpufreq/cpufreq_power_mode

  apply_ppm_limits
}

apply_gpu() {
  # Lock Mali at OPP 31 = 300 MHz / 196 mW (dump: OPP0 is 1.2 GHz / 2105 mW)
  w $GPU_MIN_KHZ /proc/gpufreq/gpufreq_opp_freq
  w $GPU_MIN_KHZ /sys/module/ged/parameters/gpu_cust_upbound_freq
  w $GPU_MIN_KHZ /sys/module/ged/parameters/gpu_bottom_freq
  w $GPU_MIN_KHZ /sys/module/ged/parameters/gpu_cust_boost_freq
  w 0 /sys/module/ged/parameters/enable_cpu_boost
  w 0 /sys/module/ged/parameters/enable_gpu_boost
  w 0 /sys/module/ged/parameters/ged_boost_enable
  w 0 /sys/module/ged/parameters/boost_gpu_enable
  w 0 /sys/module/ged/parameters/gx_game_mode
  w 0 /sys/module/ged/parameters/gx_boost_on
  w 0 /sys/module/ged/parameters/gx_force_cpu_boost
  w 0 /sys/module/ged/parameters/ged_smart_boost
  w 0 /sys/module/ged/parameters/is_GED_KPI_enabled
  # keep dvfs enabled so idle can drop; upbound already 300 MHz
  w 1 /sys/module/ged/parameters/gpu_dvfs_enable
}

apply_display() {
  screen_is_off && return 0
  w $BL_SPSM "$BL_PATH"
}

apply_axion_props() {
  setprop persist.sys.activity_anim_perf_override false >/dev/null 2>&1
  setprop persist.sys.perf.scroll_opt false >/dev/null 2>&1
  setprop persist.sys.axion_cpu_fg "0-5" >/dev/null 2>&1
  setprop persist.sys.axion_cpu_limit_ui "0-1" >/dev/null 2>&1
  setprop persist.sys.axion_cpu_svp "0-5" >/dev/null 2>&1
  setprop vendor.powerhal.interaction.max 0 >/dev/null 2>&1
  setprop vendor.powerhal.interaction.min 0 >/dev/null 2>&1
}

GOOGLE_PKGS="
com.google.android.gms
com.google.android.gsf
com.google.android.gsf.login
com.google.android.gms.unstable
com.android.vending
com.google.android.googlequicksearchbox
com.google.android.tts
com.google.android.as
com.google.android.adservices.api
com.google.android.feedback
com.google.android.partnersetup
com.google.android.onetimeinitializer
com.google.android.configupdater
com.google.android.projection.gearhead
com.google.android.apps.restore
"

apply_idle_radios() {
  # Fully ours: Wi-Fi, scans, wakeup. Mobile data stays (VoLTE).
  sput global wifi_scan_always_enabled 0
  sput global ble_scan_always_enabled 0
  sput global wifi_wakeup_enabled 0
  sput secure wifi_wakeup_enabled 0
  sput global network_scoring_ui_enabled 0
  if screen_is_off; then
    svc wifi disable >/dev/null 2>&1
  else
    if [ -f "$STATE_DIR/wifi_on" ]; then
      case "$(cat "$STATE_DIR/wifi_on")" in
        1|true|on) svc wifi enable >/dev/null 2>&1 ;;
      esac
    fi
  fi
}

silence_logs() {
  # Fully ours: kill logd / printk / persist logs. Not using any other module.
  if [ ! -f "$STATE_DIR/printk" ]; then
    cat /proc/sys/kernel/printk > "$STATE_DIR/printk" 2>/dev/null
  fi
  if [ ! -f "$STATE_DIR/logtag" ]; then
    getprop persist.log.tag > "$STATE_DIR/logtag"
  fi
  if [ ! -f "$STATE_DIR/logd_svc" ]; then
    getprop init.svc.logd > "$STATE_DIR/logd_svc"
  fi
  w "0 0 0 0" /proc/sys/kernel/printk
  setprop persist.log.tag S >/dev/null 2>&1
  setprop log.tag S >/dev/null 2>&1
  setprop persist.logd.logpersistd "" >/dev/null 2>&1
  setprop persist.logd.size 65536 >/dev/null 2>&1
  logcat -b all -c >/dev/null 2>&1
  stop logd >/dev/null 2>&1
  stop logd-reinit >/dev/null 2>&1
  stop statsd >/dev/null 2>&1
  stop traced >/dev/null 2>&1
  stop traced_probes >/dev/null 2>&1
  stop dumpstate >/dev/null 2>&1
}

restore_logs() {
  if [ -f "$STATE_DIR/printk" ]; then
    w "$(cat "$STATE_DIR/printk")" /proc/sys/kernel/printk
  else
    w "4 4 1 7" /proc/sys/kernel/printk
  fi
  if [ -f "$STATE_DIR/logtag" ]; then
    tag=$(cat "$STATE_DIR/logtag")
    [ -n "$tag" ] && [ "$tag" != "null" ] && setprop persist.log.tag "$tag" >/dev/null 2>&1
  fi
  start logd >/dev/null 2>&1
  start statsd >/dev/null 2>&1
  start traced >/dev/null 2>&1
}

disable_gms_components() {
  # Extra GMS chimera services (ads, nearby, analytics, wear, fitness, OTA).
  # Independent of any GMS-tweaker module. Restored on exit from the list file.
  [ -f "$STATE_DIR/gms_components_done" ] && return 0
  : > "$STATE_DIR/gms_components"
  for c in \
    com.google.android.gms/com.google.android.gms.nearby.discovery.service.DiscoveryService \
    com.google.android.gms/com.google.android.gms.nearby.messages.service.NearbyMessagesService \
    com.google.android.gms/com.google.android.gms.ads.AdRequestBrokerService \
    com.google.android.gms/com.google.android.gms.ads.identifier.service.AdvertisingIdService \
    com.google.android.gms/com.google.android.gms.analytics.service.AnalyticsService \
    com.google.android.gms/com.google.android.gms.measurement.service.MeasurementBrokerService \
    com.google.android.gms/com.google.android.gms.cast.service.CastDeviceControllerService \
    com.google.android.gms/com.google.android.gms.wearable.service.WearableService \
    com.google.android.gms/com.google.android.gms.fitness.service.FitnessService \
    com.google.android.gms/com.google.android.gms.location.reporting.service.ReportingAndroidService \
    com.google.android.gms/com.google.android.gms.update.SystemUpdateService \
    com.google.android.gms/com.google.android.gms.mdm.receivers.MdmDeviceAdminReceiver \
    com.google.android.gms/com.google.android.gms.auth.setup.devicesignals.LockScreenReceiver \
    com.google.android.gms/com.google.android.gms.checkin.CheckinService \
    com.google.android.gms/com.google.android.location.internal.GoogleLocationManagerService \
    com.google.android.gsf/.checkin.CheckinService \
    com.google.android.gsf/.update.SystemUpdateService
  do
    pm disable "$c" >/dev/null 2>&1 && echo "$c" >> "$STATE_DIR/gms_components"
  done
  echo 1 > "$STATE_DIR/gms_components_done"
}

restore_gms_components() {
  if [ -f "$STATE_DIR/gms_components" ]; then
    while read -r c; do
      [ -n "$c" ] || continue
      pm enable "$c" >/dev/null 2>&1
    done < "$STATE_DIR/gms_components"
  fi
}

freeze_google() {
  # Fully ours: suspend + disable-user Google. No other module required.
  disable_gms_components
  for p in $GOOGLE_PKGS; do
    [ -n "$p" ] || continue
    pm suspend "$p" >/dev/null 2>&1
    am force-stop "$p" >/dev/null 2>&1
    pm disable-user --user 0 "$p" >/dev/null 2>&1
    cmd appops set "$p" RUN_IN_BACKGROUND ignore >/dev/null 2>&1
    cmd appops set "$p" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
    cmd appops set "$p" WAKE_LOCK ignore >/dev/null 2>&1
  done
}

thaw_google() {
  restore_gms_components
  rm -f "$STATE_DIR/gms_components_done"
  for p in $GOOGLE_PKGS; do
    [ -n "$p" ] || continue
    pm enable "$p" >/dev/null 2>&1
    pm unsuspend "$p" >/dev/null 2>&1
    cmd appops set "$p" RUN_IN_BACKGROUND default >/dev/null 2>&1
    cmd appops set "$p" RUN_ANY_IN_BACKGROUND default >/dev/null 2>&1
    cmd appops set "$p" WAKE_LOCK default >/dev/null 2>&1
  done
}

trim_caches() {
  # Independent cache trim (does not depend on any cache-nuker module).
  pm trim-caches 999G >/dev/null 2>&1
}

# RUI SPSM keeps the panel fully asleep: no DT2W / lift-to-wake / AOD.
# Digitizer gesture mode is a real idle-current cost (user confirmed DT2W
# did not work in RUI2/3 super power saving).
WAKE_KEYS="
secure:double_tap_to_wake
secure:tap_to_wake
secure:wake_gesture_enabled
secure:doze_pulse_on_double_tap
secure:doze_pulse_on_pick_up
secure:doze_pulse_on_significant_motion
secure:doze_always_on
system:lift_to_wake
system:double_tap_to_wake
system:double_tap_sleep_gesture
system:double_tap_sleep_lockscreen
system:pocket_judge
"

WAKE_SYSFS="
/proc/touchpanel/double_tap_enable
/proc/touchpanel/gesture_enable
/proc/touchpanel/enable_dt2w
/proc/tp_gesture
/sys/touchpanel/double_tap
/sys/class/touch/tp_gesture
/sys/devices/virtual/touch/tp_dev/gesture_on
/sys/devices/platform/soc/soc:touch/gesture_on
"

save_wake_gestures() {
  [ -f "$STATE_DIR/wake_saved" ] && return 0
  for pair in $WAKE_KEYS; do
    [ -n "$pair" ] || continue
    ns=${pair%%:*}
    key=${pair#*:}
    sget "$ns" "$key" > "$STATE_DIR/wk_${ns}_${key}"
  done
  for f in $WAKE_SYSFS; do
    [ -e "$f" ] || continue
    b=$(echo "$f" | tr '/.' '_')
    cat "$f" > "$STATE_DIR/ws_$b" 2>/dev/null
    echo "$f" >> "$STATE_DIR/wake_sysfs_list"
  done
  echo 1 > "$STATE_DIR/wake_saved"
}

disable_wake_gestures() {
  save_wake_gestures
  sput secure double_tap_to_wake 0
  sput secure tap_to_wake 0
  sput secure wake_gesture_enabled 0
  sput secure doze_pulse_on_double_tap 0
  sput secure doze_pulse_on_pick_up 0
  sput secure doze_pulse_on_significant_motion 0
  sput secure doze_always_on 0
  sput system lift_to_wake 0
  sput system double_tap_to_wake 0
  sput system double_tap_sleep_gesture 0
  sput system double_tap_sleep_lockscreen 0
  sput global wifi_idle_ms 15000
  for f in $WAKE_SYSFS; do
    w 0 "$f"
  done
}

restore_wake_gestures() {
  [ -f "$STATE_DIR/wake_saved" ] || return 0
  for pair in $WAKE_KEYS; do
    [ -n "$pair" ] || continue
    ns=${pair%%:*}
    key=${pair#*:}
    file="$STATE_DIR/wk_${ns}_${key}"
    [ -f "$file" ] || continue
    val=$(cat "$file")
    [ "$val" = "null" ] && continue
    [ -z "$val" ] && continue
    sput "$ns" "$key" "$val"
  done
  if [ -f "$STATE_DIR/wake_sysfs_list" ]; then
    while read -r f; do
      [ -e "$f" ] || continue
      b=$(echo "$f" | tr '/.' '_')
      [ -f "$STATE_DIR/ws_$b" ] && w "$(cat "$STATE_DIR/ws_$b")" "$f"
    done < "$STATE_DIR/wake_sysfs_list"
  fi
}

apply_hw() {
  apply_cpu
  apply_gpu
  apply_display
  apply_idle_radios
  disable_wake_gestures
}

still_on() {
  [ -f "$ACTIVE" ] && [ ! -f "$EXITING" ] && [ ! -f "$DISABLE" ]
}

# AOSP 16 BatterySaverPolicy keys (new + old names) + extras RUI SPSM also kills.
BS_CONSTANTS="advertise_is_enabled=true,disable_vibration=true,disable_animation=true,disable_launch_boost=true,disable_optional_sensors=true,disable_aod=true,enable_quick_doze=true,enable_night_mode=true,enable_datasaver=true,enable_firewall=true,enable_brightness_adjustment=true,adjust_brightness_factor=0.3,force_all_apps_standby=true,force_background_check=true,defer_full_backup=true,defer_keyvalue_backup=true,location_mode=2,soundtrigger_mode=2,vibration_disabled=true,animation_disabled=true,soundtrigger_disabled=true,aod_disabled=true,quick_doze_enabled=true,launch_boost_disabled=true,gps_mode=2,data_saver=true,optional_sensors_disabled=true,fullbackup_deferred=true,keyvaluebackup_deferred=true"

apply_framework_extras() {
  sput global battery_saver_constants "$BS_CONSTANTS"
  sput global low_power 1
  sput global low_power_sticky 1
  sput system accelerometer_rotation 0
  sput system notification_light_pulse 0
  sput secure hotword_detection_enabled 0
  sput global captive_portal_mode 0
  sput global stay_on_while_plugged_in 0
  sput global adaptive_connectivity_enabled 0
  sput global wifi_networks_available_notification_on 0
  sput global mobile_data_always_on 0
  sput global wifi_idle_ms 15000
  sput global wifi_wakeup_enabled 0
  sput secure wifi_wakeup_enabled 0
  sput secure nearby_scanning_enabled 0
  sput global network_scoring_ui_enabled 0
}

enable_quick_doze() {
  cmd wifi set-scan-always-available disabled >/dev/null 2>&1
  cmd connectivity tether stop >/dev/null 2>&1
  # Quick doze, but NEVER force-idle: that can ignore incoming calls.
  dumpsys deviceidle enable >/dev/null 2>&1
  dumpsys deviceidle enable deep >/dev/null 2>&1
  dumpsys deviceidle enable light >/dev/null 2>&1
}

save_framework_extras() {
  [ -f "$STATE_DIR/fw_saved" ] && return 0
  sget system accelerometer_rotation > "$STATE_DIR/fw_rotate"
  sget system notification_light_pulse > "$STATE_DIR/fw_led"
  sget secure hotword_detection_enabled > "$STATE_DIR/fw_hotword"
  sget global captive_portal_mode > "$STATE_DIR/fw_captive"
  sget global stay_on_while_plugged_in > "$STATE_DIR/fw_stayon"
  sget global adaptive_connectivity_enabled > "$STATE_DIR/fw_adapt"
  sget global wifi_networks_available_notification_on > "$STATE_DIR/fw_wifinotify"
  sget global mobile_data_always_on > "$STATE_DIR/fw_mdao"
  sget global nfc_on > "$STATE_DIR/fw_nfc"
  sget global wifi_wakeup_enabled > "$STATE_DIR/fw_wifi_wakeup"
  sget secure nearby_scanning_enabled > "$STATE_DIR/fw_nearby"
  sget global network_scoring_ui_enabled > "$STATE_DIR/fw_scoring"
  echo 1 > "$STATE_DIR/fw_saved"
}

restore_one() {
  [ -f "$STATE_DIR/$3" ] || return 0
  val=$(cat "$STATE_DIR/$3")
  [ "$val" = "null" ] && return 0
  [ -z "$val" ] && return 0
  sput "$1" "$2" "$val"
}

restore_framework_extras() {
  [ -f "$STATE_DIR/fw_saved" ] || return 0
  restore_one system accelerometer_rotation fw_rotate
  restore_one system notification_light_pulse fw_led
  restore_one secure hotword_detection_enabled fw_hotword
  restore_one global captive_portal_mode fw_captive
  restore_one global stay_on_while_plugged_in fw_stayon
  restore_one global adaptive_connectivity_enabled fw_adapt
  restore_one global wifi_networks_available_notification_on fw_wifinotify
  restore_one global mobile_data_always_on fw_mdao
  restore_one global wifi_wakeup_enabled fw_wifi_wakeup
  restore_one secure nearby_scanning_enabled fw_nearby
  restore_one global network_scoring_ui_enabled fw_scoring
  if [ -f "$STATE_DIR/fw_nfc" ]; then
    case "$(cat "$STATE_DIR/fw_nfc")" in
      1|true|on) svc nfc enable >/dev/null 2>&1 ;;
    esac
  fi
  if [ -f "$STATE_DIR/wifi_scan" ]; then
    case "$(cat "$STATE_DIR/wifi_scan")" in
      1|true|on) cmd wifi set-scan-always-available enabled >/dev/null 2>&1 ;;
      *) cmd wifi set-scan-always-available disabled >/dev/null 2>&1 ;;
    esac
  fi
}

save_vm() {
  [ -f "$STATE_DIR/vm_saved" ] && return 0
  cat /proc/sys/vm/dirty_writeback_centisecs > "$STATE_DIR/vm_dirty_wb" 2>/dev/null
  cat /proc/sys/vm/dirty_expire_centisecs > "$STATE_DIR/vm_dirty_exp" 2>/dev/null
  cat /proc/sys/vm/laptop_mode > "$STATE_DIR/vm_laptop" 2>/dev/null
  cat /sys/module/workqueue/parameters/power_efficient > "$STATE_DIR/vm_wq" 2>/dev/null
  cat /proc/sys/kernel/sched_schedstats > "$STATE_DIR/vm_schedstats" 2>/dev/null
  cat /sys/block/mmcblk0/queue/read_ahead_kb > "$STATE_DIR/vm_ra" 2>/dev/null
  echo 1 > "$STATE_DIR/vm_saved"
}

restore_vm() {
  [ -f "$STATE_DIR/vm_saved" ] || return 0
  [ -f "$STATE_DIR/vm_dirty_wb" ] && w "$(cat "$STATE_DIR/vm_dirty_wb")" /proc/sys/vm/dirty_writeback_centisecs
  [ -f "$STATE_DIR/vm_dirty_exp" ] && w "$(cat "$STATE_DIR/vm_dirty_exp")" /proc/sys/vm/dirty_expire_centisecs
  [ -f "$STATE_DIR/vm_laptop" ] && w "$(cat "$STATE_DIR/vm_laptop")" /proc/sys/vm/laptop_mode
  [ -f "$STATE_DIR/vm_wq" ] && w "$(cat "$STATE_DIR/vm_wq")" /sys/module/workqueue/parameters/power_efficient
  [ -f "$STATE_DIR/vm_schedstats" ] && w "$(cat "$STATE_DIR/vm_schedstats")" /proc/sys/kernel/sched_schedstats
  ra=128
  [ -f "$STATE_DIR/vm_ra" ] && ra=$(cat "$STATE_DIR/vm_ra")
  [ -z "$ra" ] && ra=128
  for q in /sys/block/*/queue; do
    w 1 "$q/iostats"
    w "$ra" "$q/read_ahead_kb"
  done
}

restore_ppm() {
  ppm_write "-1 -1" /proc/ppm/policy/ut_fix_core_num
  ppm_write "-1 -1" /proc/ppm/policy/ut_fix_freq_idx
  ppm_write "6 1" /proc/ppm/policy_status
  ppm_write "9 0" /proc/ppm/policy_status
  # clear hard limits: 0 often means unlock on MTK
  ppm_write "0 0" /proc/ppm/policy/hard_userlimit_max_cpu_freq
  ppm_write "1 0" /proc/ppm/policy/hard_userlimit_max_cpu_freq
  ppm_write "0 0" /proc/ppm/policy/hard_userlimit_min_cpu_freq
  ppm_write "1 0" /proc/ppm/policy/hard_userlimit_min_cpu_freq
  ppm_write "0 -1" /proc/ppm/policy/forcelimit_cpu_core
  ppm_write "1 -1" /proc/ppm/policy/forcelimit_cpu_core
}
