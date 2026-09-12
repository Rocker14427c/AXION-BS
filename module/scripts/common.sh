#!/system/bin/sh
# RMX3430 Helio G85 — shared helpers for SPSM v2.
# Snapshot-first: never write a node/prop/setting without a backup file.

SPSM_DIR="/data/adb/spsm"
SNAP="$SPSM_DIR/snap"
STATE_DIR="$SPSM_DIR/state"
LOG="$SPSM_DIR/spsm.log"
WHITELIST="$SPSM_DIR/whitelist.txt"
ACTIVE="$SPSM_DIR/active"
DISABLE="$SPSM_DIR/disable"
EXITING="$SPSM_DIR/exiting"
MANIFEST="$SNAP/MANIFEST"

# G85: policy0 A55 cpu0-5 500-1800, policy6 A75 cpu6-7 850-2000
LITTLE_ON_KHZ=850000
LITTLE_OFF_KHZ=850000
LITTLE_MIN_KHZ=500000
LITTLE_MAX_KHZ=1800000
BIG_MIN_KHZ=850000
BIG_MAX_KHZ=2000000
GPU_MIN_KHZ=300000
BL_PATH="/sys/class/leds/lcd-backlight/brightness"
BL_SPSM=160

mkdir -p "$SPSM_DIR" "$SNAP" "$STATE_DIR"

log() {
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line" >> "$LOG" 2>/dev/null
  echo "SPSM: $*" > /dev/kmsg 2>/dev/null
  echo "$line"
  if [ -f "$LOG" ]; then
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 300000 ] && tail -c 120000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

w() {
  [ -n "$2" ] && [ -e "$2" ] || return 0
  echo "$1" > "$2" 2>/dev/null
}

rp() {
  if command -v resetprop >/dev/null 2>&1; then
    resetprop "$1" "$2" >/dev/null 2>&1 && return 0
  fi
  setprop "$1" "$2" >/dev/null 2>&1
}

rpdel() {
  resetprop --delete "$1" >/dev/null 2>&1
  resetprop -p --delete "$1" >/dev/null 2>&1
  setprop "$1" "" >/dev/null 2>&1
}

screen_is_off() {
  bl=$(cat "$BL_PATH" 2>/dev/null)
  [ -z "$bl" ] && bl=1
  [ "$bl" = "0" ]
}

still_on() {
  [ -f "$ACTIVE" ] && [ ! -f "$EXITING" ] && [ ! -f "$DISABLE" ]
}

# ---------- snapshot (never overwrite an existing backup) ----------

snap_sys() {
  # snap_sys name path
  name="$1"; path="$2"
  [ -f "$SNAP/$name" ] && return 0
  if [ ! -e "$path" ]; then
    echo 1 > "$SNAP/$name.missing"
    return 0
  fi
  cat "$path" > "$SNAP/$name" 2>/dev/null
  echo "$path" > "$SNAP/$name.path"
  echo "SYS $name $path" >> "$MANIFEST"
}

restore_sys() {
  name="$1"
  [ -f "$SNAP/$name.missing" ] && return 0
  [ -f "$SNAP/$name" ] || return 0
  path=$(cat "$SNAP/$name.path" 2>/dev/null)
  [ -n "$path" ] && [ -e "$path" ] || return 0
  w "$(cat "$SNAP/$name")" "$path"
}

snap_prop() {
  name="$1"; key="$2"
  [ -f "$SNAP/$name" ] && return 0
  getprop "$key" > "$SNAP/$name" 2>/dev/null
  echo "$key" > "$SNAP/$name.key"
  echo "PROP $name $key" >> "$MANIFEST"
}

restore_prop() {
  name="$1"
  [ -f "$SNAP/$name" ] || return 0
  key=$(cat "$SNAP/$name.key" 2>/dev/null)
  [ -n "$key" ] || return 0
  val=$(cat "$SNAP/$name")
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    rpdel "$key"
  else
    rp "$key" "$val"
  fi
}

snap_set() {
  # snap_set name namespace key default
  name="$1"; ns="$2"; key="$3"; def="$4"
  [ -f "$SNAP/$name" ] && return 0
  val=$(settings get "$ns" "$key" 2>/dev/null)
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    val="$def"
    echo 1 > "$SNAP/$name.defaulted"
  fi
  echo "$val" > "$SNAP/$name"
  echo "$ns $key" > "$SNAP/$name.key"
  echo "SET $name $ns.$key=$val" >> "$MANIFEST"
}

