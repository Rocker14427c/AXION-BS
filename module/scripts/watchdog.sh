#!/system/bin/sh
# Re-assert SPSM limits. PowerHAL and GMS love to undo them.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

[ -f "$ACTIVE" ] || exit 0
[ -f "$DISABLE" ] && { sh "$SCRIPT_DIR/exit.sh"; exit 0; }

# big cores stay offline
for n in 6 7 8 9; do
  [ -f /sys/devices/system/cpu/cpu$n/online ] || continue
  cur=$(cat /sys/devices/system/cpu/cpu$n/online 2>/dev/null)
  [ "$cur" = "0" ] || w 0 /sys/devices/system/cpu/cpu$n/online
done

# freq caps (files may have been chmod'd 444 already)
for cpu in /sys/devices/system/cpu/cpu0 /sys/devices/system/cpu/cpu1 /sys/devices/system/cpu/cpu2 /sys/devices/system/cpu/cpu3 /sys/devices/system/cpu/cpu4 /sys/devices/system/cpu/cpu5; do
  [ -f "$cpu/cpufreq/scaling_max_freq" ] || continue
  cap=$(pick_freq_cap 1150000 "$cpu/cpufreq/scaling_available_frequencies")
  cur=$(cat "$cpu/cpufreq/scaling_max_freq" 2>/dev/null)
  if [ -n "$cap" ] && [ "$cur" != "$cap" ]; then
    chmod 644 "$cpu/cpufreq/scaling_max_freq" 2>/dev/null
    w "$cap" "$cpu/cpufreq/scaling_max_freq"
    chmod 444 "$cpu/cpufreq/scaling_max_freq" 2>/dev/null
  fi
done

settings put global low_power 1 >/dev/null 2>&1
settings put global low_power_sticky 1 >/dev/null 2>&1

# doze when screen is off
if dumpsys power 2>/dev/null | grep -Eq 'mWakefulness=(Asleep|Dozing)'; then
  dumpsys deviceidle force-idle >/dev/null 2>&1
else
  dumpsys deviceidle unforce >/dev/null 2>&1
fi

# re-suspend third-party apps that are not in the 6-app list
pm list packages -3 2>/dev/null | sed 's/package://' | while read -r pkg; do
  [ -n "$pkg" ] || continue
  is_protected "$pkg" && continue
  pm suspend "$pkg" >/dev/null 2>&1
done

exit 0
