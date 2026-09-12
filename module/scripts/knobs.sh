#!/system/bin/sh
# Axion SPSM v3 - the knob registry.
#
# Every single thing SPSM is allowed to change is declared here as a knob with
# three functions:
#
#   meta_<id>        category|label|description|default|scope|tags
#   snapshot_<id>    print the current value(s), one "target<TAB>value" per line
#   apply_<id>       make the change
#   restore_<id> F   put back whatever file F holds (F is a saved snapshot)
#
# scope=session  -> applied for the whole time SPSM is on
# scope=deep     -> applied only while the screen is off, undone on wake
#
# Values are addressed with a small target syntax so one generic snapshot/apply
# path covers sysfs nodes, Settings rows and properties:
#
#   /sys/...          sysfs or procfs node
#   @ns:key           Settings row (ns = global|secure|system)
#   %prop.name        system property
#
# The APK reads this same list (engine.sh dump-knobs writes knobs.list) so the
# options screen can never drift from what the scripts actually do.

# ------------------------------------------------------------------ targets
kv_read() { # kv_read target -> value, or (MISSING)
  case "$1" in
    /*) exists "$1" || { printf '(MISSING)'; return; }
        _v=$(rd "$1"); printf '%s' "$_v" ;;
    @*) _ns=${1#@}; _ns=${_ns%%:*}; _key=${1#*:}
        _v=$(sget "$_ns" "$_key" 2>/dev/null)
        [ -z "$_v" ] && _v=null
        printf '%s' "$_v" ;;
    %*) _v=$(gprop "${1#%}"); printf '%s' "$_v" ;;
    *)  printf '(MISSING)' ;;
  esac
}

kv_write() { # kv_write target value
  case "$1" in
    /*) exists "$1" || return 1; w "$2" "$1" ;;
    @*) _ns=${1#@}; _ns=${_ns%%:*}; _key=${1#*:}
        if [ "$2" = "null" ] || [ -z "$2" ]; then sdel "$_ns" "$_key"; else sput "$_ns" "$_key" "$2"; fi ;;
    %*) if [ -z "$2" ]; then dprop "${1#%}"; else sprop "${1#%}" "$2"; fi ;;
    *)  return 1 ;;
  esac
}

# Print "target<TAB>value" for each target, so restore_kv can rebuild it.
snap_kv() {
  for _t in "$@"; do
    [ -n "$_t" ] || continue
    printf '%s\t%s\n' "$_t" "$(kv_read "$_t")"
  done
}

# Apply "target=value" pairs, splitting on the FIRST '=' only.
apply_kv() {
  for _pair in "$@"; do
    _t=${_pair%%=*}
    _v=${_pair#*=}
    kv_write "$_t" "$_v"
  done
}

# Restore from a snapshot file produced by snap_kv.
#
#   restore_kv <orig-file> [<applied-file>]
#
# Values that are (MISSING) are skipped: the node did not exist when we
# started, so there is nothing to put back - writing to a node that was never
# there is how a revert "succeeds" while leaving the device changed.
#
# When the applied snapshot is supplied, the decision is made PER TARGET: a
# value is only written back if the live value is still the one we set. Two
# knobs that happen to share a target (wifi_off and scan_always_off both look
# at wifi_scan_always_enabled) therefore cannot make each other look
# "externally changed", and a change the user made after us is still respected.
restore_kv() {
  [ -f "$1" ] || return 0
  while IFS='	' read -r _t _v || [ -n "$_t" ]; do
    [ -n "$_t" ] || continue
    [ "$_v" = "(MISSING)" ] && continue
    if [ -f "$2" ]; then
      _was=$(snap_get "$(cat "$2" 2>/dev/null)" "$_t")
      _cur=$(kv_read "$_t")
      # Still ours to undo? If not, a newer value wins.
      [ -n "$_was" ] && [ "$_cur" != "$_was" ] && continue
    fi
    kv_write "$_t" "$_v"
  done < "$1"
}

# ------------------------------------------------------------------ node sets
# RMX3430 / Helio G85 shared DT2W + gesture nodes (same list as FIX-DT2W.sh).
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
DT2W_SETTINGS="@secure:double_tap_to_wake @system:double_tap_to_wake @secure:tap_to_wake @secure:wake_gesture_enabled"

GED_PARAMS=/sys/module/ged/parameters

# ============================================================ Display / UI

meta_home_swap() {
  echo "Display|Black 6-app home|Swaps the launcher for the SPSM home screen while the mode is on, and restores your launcher on exit.|1|session|core"
}
snapshot_home_swap() {
  printf 'home\t%s\n' "$(home_holder)"
  # The role holder is not the only thing that decides what HOME opens: the
  # package manager also stores a configured home activity, and leaving that
  # pointing at us would send the next HOME press to a disabled activity.
  _act=$(cmd package resolve-activity --brief -c android.intent.category.HOME 2>/dev/null | tail -1)
  printf 'activity\t%s\n' "${_act:-none}"
  _en=$(cmd package get-component-enabled-setting dev.axion.spsm/.SpsmHomeActivity 2>/dev/null | tail -1)
  printf 'component\t%s\n' "${_en:-DEFAULT}"
}
apply_home_swap() {
  pm enable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1
  set_home dev.axion.spsm
  launch_home
}
restore_home_swap() {
  _orig=$(sed -n 's/^home	//p' "$1" 2>/dev/null | head -1)
  _act=$(sed -n 's/^activity	//p' "$1" 2>/dev/null | head -1)
  _comp=$(sed -n 's/^component	//p' "$1" 2>/dev/null | head -1)

  cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
  if [ -n "$_orig" ] && [ "$_orig" != "dev.axion.spsm" ]; then
    set_home "$_orig"
  else
    set_home com.android.launcher3
  fi
  # Put back the exact home activity that was configured before, if we have it.
  if [ -n "$_act" ] && [ "$_act" != "none" ]; then
    cmd package set-home-activity "$_act" >/dev/null 2>&1
  fi
  # Only re-disable our activity if it was not already explicitly enabled.
  case "$_comp" in
    ENABLED*|enabled*) : ;;
    *) pm disable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1 ;;
  esac
  launch_home
}

meta_dt2w_off() {
  echo "Display|Double-tap to wake|Puts the touch panel to sleep so taps and swipes cannot wake the phone. The power button still works.|1|session|battery"
}
snapshot_dt2w_off() { snap_kv $DT2W_SETTINGS $DT2W_NODES; }
apply_dt2w_off() { apply_kv "@secure:double_tap_to_wake=0" "@system:double_tap_to_wake=0" "@secure:tap_to_wake=0"; for _f in $DT2W_NODES; do w 0 "$_f"; done; }
restore_dt2w_off() { restore_kv "$1" "$2"; }

meta_aod_off() {
  echo "Display|Always-on display|Turns off the ambient/AOD panel so the screen stays fully off between wake-ups.|1|session|battery"
}
snapshot_aod_off() { snap_kv @secure:doze_always_on @secure:doze_enabled @system:doze_always_on /sys/devices/platform/soc/soc:mtk-tb/ambient_enable; }
apply_aod_off() { apply_kv "@secure:doze_always_on=0" "@secure:doze_enabled=0" "@system:doze_always_on=0"; }
restore_aod_off() { restore_kv "$1" "$2"; }

meta_brightness_cap() {
  echo "Display|Dim the screen|Sets a low fixed backlight so SPSM looks like realme's dark mode. Set once and left alone - it will not fight your brightness slider.|1|session|battery"
}
snapshot_brightness_cap() { snap_kv "$BL_PATH" @system:screen_brightness @system:screen_brightness_mode; }
apply_brightness_cap() {
  _cap=$(cfg brightness_cap 160)
  snap_val=$(rd "$BL_PATH")
  if [ -n "$snap_val" ] && [ "$snap_val" != "0" ]; then
    w "$_cap" "$BL_PATH"
  fi
  sput system screen_brightness_mode 0
}
restore_brightness_cap() { restore_kv "$1" "$2"; }

meta_timeout_short() {
  echo "Display|15 second screen timeout|Screen turns off quickly after you stop using it, which is where most idle power is saved.|1|session|battery"
}
snapshot_timeout_short() { snap_kv @system:screen_off_timeout; }
apply_timeout_short() { apply_kv "@system:screen_off_timeout=$(cfg timeout_ms 15000)"; }
restore_timeout_short() { restore_kv "$1" "$2"; }

meta_animations_off() {
  echo "Display|Turn off animations|Disables window/transition/animator animations so the light UI feels responsive on capped hardware.|1|session|perf"
}
snapshot_animations_off() { snap_kv @global:animator_duration_scale @global:transition_animation_scale @global:window_animation_scale; }
apply_animations_off() { apply_kv "@global:animator_duration_scale=0" "@global:transition_animation_scale=0" "@global:window_animation_scale=0"; }
restore_animations_off() { restore_kv "$1" "$2"; }

meta_haptic_off() {
  echo "Display|Turn off vibration|Stops haptic feedback motor use.|1|session|battery"
}
snapshot_haptic_off() { snap_kv @system:haptic_feedback_enabled @system:vibrate_on; }
apply_haptic_off() { apply_kv "@system:haptic_feedback_enabled=0" "@system:vibrate_on=0"; }
restore_haptic_off() { restore_kv "$1" "$2"; }

meta_rotate_lock() {
  echo "Display|Lock rotation|Keeps the portrait layout, so the (unused) rotation sensor stops waking the CPU.|0|session|experimental"
}
snapshot_rotate_lock() { snap_kv @system:accelerometer_rotation; }
apply_rotate_lock() { apply_kv "@system:accelerometer_rotation=0"; }
restore_rotate_lock() { restore_kv "$1" "$2"; }

# ============================================================ Radio / network

meta_wifi_off() {
  echo "Radio|Turn off Wi-Fi|Wi-Fi is the biggest idle talker. Mobile data stays on so calls, SMS and VoLTE keep working.|1|session|battery"
}
snapshot_wifi_off() { snap_kv @global:wifi_on @global:wifi_scan_always_enabled; }
apply_wifi_off() {
  has svc && svc wifi disable >/dev/null 2>&1
  has cmd && cmd wifi set-wifi-enabled disabled >/dev/null 2>&1
}
restore_wifi_off() {
  restore_kv "$1" "$2"
  _on=$(sed -n 's/^@global:wifi_on	//p' "$1" 2>/dev/null | head -1)
  case "$_on" in
    1|true|on) has svc && svc wifi enable >/dev/null 2>&1
               has cmd && cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 ;;
  esac
}

meta_bt_off() {
  echo "Radio|Turn off Bluetooth|Bluetooth scanning and connections are stopped for the session.|1|session|battery"
}
snapshot_bt_off() { snap_kv @global:bluetooth_on; }
apply_bt_off() { has svc && svc bluetooth disable >/dev/null 2>&1; }
restore_bt_off() {
  restore_kv "$1" "$2"
  _on=$(sed -n 's/^@global:bluetooth_on	//p' "$1" 2>/dev/null | head -1)
  case "$_on" in 1|true|on) has svc && svc bluetooth enable >/dev/null 2>&1 ;; esac
}

meta_nfc_off() {
  echo "Radio|Turn off NFC|Stops the NFC controller polling.|1|session|battery"
}
snapshot_nfc_off() { snap_kv @global:nfc_on; }
apply_nfc_off() { has svc && svc nfc disable >/dev/null 2>&1; }
restore_nfc_off() {
  restore_kv "$1" "$2"
  _on=$(sed -n 's/^@global:nfc_on	//p' "$1" 2>/dev/null | head -1)
  case "$_on" in 1|true|on) has svc && svc nfc enable >/dev/null 2>&1 ;; esac
}

meta_scan_always_off() {
  echo "Radio|Stop background scanning|Stops Wi-Fi/BLE always-scan, which wakes the radio in the middle of the night.|1|session|battery"
}
snapshot_scan_always_off() {
  snap_kv @global:wifi_scan_always_enabled @global:ble_scan_always_enabled @global:network_recommendations_enabled
}
apply_scan_always_off() {
  apply_kv "@global:wifi_scan_always_enabled=0" "@global:ble_scan_always_enabled=0" "@global:network_recommendations_enabled=0"
  has cmd && cmd wifi set-scan-always-available disabled >/dev/null 2>&1
}
restore_scan_always_off() { restore_kv "$1" "$2"; }

meta_location_off() {
  echo "Radio|Turn off location|Stops GNSS and location providers. Maps and weather will not update until you exit.|0|session|breaks-features"
}
snapshot_location_off() { snap_kv @secure:location_mode @secure:location_providers_allowed; }
apply_location_off() {
  apply_kv "@secure:location_mode=0"
  has cmd && cmd location set-location-enabled false >/dev/null 2>&1
}
restore_location_off() {
  restore_kv "$1" "$2"
  _m=$(sed -n 's/^@secure:location_mode	//p' "$1" 2>/dev/null | head -1)
  case "$_m" in 3|1|true) has cmd && cmd location set-location-enabled true >/dev/null 2>&1 ;; esac
}

# ============================================================ Processor / GPU

meta_cpu_cap() {
  echo "Processor|Cap the CPU while idle|Lowers the maximum frequency of both clusters while the screen is off. Nothing is taken offline, so wake-up stays instant.|1|deep|battery"
}
snapshot_cpu_cap() {
  snap_kv /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
          /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq \
          /sys/devices/system/cpu/cpufreq/policy6/scaling_governor \
          /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq \
          /proc/cpufreq/cpufreq_power_mode
}
apply_cpu_cap() {
  # Cache the top of each cluster and cap below it; never touch scaling_min_freq,
  # because a high floor plus a powersave governor was exactly what pinned the
  # little cluster at 500 MHz for the whole session in v2.
  for _p in 0 6; do
    _d=/sys/devices/system/cpu/cpufreq/policy$_p
    [ -d "$(rp "$_d")" ] || continue
    _max=$(rd "$_d/cpuinfo_max_freq")
    [ -n "$_max" ] || _max=$(rd "$_d/scaling_max_freq")
    case "$_p" in
      0) _target=$(cfg cpu_little_cap_khz 1100000) ;;
      6) _target=$(cfg cpu_big_cap_khz 1300000) ;;
    esac
    # Only ever lower the ceiling, never raise it.
    if [ -n "$_max" ] && [ "$_target" -gt "$_max" ] 2>/dev/null; then
      _target=$_max
    fi
    w "$_target" "$_d/scaling_max_freq"
  done
  w 1 /proc/cpufreq/cpufreq_power_mode
}
restore_cpu_cap() { restore_kv "$1" "$2"; }

meta_cpu_offline_big() {
  echo "Processor|Take the big cores offline|Powers down the two Cortex-A75 cores entirely. Bigger saving, but the phone feels slower if anything wakes it. Experimental.|0|deep|experimental"
}
snapshot_cpu_offline_big() {
  snap_kv /sys/devices/system/cpu/cpu6/online /sys/devices/system/cpu/cpu7/online
}
apply_cpu_offline_big() {
  w 0 /sys/devices/system/cpu/cpu7/online
  w 0 /sys/devices/system/cpu/cpu6/online
}
restore_cpu_offline_big() {
  # Faithful restore: whatever the cores were doing before SPSM is what they
  # should be doing after. engine.sh's verify catches it if that fails.
  restore_kv "$1" "$2"
}

meta_gpu_cap() {
  echo "Processor|Cap the GPU while idle|Holds the Mali GPU at its lowest step when the screen is off.|1|deep|battery"
}
snapshot_gpu_cap() {
  snap_kv /proc/gpufreq/gpufreq_opp_freq \
          $GED_PARAMS/gpu_cust_upbound_freq \
          $GED_PARAMS/gpu_bottom_freq \
          $GED_PARAMS/gpu_dvfs_enable
}
apply_gpu_cap() {
  _g=$(cfg gpu_cap_khz 300000)
  w "$_g" /proc/gpufreq/gpufreq_opp_freq
  w "$_g" $GED_PARAMS/gpu_cust_upbound_freq
  w "$_g" $GED_PARAMS/gpu_bottom_freq
}
restore_gpu_cap() { restore_kv "$1" "$2"; }

meta_ged_boost_off() {
  echo "Processor|Disable GED boosts|Stops MediaTek's scheduler from raising CPU/GPU clocks for touch and scrolling while the screen is off.|1|deep|battery"
}
snapshot_ged_boost_off() {
  snap_kv $GED_PARAMS/enable_cpu_boost $GED_PARAMS/enable_gpu_boost \
          $GED_PARAMS/ged_boost_enable $GED_PARAMS/is_GED_KPI_enabled
}
apply_ged_boost_off() {
  apply_kv "$GED_PARAMS/enable_cpu_boost=0" "$GED_PARAMS/enable_gpu_boost=0" "$GED_PARAMS/ged_boost_enable=0"
}
restore_ged_boost_off() { restore_kv "$1" "$2"; }

# ============================================================ Apps

meta_app_restrict() {
  echo "Apps|Restrict background apps|While the screen is off, moves apps that are not in your list into a restricted standby bucket and denies background running. Jobs and alarms are deferred, not cancelled, and everything is put back when you wake the phone.|1|deep|battery"
}
snapshot_app_restrict() {
  # Snapshot is just the set of packages we manage: if that set still matches
  # on restore, our per-app values are still the ones in the sub-journal.
  echo "$(managed_packages | tr '\n' ' ')"
}
apply_app_restrict() {
  _bucket=$(cfg bucket_level restricted)
  case "$_bucket" in restricted|rare|frequent) ;; *) _bucket=restricted ;; esac
  _list="$ORIG_DIR/app_restrict.tsv"
  : > "$_list"
  managed_packages | while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    _ob=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
    [ -n "$_ob" ] || _ob=-
    _oo=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
          | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
    [ -n "$_oo" ] || _oo=-
    [ "$_ob" = "-" ] && [ "$_oo" = "-" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_bucket" "$_oo" "deny" >> "$_list"
    [ "$_ob" != "-" ] && am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
    [ "$_oo" != "-" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
  done
}
restore_app_restrict() {
  _list="$ORIG_DIR/app_restrict.tsv"
  [ -f "$_list" ] || return 0
  while IFS='	' read -r _pkg _ob _nb _oo _no || [ -n "$_pkg" ]; do
    [ -n "$_pkg" ] || continue
    if [ "$_ob" != "-" ]; then
      _now=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
      # Only undo our own change: if the system or the user moved it since,
      # that newer decision wins.
      [ "$_now" = "$_nb" ] && am set-standby-bucket "$_pkg" "$_ob" >/dev/null 2>&1
    fi
    if [ "$_oo" != "-" ]; then
      _now=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
             | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
      [ "$_now" = "$_no" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND "$_oo" >/dev/null 2>&1
    fi
  done < "$_list"
}

meta_freeze_google() {
  echo "Apps|Sleep Google Play services|Suspends and force-stops Play services, Play Store and Search. Big saving, but WhatsApp-style push notifications will not arrive until you open the app.|0|deep|breaks-features"
}
GOOGLE_PKGS="com.google.android.gms com.google.android.gsf com.android.vending com.google.android.googlequicksearchbox com.google.android.gms.location.history"
snapshot_freeze_google() {
  _f="$ORIG_DIR/google_state.tsv"
  : > "$_f"
  for _p in $GOOGLE_PKGS; do
    _en=$(dumpsys package "$_p" 2>/dev/null | sed -n 's/^ *enabled=\([a-z]*\).*/\1/p' | head -1)
    [ -n "$_en" ] || continue
    printf '%s\t%s\n' "$_p" "$_en" >> "$_f"
    printf '%s\t%s\n' "$_p" "$_en"
  done
}
apply_freeze_google() {
  for _p in $GOOGLE_PKGS; do
    pm suspend "$_p" >/dev/null 2>&1
    am force-stop "$_p" >/dev/null 2>&1
  done
}
restore_freeze_google() {
  restore_kv "$1" "$2"
  for _p in $GOOGLE_PKGS; do
    pm unsuspend "$_p" >/dev/null 2>&1
    pm enable "$_p" >/dev/null 2>&1
  done
  pm enable --user 0 com.google.android.gms >/dev/null 2>&1
}