restore_set() {
  name="$1"
  [ -f "$SNAP/$name" ] || return 0
  ns_key=$(cat "$SNAP/$name.key" 2>/dev/null)
  ns=${ns_key%% *}
  key=${ns_key#* }
  val=$(cat "$SNAP/$name")
  [ -z "$ns" ] && return 0
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    settings delete "$ns" "$key" >/dev/null 2>&1
  else
    settings put "$ns" "$key" "$val" >/dev/null 2>&1
  fi
}

# ---------- DT2W nodes (same list as FIX-DT2W.sh) ----------

DT2W_NODES="
/proc/touchpanel/double_tap_enable
/proc/touchpanel/double_tap
/proc/touchpanel/gesture_enable
/proc/touchpanel/enable_dt2w
/proc/tp_gesture
/proc/ilitek/gesture
/proc/ilitek/double_tap
/sys/touchpanel/double_tap
/sys/class/touch/tp_gesture
/sys/class/touch/tp_dev/gesture_on
/sys/devices/virtual/touch/tp_dev/gesture_on
/sys/devices/platform/soc/soc:touch/gesture_on
/sys/class/ms-touchscreen-mtk/device/gesture_wakeup
"

snap_dt2w() {
  [ -f "$SNAP/dt2w_done" ] && return 0
  snap_set dt2w_sec secure double_tap_to_wake 1
  snap_set dt2w_sys system double_tap_to_wake 1
  snap_set dt2w_tap secure tap_to_wake 1
  snap_set dt2w_wg secure wake_gesture_enabled 1
  i=0
  for f in $DT2W_NODES; do
    [ -e "$f" ] || continue
    snap_sys "dt2w_n$i" "$f"
    i=$((i + 1))
  done
  echo "$i" > "$SNAP/dt2w_count"
  echo 1 > "$SNAP/dt2w_done"
}

disable_dt2w() {
  settings put secure double_tap_to_wake 0 >/dev/null 2>&1
  settings put system double_tap_to_wake 0 >/dev/null 2>&1
  settings put secure tap_to_wake 0 >/dev/null 2>&1
  for f in $DT2W_NODES; do
    w 0 "$f"
  done
}

restore_dt2w() {
  restore_set dt2w_sec
  restore_set dt2w_sys
  restore_set dt2w_tap
  restore_set dt2w_wg
  i=0
  cnt=$(cat "$SNAP/dt2w_count" 2>/dev/null)
  [ -n "$cnt" ] || cnt=0
  while [ "$i" -lt "$cnt" ]; do
    restore_sys "dt2w_n$i"
    i=$((i + 1))
  done
}

# ---------- snapshot everything we will touch ----------

snapshot_all() {
  if [ -f "$SNAP/complete" ]; then
    log "snapshot already complete — not overwriting"
    return 0
  fi
  : > "$MANIFEST"
  log "SNAPSHOT begin"

  for n in 0 1 2 3 4 5 6 7; do
    snap_sys "cpu${n}_online" "/sys/devices/system/cpu/cpu${n}/online"
  done
  for pol in 0 6; do
    p=/sys/devices/system/cpu/cpufreq/policy$pol
    snap_sys "pol${pol}_gov" "$p/scaling_governor"
    snap_sys "pol${pol}_min" "$p/scaling_min_freq"
    snap_sys "pol${pol}_max" "$p/scaling_max_freq"
  done
  snap_sys ppm_status /proc/ppm/policy_status
  snap_sys ppm_cores /proc/ppm/policy/ut_fix_core_num
  snap_sys ppm_freqidx /proc/ppm/policy/ut_fix_freq_idx
  snap_sys ppm_forcelimit0_dummy /proc/ppm/policy/forcelimit_cpu_core
  snap_sys cpufreq_power_mode /proc/cpufreq/cpufreq_power_mode
  snap_sys gpu_opp /proc/gpufreq/gpufreq_opp_freq
  snap_sys gpu_upbound /sys/module/ged/parameters/gpu_cust_upbound_freq
  snap_sys gpu_bottom /sys/module/ged/parameters/gpu_bottom_freq
  snap_sys ged_cpu_boost /sys/module/ged/parameters/enable_cpu_boost
  snap_sys ged_gpu_boost /sys/module/ged/parameters/enable_gpu_boost
  snap_sys ged_boost /sys/module/ged/parameters/ged_boost_enable
  snap_sys ged_kpi /sys/module/ged/parameters/is_GED_KPI_enabled
  snap_sys ged_dvfs /sys/module/ged/parameters/gpu_dvfs_enable
  snap_sys bl_value "$BL_PATH"
  snap_sys vm_laptop /proc/sys/vm/laptop_mode
  snap_sys vm_dirty_wb /proc/sys/vm/dirty_writeback_centisecs
  snap_sys vm_dirty_exp /proc/sys/vm/dirty_expire_centisecs

  snap_prop p_anim persist.sys.activity_anim_perf_override
  snap_prop p_scroll persist.sys.perf.scroll_opt
  snap_prop p_fg persist.sys.axion_cpu_fg
  snap_prop p_limit persist.sys.axion_cpu_limit_ui
  snap_prop p_svp persist.sys.axion_cpu_svp
  snap_prop p_big persist.sys.axion_cpu_big
  snap_prop p_small persist.sys.axion_cpu_small
  snap_prop p_hint_max vendor.powerhal.interaction.max
  snap_prop p_hint_min vendor.powerhal.interaction.min
  snap_prop p_logtag persist.log.tag
  snap_prop p_logd_size persist.logd.size

  snap_set anim1 global animator_duration_scale 1
  snap_set anim2 global transition_animation_scale 1
  snap_set anim3 global window_animation_scale 1
  snap_set low_power global low_power 0
  snap_set low_power_sticky global low_power_sticky 0
  snap_set bs_constants global battery_saver_constants ""
  snap_set brightness system screen_brightness 128
  snap_set brightness_mode system screen_brightness_mode 1
  snap_set timeout system screen_off_timeout 30000
  snap_set haptic system haptic_feedback_enabled 1
  snap_set rotate system accelerometer_rotation 1
  snap_set wifi_scan global wifi_scan_always_enabled 1
  snap_set ble_scan global ble_scan_always_enabled 0
  snap_set aod secure doze_always_on 0
  snap_set auto_sync global auto_sync 1
  snap_set bt global bluetooth_on 0
  snap_set wifi_on global wifi_on 1
  snap_set captive global captive_portal_mode 1

  h=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | head -1)
  [ -z "$h" ] && h="com.android.launcher3"
  echo "$h" > "$SNAP/home"
  echo "HOME $h" >> "$MANIFEST"

  snap_dt2w

  echo 1 > "$SNAP/complete"
  log "SNAPSHOT done ($(wc -l < "$MANIFEST" 2>/dev/null) entries)"
  cat "$MANIFEST" >> "$LOG" 2>/dev/null
}

