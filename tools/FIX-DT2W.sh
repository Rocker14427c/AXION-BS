#!/system/bin/sh
# Restore Double-Tap-to-Wake after SPSM v1.8 wrote 0 to gesture nodes + settings.
# Run as root (ResukiSU):  su -c 'sh /sdcard/FIX-DT2W.sh'
# Paste the whole output back if DT2W still fails.

echo "===== DT2W FIX start ====="
echo "uid=$(id -u)"
if [ "$(id -u)" != "0" ]; then
  echo "NOT ROOT. Asking su..."
  exec su -c "sh \"$0\""
fi

echo "kernel=$(uname -r)"
echo "rom=$(getprop ro.axion.version 2>/dev/null) $(getprop ro.lineage.version 2>/dev/null)"

# --- 1. Settings (these persist; v1.8 left them at 0) ---
echo "--- settings BEFORE ---"
for ns in secure system global; do
  for k in double_tap_to_wake tap_to_wake wake_gesture_enabled \
           doze_pulse_on_double_tap doze_pulse_on_pick_up \
           lift_to_wake double_tap_sleep_gesture; do
    v=$(settings get "$ns" "$k" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "null" ] && echo "  $ns.$k=$v"
  done
done

settings put secure double_tap_to_wake 1
settings put system double_tap_to_wake 1
settings put secure tap_to_wake 1
settings put secure wake_gesture_enabled 1
settings put system lift_to_wake 0
# DT2W is panel wake, not AOD pulse
settings put secure doze_always_on 0

echo "--- settings AFTER ---"
echo "  secure.double_tap_to_wake=$(settings get secure double_tap_to_wake 2>/dev/null)"
echo "  system.double_tap_to_wake=$(settings get system double_tap_to_wake 2>/dev/null)"
echo "  secure.tap_to_wake=$(settings get secure tap_to_wake 2>/dev/null)"

# --- 2. Known Realme / MTK / Lineage / Ilitek nodes ---
NODES="
/proc/touchpanel/double_tap_enable
/proc/touchpanel/double_tap
/proc/touchpanel/gesture_enable
/proc/touchpanel/enable_dt2w
/proc/touchpanel/oppo_tp_limit_enable
/proc/tp_gesture
/proc/android_touch/gesture
/proc/android_touch/SMWP
/proc/ilitek/gesture
/proc/ilitek/double_tap
/proc/ilitek/gesture_mode
/sys/touchpanel/double_tap
/sys/class/touch/tp_gesture
/sys/class/touch/tp_dev/gesture_on
/sys/devices/virtual/touch/tp_dev/gesture_on
/sys/devices/platform/soc/soc:touch/gesture_on
/sys/class/sec/tsp/cmd
/sys/class/ms-touchscreen-mtk/device/gesture_wakeup
/sys/devices/virtual/input/input0/wake_gesture
/sys/devices/virtual/input/input1/wake_gesture
/sys/devices/virtual/input/input2/wake_gesture
/sys/devices/virtual/input/input3/wake_gesture
/sys/module/touchscreen/parameters/dt2w
"

echo "--- sysfs/proc (exist + write 1) ---"
found=0
for f in $NODES; do
  [ -e "$f" ] || continue
  found=1
  before=$(cat "$f" 2>/dev/null | tr '\n' ' ')
  echo 1 > "$f" 2>/dev/null
  after=$(cat "$f" 2>/dev/null | tr '\n' ' ')
  echo "  $f"
  echo "    before=[$before] after=[$after] writable=$( [ -w "$f" ] && echo yes || echo no )"
done

# Wake-gesture files under input
echo "--- extra *gesture* / *dt2w* nodes ---"
for f in \
  /proc/touchpanel/* \
  /proc/ilitek/* \
  /sys/class/touch/*/* \
  /sys/devices/virtual/touch/*/* \
  /proc/android_touch/*
do
  [ -e "$f" ] || continue
  case "$f" in
    *gesture*|*dt2w*|*double*|*tap*|*wake*|*SMWP*|*smwp*)
      before=$(cat "$f" 2>/dev/null | tr '\n' ' ' | cut -c1-80)
      echo 1 > "$f" 2>/dev/null
      echo "  $f = [$before]"
      found=1
      ;;
  esac
done

if [ "$found" = "0" ]; then
  echo "  NO gesture sysfs node found. DT2W is settings-only on this kernel,"
  echo "  or the node is under a path we did not list (paste this log)."
fi

# Lineage / Axion touch HAL if present
if getprop | grep -qi 'lineage.touch\|vendor.lineage.touch'; then
  echo "--- lineage touch HAL present ---"
  getprop | grep -i touch
fi

echo "--- input devices ---"
cat /proc/bus/input/devices 2>/dev/null | grep -E 'Name=|Handlers=' | head -40

echo "===== DT2W FIX done ====="
echo "Now: screen OFF, double-tap the panel (not the fingerprint)."
echo "If still dead: Settings → Display → look for Tap to wake / Double tap to wake → ON."
echo "Then paste this whole output."