# ============================================================ Doze / power

meta_deep_doze() {
  echo "Power|Force deep doze while asleep|Puts the device into Doze the moment the screen goes off instead of waiting for the system timers, and releases it the instant you wake it. The single biggest idle saving. Background apps cannot poll while you sleep, so turn this off if you rely on them reaching you with the screen off.|1|deep|battery,breaks-features"
}
snapshot_deep_doze() {
  _st=$(dumpsys deviceidle 2>/dev/null | sed -n 's/.*mState=\([A-Z_]*\).*/\1/p' | head -1)
  printf 'deviceidle\t%s\n' "${_st:-UNKNOWN}"
}
apply_deep_doze() {
  dumpsys deviceidle force-idle deep >/dev/null 2>&1 && touch "$STATE/doze_forced"
}
restore_deep_doze() {
  # unforce is harmless even if nothing was forced, so it always runs: leaving
  # the device stuck in forced idle would kill every notification.
  has dumpsys && dumpsys deviceidle unforce >/dev/null 2>&1
  # Stepping the state machine is a change of its own, so only do it when we are
  # the ones who forced it - otherwise this knob would nudge the power state of
  # a phone that was minding its own business.
  if [ -f "$STATE/doze_forced" ]; then
    has cmd && cmd deviceidle step >/dev/null 2>&1
  fi
  rm -f "$STATE/doze_forced"
}