# ---------- apply (SPSM on) ----------

apply_cpu() {
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
  w powersave /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
  w $LITTLE_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
  w "$cap" /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  w powersave /sys/devices/system/cpu/cpufreq/policy6/scaling_governor
  w $BIG_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq
  w $BIG_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
  w 1 /proc/cpufreq/cpufreq_power_mode
  w "6 0" /proc/ppm/policy_status
  w "9 1" /proc/ppm/policy_status
  w "6 0" /proc/ppm/policy/ut_fix_core_num
  w "1 0" /proc/ppm/policy/forcelimit_cpu_core
  w "0 $cap" /proc/ppm/policy/hard_userlimit_max_cpu_freq
  w "0 $LITTLE_MIN_KHZ" /proc/ppm/policy/hard_userlimit_min_cpu_freq
}

apply_gpu() {
  w $GPU_MIN_KHZ /proc/gpufreq/gpufreq_opp_freq
  w $GPU_MIN_KHZ /sys/module/ged/parameters/gpu_cust_upbound_freq
  w $GPU_MIN_KHZ /sys/module/ged/parameters/gpu_bottom_freq
  w 0 /sys/module/ged/parameters/enable_cpu_boost
  w 0 /sys/module/ged/parameters/enable_gpu_boost
  w 0 /sys/module/ged/parameters/ged_boost_enable
  w 0 /sys/module/ged/parameters/is_GED_KPI_enabled
  w 1 /sys/module/ged/parameters/gpu_dvfs_enable
}

apply_wifi() {
  # Whole SPSM session: Wi-Fi off. Mobile data stays (Jio VoLTE).
  svc wifi disable >/dev/null 2>&1
}

