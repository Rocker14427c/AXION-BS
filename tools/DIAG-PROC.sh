#!/bin/sh
# Read-only diagnostic. Writes ONE text file describing what the phone is doing.
#
#   su -c 'sh /data/local/tmp/spsm-diag.sh'
#
# Nothing here changes a single value on the device: every command is a read.
# It exists because guessing which processes are running on somebody else's ROM
# is how you break a phone. The output is what the "maximum power saving" work is
# planned from.
#
# Why each section is here:
#   processes        - who is running at all, and how much RAM each one holds
#   lru/oom          - which of them Android considers killable, and its class
#   services/alarms  - what is scheduled to wake up on its own
#   power/batterystats - who has actually been consuming (CPU time per uid)
#   freezer/device   - the knobs that decide how hard the system parks apps
#   display/cpufreq  - the two biggest in-use consumers: panel and CPU state

OUT=${1:-/data/local/tmp/spsm-diag.txt}
BIG=${2:-300}          # line cap for the sections that can run away

section() { printf '\n===== %s =====\n' "$1"; }

{
  section "when / what"
  date
  echo "build: $(getprop ro.build.display.id)"
  echo "android: $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
  echo "model: $(getprop ro.product.model) / $(getprop ro.product.device)"
  uname -a
  echo "uptime: $(uptime)"
  echo "battery:"
  dumpsys battery 2>/dev/null | sed -n '1,20p'

  section "screen state right now"
  echo "panel: $(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)"
  dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/wakefulness: \1/p' | head -3

  section "cpu: state, limits, cores, thermal"
  echo "power_mode: $(cat /proc/cpufreq/cpufreq_power_mode 2>/dev/null)"
  ls /proc/ppm 2>/dev/null | head -20
  for f in /proc/ppm/mode /proc/ppm/policy/* /proc/ppm/enabled; do
    [ -f "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
  done
  for p in 0 4 6; do
    d=/sys/devices/system/cpu/cpufreq/policy$p
    [ -d "$d" ] || continue
    echo "policy$p gov=$(cat $d/scaling_governor 2>/dev/null) min=$(cat $d/scaling_min_freq 2>/dev/null) max=$(cat $d/scaling_max_freq 2>/dev/null)"
  done
  for c in 0 4 6 7; do
    echo "cpu$c online=$(cat /sys/devices/system/cpu/cpu$c/online 2>/dev/null)"
  done
  echo "available governors: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)"
  for z in /sys/class/thermal/thermal_zone*/temp; do
    printf '%s=%s ' "$z" "$(cat "$z" 2>/dev/null)"
  done; echo

  section "display: modes and refresh setting"
  dumpsys display 2>/dev/null | grep -iE "mDisplayId|refreshRate|modeId|renderFrameRate" | head -25
  echo "peak_refresh_rate: $(settings get system peak_refresh_rate 2>/dev/null)"
  echo "min_refresh_rate:  $(settings get system min_refresh_rate 2>/dev/null)"
  echo "user_refresh_rate: $(settings get secure user_refresh_rate 2>/dev/null)"

  section "processes: pid ppid rss name"
  ps -A -o PID,PPID,RSS,NAME 2>/dev/null || ps -A 2>/dev/null
  echo "process count: $(ps -A 2>/dev/null | wc -l)"

  section "memory by process (PSS)"
  dumpsys meminfo -s 2>/dev/null | head -"$BIG"

  section "which processes Android may kill, and their class"
  dumpsys activity lru 2>/dev/null | head -"$BIG"

  section "running services"
  dumpsys activity services 2>/dev/null | grep -E "ServiceRecord|app=|isForeground" | head -"$BIG"

  section "scheduled wakeups (alarms)"
  dumpsys alarm 2>/dev/null | head -"$BIG"

  section "wake locks held"
  dumpsys power 2>/dev/null | sed -n '/Wake Locks/,/^$/p' | head -60

  section "doze / idle state"
  dumpsys deviceidle 2>/dev/null | head -40

  section "how hard the system parks apps"
  echo "cached_apps_freezer setting: $(settings get global cached_apps_freezer 2>/dev/null)"
  device_config get activity_manager_native_boot use_freezer 2>/dev/null
  device_config get activity_manager_native_boot freeze_debounce_timeout 2>/dev/null
  device_config get activity_manager max_cached_processes 2>/dev/null
  device_config get activity_manager max_phantom_processes 2>/dev/null

  section "who has actually been using the battery"
  # From "Estimated power use" to the end of the dump: the per-uid and per-app
  # CPU time tables live there, which is what names the real consumers.
  dumpsys batterystats --charged 2>/dev/null | awk '/Estimated power use/,0' | head -"$BIG"

  section "what SPSM itself is set to, and who it blocked"
  if [ -d /data/adb/spsm ]; then
    echo "active: $( [ -f /data/adb/spsm/active ] && echo yes || echo no )"
    echo "--- config (which options are on) ---"
    cat /data/adb/spsm/config 2>/dev/null | head -40
    echo "--- the six slots ---"
    cat /data/adb/spsm/whitelist.txt 2>/dev/null
    echo "--- apps SPSM suspended (must be empty after an exit) ---"
    cat /data/adb/spsm/state/blocked_by_us.tsv 2>/dev/null
    echo "--- last probe report ---"
    head -40 /data/adb/spsm/state/probe.tsv 2>/dev/null
    echo "--- last 30 log lines ---"
    tail -30 /data/adb/spsm/spsm.log 2>/dev/null
  else
    echo "module not installed"
  fi

  section "installed packages: system and user"
  echo "system packages: $(pm list packages -s 2>/dev/null | wc -l)"
  echo "user packages:   $(pm list packages -3 2>/dev/null | wc -l)"
  pm list packages -3 2>/dev/null
} > "$OUT" 2>&1

chmod 666 "$OUT" 2>/dev/null
echo "wrote $OUT ($(wc -l < "$OUT" 2>/dev/null) lines, $(wc -c < "$OUT" 2>/dev/null) bytes)"