meta_battery_saver() {
  echo "Power|Android battery saver|Turns on the ROM's own battery saver. On this device it tints the UI and does not save much beyond what SPSM already does.|0|session|experimental"
}
snapshot_battery_saver() { snap_kv @global:low_power @global:low_power_sticky @global:battery_saver_constants; }
apply_battery_saver() { apply_kv "@global:low_power=1" "@global:low_power_sticky=1"; }
restore_battery_saver() { restore_kv "$1" "$2"; sdel global battery_saver_constants; }

meta_sync_off() {
  echo "Power|Stop account sync|Background account sync stops, so mail and contacts do not refresh until you exit.|0|session|breaks-features"
}
snapshot_sync_off() { snap_kv @global:auto_sync; }
apply_sync_off() { apply_kv "@global:auto_sync=0"; }
restore_sync_off() { restore_kv "$1" "$2"; }

# ============================================================ registry
# Order matters: cheapest and most visible first, and the deep system-wide
# switches last, so that a failure part-way through never leaves the phone
# without a working launcher or CPU.

KNOBS="
home_swap
dt2w_off
aod_off
brightness_cap
timeout_short
animations_off
haptic_off
rotate_lock
wifi_off
bt_off
nfc_off
scan_always_off
location_off
ged_boost_off
gpu_cap
cpu_cap
cpu_offline_big
app_restrict
freeze_google
deep_doze
sync_off
battery_saver
"