apply_axion_props() {
  rp persist.sys.activity_anim_perf_override false
  rp persist.sys.perf.scroll_opt false
  rp persist.sys.axion_cpu_fg "0-5"
  rp persist.sys.axion_cpu_limit_ui "0-1"
  rp persist.sys.axion_cpu_svp "0-5"
  rp vendor.powerhal.interaction.max 0
  rp vendor.powerhal.interaction.min 0
}

apply_hw() {
  apply_cpu
  apply_gpu
  apply_wifi
  if ! screen_is_off; then
    w $BL_SPSM "$BL_PATH"
  fi
}

GOOGLE_PKGS="
com.google.android.gms
com.google.android.gsf
com.google.android.gsf.login
com.android.vending
com.google.android.googlequicksearchbox
com.google.android.tts
com.google.android.as
"

freeze_google() {
  [ -f "$SNAP/google_frozen" ] && return 0
  : > "$SNAP/google_list"
  for p in $GOOGLE_PKGS; do
    [ -n "$p" ] || continue
    echo "$p" >> "$SNAP/google_list"
    pm suspend "$p" >/dev/null 2>&1
    am force-stop "$p" >/dev/null 2>&1
    pm disable-user --user 0 "$p" >/dev/null 2>&1
  done
  echo 1 > "$SNAP/google_frozen"
}

thaw_google() {
  [ -f "$SNAP/google_list" ] || return 0
  while read -r p; do
    [ -n "$p" ] || continue
    pm enable "$p" >/dev/null 2>&1
    pm unsuspend "$p" >/dev/null 2>&1
  done < "$SNAP/google_list"
}

# ---------- restore (SPSM off) — sysfs first, then props, then settings ----------

restore_cpu_defaults() {
  for n in 0 1 2 3 4 5 6 7; do
    w 1 "/sys/devices/system/cpu/cpu${n}/online"
  done
  w schedutil /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
  w $LITTLE_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
  w $LITTLE_MAX_KHZ /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
  w schedutil /sys/devices/system/cpu/cpufreq/policy6/scaling_governor
  w $BIG_MIN_KHZ /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq
  w $BIG_MAX_KHZ /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
  w 0 /proc/cpufreq/cpufreq_power_mode
  w "-1 -1" /proc/ppm/policy/ut_fix_core_num
  w "-1 -1" /proc/ppm/policy/ut_fix_freq_idx
  w "6 1" /proc/ppm/policy_status
  w "9 0" /proc/ppm/policy_status
  w "0 0" /proc/ppm/policy/hard_userlimit_max_cpu_freq
  w "1 0" /proc/ppm/policy/hard_userlimit_max_cpu_freq
  w "0 0" /proc/ppm/policy/hard_userlimit_min_cpu_freq
  w "1 0" /proc/ppm/policy/hard_userlimit_min_cpu_freq
  w "0 -1" /proc/ppm/policy/forcelimit_cpu_core
  w "1 -1" /proc/ppm/policy/forcelimit_cpu_core
}

