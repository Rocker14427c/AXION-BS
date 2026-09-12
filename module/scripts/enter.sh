#!/system/bin/sh
# Enter Super Power Saving — snapshot first, then cheap hardware + 6-app home.
# No package-wide freeze, no logd kill, no deviceidle.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

if [ -f "$DISABLE" ]; then
  log "disable flag present, not entering"
  exit 0
fi

rm -f "$EXITING"
log "===== ENTER SPSM v2 ====="

snapshot_all

# 6-app home first so the user sees the black screen in ~1s
log "switching home"
pm enable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1
cmd role add-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
cmd package set-home-activity "dev.axion.spsm/.SpsmHomeActivity" >/dev/null 2>&1
am start -n dev.axion.spsm/.SpsmHomeActivity -a android.intent.action.MAIN \
  -c android.intent.category.HOME --activity-clear-task >/dev/null 2>&1
service call statusbar 2 >/dev/null 2>&1

touch "$ACTIVE"

# Hardware (seconds, not minutes)
apply_axion_props
apply_hw
disable_dt2w

# Animations off. Do NOT enable AOSP battery saver / data saver —
# that was the yellow "saver" look and extra radio retries.
settings put global animator_duration_scale 0 >/dev/null 2>&1
settings put global transition_animation_scale 0 >/dev/null 2>&1
settings put global window_animation_scale 0 >/dev/null 2>&1
settings put global low_power 0 >/dev/null 2>&1
settings put global low_power_sticky 0 >/dev/null 2>&1
settings delete global battery_saver_constants >/dev/null 2>&1
cmd power set-mode 0 >/dev/null 2>&1
cmd netpolicy set restrict-background false >/dev/null 2>&1
settings put system screen_brightness_mode 0 >/dev/null 2>&1
settings put system screen_off_timeout 15000 >/dev/null 2>&1
settings put system haptic_feedback_enabled 0 >/dev/null 2>&1
settings put global wifi_scan_always_enabled 0 >/dev/null 2>&1
settings put global ble_scan_always_enabled 0 >/dev/null 2>&1
settings put secure doze_always_on 0 >/dev/null 2>&1
settings put global auto_sync 0 >/dev/null 2>&1
# Home is already black — do not flip system night mode (leftover last time)
svc bluetooth disable >/dev/null 2>&1
svc nfc disable >/dev/null 2>&1
svc wifi disable >/dev/null 2>&1
cmd wifi set-scan-always-available disabled >/dev/null 2>&1

# Cached apps only — NOT pm suspend of every package
am kill-all >/dev/null 2>&1
freeze_google

# Do NOT: stop logd, persist.log.tag=S, dumpsys deviceidle, pm list packages

log "===== SPSM ON (logd left running) ====="
echo "cpu=$(cat /sys/devices/system/cpu/online) gov=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)" | tee -a "$LOG"
exit 0