knobs_all() { for k in $KNOBS; do echo "$k"; done; }

# Membership test. knobs_all prints one knob per line, so a
#   case " $(knobs_all) " in *" $k "*) ...
# test can never match: the command substitution keeps its newlines and the
# knobs are never surrounded by spaces. Always ask this function instead.
knob_exists() { # knob_exists id
  for _e in $KNOBS; do [ "$_e" = "$1" ] && return 0; done
  return 1
}

knob_meta() { # knob_meta id -> category|label|desc|default|scope|tags
  _fn="meta_$1"
  if command -v "$_fn" >/dev/null 2>&1 || type "$_fn" >/dev/null 2>&1; then
    "$_fn"
  else
    echo "Other|$1|(no description)|0|session|"
  fi
}

knob_scope() {
  knob_meta "$1" | awk -F'|' '{print $5}'
}
knob_default() {
  knob_meta "$1" | awk -F'|' '{print $4}'
}

# ------------------------------------------------------------------ app list
# Which packages are we allowed to restrict? Third-party apps, minus anything
# the user pinned, minus anything Android already exempts from battery
# optimisation, minus the things that must keep working (calls, SMS, alarms,
# the root manager itself, and our own app).
ESSENTIALS="com.android.dialer com.android.server.telecom com.android.mms com.android.messaging com.google.android.apps.messaging com.android.providers.telephony com.android.phone com.android.deskclock com.android.systemui dev.axion.spsm com.topjohnwu.magisk me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra"

managed_packages() {
  _keep=" $(cfg keep '') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') "
  _keep="$_keep $ESSENTIALS "
  _exempt=$(dumpsys deviceidle whitelist 2>/dev/null | sed -n 's/^ *[a-z-]*,\([a-zA-Z0-9_.]*\),.*/\1/p' | sort -u)
  _all=$(pm list packages -3 2>/dev/null | sed 's/^package://')
  for _p in $_all; do
    [ -n "$_p" ] || continue
    case "$_keep" in *" $_p "*) continue ;; esac
    echo "$_exempt" | grep -qxF "$_p" && continue
    echo "$_p"
  done
}