restore_all() {
  log "RESTORE begin"
  # Always unlock hardware first so a missing snap cannot leave cores offline
  restore_cpu_defaults
  for n in 0 1 2 3 4 5 6 7; do
    restore_sys "cpu${n}_online"
  done
  # cores must be online before gov restore on policy6
  for n in 6 7; do
    w 1 "/sys/devices/system/cpu/cpu${n}/online"
  done
  for pol in 0 6; do
    restore_sys "pol${pol}_gov"
    restore_sys "pol${pol}_min"
    restore_sys "pol${pol}_max"
  done
  # If snap gov was empty/powersave leftover, force schedutil
  gov0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
  [ "$gov0" = "powersave" ] && w schedutil /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
  gov6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_governor 2>/dev/null)
  [ "$gov6" = "powersave" ] && w schedutil /sys/devices/system/cpu/cpufreq/policy6/scaling_governor

  w 0 /proc/gpufreq/gpufreq_opp_freq
  restore_sys gpu_upbound
  [ -f "$SNAP/gpu_upbound" ] || w 1200000 /sys/module/ged/parameters/gpu_cust_upbound_freq
  restore_sys gpu_bottom
  restore_sys ged_cpu_boost
  restore_sys ged_gpu_boost
  restore_sys ged_boost
  restore_sys ged_kpi
  restore_sys ged_dvfs
  w 1 /sys/module/ged/parameters/enable_cpu_boost
  w 1 /sys/module/ged/parameters/enable_gpu_boost
  w 1 /sys/module/ged/parameters/ged_boost_enable
  restore_sys cpufreq_power_mode
  restore_sys vm_laptop
  restore_sys vm_dirty_wb
  restore_sys vm_dirty_exp
  restore_sys bl_value

  restore_prop p_anim
  restore_prop p_scroll
  restore_prop p_fg
  restore_prop p_limit
  restore_prop p_svp
  restore_prop p_big
  restore_prop p_small
  restore_prop p_hint_max
  restore_prop p_hint_min
  # NEVER leave persist.log.tag=S
  rpdel persist.log.tag
  rpdel log.tag
  restore_prop p_logtag
  tagnow=$(getprop persist.log.tag)
  [ "$tagnow" = "S" ] && rpdel persist.log.tag

  restore_set anim1
  restore_set anim2
  restore_set anim3
  restore_set low_power
  restore_set low_power_sticky
  restore_set brightness_mode
  restore_set timeout
  restore_set haptic
  restore_set rotate
  restore_set wifi_scan
  restore_set ble_scan
  restore_set aod
  restore_set auto_sync
  restore_set captive
  if [ -f "$SNAP/bs_constants" ]; then
    val=$(cat "$SNAP/bs_constants")
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      settings delete global battery_saver_constants >/dev/null 2>&1
    else
      settings put global battery_saver_constants "$val" >/dev/null 2>&1
    fi
  else
    settings delete global battery_saver_constants >/dev/null 2>&1
  fi
  # Safe defaults if settings binder failed on enter
  settings put global animator_duration_scale 1 >/dev/null 2>&1
  settings put global transition_animation_scale 1 >/dev/null 2>&1
  settings put global window_animation_scale 1 >/dev/null 2>&1
  settings put global low_power 0 >/dev/null 2>&1
  settings put global low_power_sticky 0 >/dev/null 2>&1

  cmd power set-mode 0 >/dev/null 2>&1
  cmd uimode night no >/dev/null 2>&1
  cmd netpolicy set restrict-background false >/dev/null 2>&1

  if [ -f "$SNAP/bt" ]; then
    case "$(cat "$SNAP/bt")" in
      1|true|on) svc bluetooth enable >/dev/null 2>&1 ;;
    esac
  fi
  if [ -f "$SNAP/wifi_on" ]; then
    case "$(cat "$SNAP/wifi_on")" in
      1|true|on) svc wifi enable >/dev/null 2>&1 ;;
    esac
  fi

  restore_dt2w
  thaw_google

  home=$(cat "$SNAP/home" 2>/dev/null)
  log "restoring home: $home"
  cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
  if [ -n "$home" ] && [ "$home" != "dev.axion.spsm" ]; then
    cmd role add-role-holder android.app.role.HOME "$home" >/dev/null 2>&1
  else
    cmd role add-role-holder android.app.role.HOME com.android.launcher3 >/dev/null 2>&1
    cmd package set-home-activity "com.android.launcher3/.uioverrides.QuickstepLauncher" >/dev/null 2>&1
  fi
  pm disable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1
  am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1

  log "RESTORE sysfs applied"
}

verify_restore() {
  echo "----- VERIFY -----" | tee -a "$LOG"
  echo "cpu.online=$(cat /sys/devices/system/cpu/online)" | tee -a "$LOG"
  echo "cpu6=$(cat /sys/devices/system/cpu/cpu6/online) cpu7=$(cat /sys/devices/system/cpu/cpu7/online)" | tee -a "$LOG"
  echo "gov0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)" | tee -a "$LOG"
  echo "gov6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_governor)" | tee -a "$LOG"
  echo "logd=$(getprop init.svc.logd) persist.log.tag=[$(getprop persist.log.tag)]" | tee -a "$LOG"
  echo "anim=$(settings get global animator_duration_scale 2>/dev/null)" | tee -a "$LOG"
  echo "low_power=$(settings get global low_power 2>/dev/null)" | tee -a "$LOG"
  echo "dt2w=$(settings get secure double_tap_to_wake 2>/dev/null)" | tee -a "$LOG"
  echo "home=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | head -1)" | tee -a "$LOG"
}
