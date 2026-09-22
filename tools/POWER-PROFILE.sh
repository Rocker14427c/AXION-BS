#!/system/bin/sh
# SPSM power profiler - what is ACTUALLY consuming energy on this phone.
#
#   tools/POWER-PROFILE.sh snapshot [tag]   one reading, right now
#   tools/POWER-PROFILE.sh window <seconds> [tag]
#                                           two readings N seconds apart, and
#                                           the DELTA between them - this is
#                                           the one that answers "what woke the
#                                           phone while it was asleep"
#   tools/POWER-PROFILE.sh compare A B      two window reports side by side
#
# Why deltas and not absolutes: every counter that matters here is cumulative
# since boot. A single reading of "wakeup_count = 48213" says nothing. The same
# counter read twice across a known interval says "this source fired 214 times
# in 600 seconds while the screen was off", which is an actionable number.
#
# Why not battery percent: on a 5000 mAh cell one percent is 50 mAh. A ten
# minute experiment that moves the gauge by zero percent can still differ by a
# factor of three in real draw. This reads current_now in microamps where the
# fuel gauge exposes it, and counts WORK (wakeups, wakelocks, alarms, CPU
# residency) everywhere else, because work is what costs energy.
#
# Everything here is read-only. Nothing in this script changes a setting.

set -u

TAG_DEFAULT=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo now)
OUT_DIR=${SPSM_PROFILE_DIR:-/data/local/tmp/spsm-power}
mkdir -p "$OUT_DIR" 2>/dev/null

# ---------------------------------------------------------------- primitives
# A file read that cannot fail loudly. Most of these nodes are vendor-specific
# and simply absent on some kernels; a missing node is data, not an error.
rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf '' ; }

# First existing path from a list - the same node has different names across
# MediaTek kernel versions, and this phone is an MT6833 (Dimensity 700).
rd_first() {
  for _p in "$@"; do
    [ -r "$_p" ] && { cat "$_p" 2>/dev/null; return 0; }
  done
  printf ''
}

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n===== %s =====\n' "$1"; }

# ---------------------------------------------------------------- the reading
snapshot() {
  printf '# SPSM power snapshot\n'
  printf 'when=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  printf 'uptime=%s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  # Time the kernel believes it was suspended. THE single most important number
  # in this whole file: if uptime advances by 600s and this does not move, the
  # phone never slept, and nothing else you tune will matter.
  printf 'suspend_time_total=%s\n' "$(rd_first /sys/power/suspend_stats/total_suspend_time /sys/kernel/debug/suspend_time)"

  section battery
  # current_now: negative = discharging on most gauges, microamps. This is the
  # closest thing to a real power meter the phone exposes.
  for _f in current_now voltage_now capacity charge_counter status power_supply_name; do
    _v=$(rd_first "/sys/class/power_supply/battery/$_f" "/sys/class/power_supply/bms/$_f")
    [ -n "$_v" ] && printf '%s=%s\n' "$_f" "$_v"
  done

  section suspend
  # Why the last suspend attempt failed, if it did. "failed_freeze" almost
  # always means a userspace process refused to freeze; "failed_suspend" points
  # at a driver.
  for _f in success fail failed_freeze failed_prepare failed_suspend last_failed_dev last_failed_step; do
    _v=$(rd "/sys/power/suspend_stats/$_f")
    [ -n "$_v" ] && printf 'suspend_%s=%s\n' "$_f" "$_v"
  done
  printf 'wakeup_count=%s\n' "$(rd /sys/power/wakeup_count)"

  section wakeup_sources
  # The kernel's own table of what is preventing suspend. Columns vary by
  # kernel; the header is printed so the delta pass can parse whatever this one
  # gives. active_count and prevent_suspend_time are the two that matter.
  if [ -r /sys/kernel/debug/wakeup_sources ]; then
    cat /sys/kernel/debug/wakeup_sources 2>/dev/null
  else
    # Non-debugfs fallback: per-device wakeup nodes under sysfs.
    for _d in /sys/class/wakeup/wakeup*; do
      [ -d "$_d" ] || continue
      printf '%s\t%s\t%s\t%s\n' \
        "$(rd "$_d/name")" "$(rd "$_d/active_count")" \
        "$(rd "$_d/event_count")" "$(rd "$_d/prevent_suspend_time_ms")"
    done
  fi

  section cpu_idle
  # Residency per C-state per CPU, in microseconds since boot. The delta of
  # these across a screen-off window tells you whether the cores are actually
  # reaching their deep states or just spinning at a low frequency - which is
  # the distinction the owner explicitly asked about.
  for _c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$_c/cpuidle" ] || continue
    _n=$(basename "$_c")
    for _s in "$_c"/cpuidle/state[0-9]*; do
      [ -d "$_s" ] || continue
      printf 'idle %s %s name=%s usage=%s time=%s\n' \
        "$_n" "$(basename "$_s")" "$(rd "$_s/name")" \
        "$(rd "$_s/usage")" "$(rd "$_s/time")"
    done
  done

  section cpu_freq
  for _p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
    [ -d "$_p" ] || continue
    printf 'policy %s gov=%s cur=%s max=%s min=%s\n' \
      "$(basename "$_p")" "$(rd "$_p/scaling_governor")" \
      "$(rd "$_p/scaling_cur_freq")" "$(rd "$_p/scaling_max_freq")" \
      "$(rd "$_p/scaling_min_freq")"
    # Time-in-state: microseconds at each frequency since boot. The delta shows
    # where the cores ACTUALLY spent the window, which is the only way to tell a
    # cap that is working from one the governor is ignoring.
    if [ -r "$_p/stats/time_in_state" ]; then
      printf 'tis %s BEGIN\n' "$(basename "$_p")"
      cat "$_p/stats/time_in_state" 2>/dev/null
      printf 'tis %s END\n' "$(basename "$_p")"
    fi
  done
  printf 'cpu_online=%s\n' "$(rd /sys/devices/system/cpu/online)"
  printf 'cpu_offline=%s\n' "$(rd /sys/devices/system/cpu/offline)"

  section interrupts
  # Which IRQs are firing. Across a screen-off window this names the hardware
  # that is waking the SoC - a modem IRQ, a touch controller, a sensor hub.
  [ -r /proc/interrupts ] && cat /proc/interrupts 2>/dev/null

  section gpu
  printf 'gpu_freq=%s\n' "$(rd_first /proc/gpufreq/gpufreq_cur_freq /sys/kernel/ged/hal/current_freqency /sys/class/devfreq/13000000.mali/cur_freq)"
  printf 'gpu_load=%s\n' "$(rd_first /sys/kernel/ged/hal/gpu_utilization /proc/gpufreq/gpufreq_var_dump)"
  printf 'gpu_dvfs=%s\n' "$(rd /sys/module/ged/parameters/gpu_dvfs_enable)"
  printf 'gpu_upbound=%s\n' "$(rd /sys/module/ged/parameters/gpu_cust_upbound_freq)"

  section thermal
  for _z in /sys/class/thermal/thermal_zone[0-9]*; do
    [ -d "$_z" ] || continue
    printf 'zone %s %s %s\n' "$(basename "$_z")" "$(rd "$_z/type")" "$(rd "$_z/temp")"
  done

  section display
  printf 'brightness=%s\n' "$(rd_first /sys/class/backlight/panel0-backlight/brightness /sys/class/leds/lcd-backlight/brightness)"
  printf 'panel_power=%s\n' "$(rd_first /sys/class/backlight/panel0-backlight/bl_power /sys/class/drm/card0-DSI-1/enabled)"

  # ---------------------------------------------------------- framework side
  if have dumpsys; then
    section deviceidle
    # The single question: is Doze actually engaging? mState=IDLE is the goal;
    # ACTIVE or INACTIVE after minutes of screen-off means something is holding
    # the phone awake, and mActiveReason / the wakelock list below says what.
    dumpsys deviceidle 2>/dev/null | sed -n '1,60p'

    section deviceidle_whitelist
    # Every app here is exempt from Doze. On an OEM-derived ROM this list is
    # often long, and each entry is an app that may wake the phone freely.
    dumpsys deviceidle whitelist 2>/dev/null | head -80

    section power_wakelocks
    # Userspace wakelocks: which app is holding the CPU awake, and for how long.
    dumpsys power 2>/dev/null | sed -n '/Wake Locks/,/^$/p' | head -40
    dumpsys power 2>/dev/null | grep -E "mWakefulness|mHoldingDisplay|mScreenBright|Display Power" | head -10

    section alarms
    # Alarms are the classic standby drain: each one wakes the AP. The top
    # section of `dumpsys alarm` ranks them.
    dumpsys alarm 2>/dev/null | grep -E "^ *(Wakeup Alarm|Alarm Stats|com\.|Top Alarms)" | head -40

    section jobs
    dumpsys jobscheduler 2>/dev/null | grep -E "Pending|Active jobs|Job History|ready" | head -25

    section network
    dumpsys connectivity 2>/dev/null | grep -E "Active default|NetworkAgentInfo.*CONNECTED" | head -10
    dumpsys wifi 2>/dev/null | grep -E "Wi-Fi is|mScreenOn|Scan Throttle|mWifiState|ScanMode" | head -12

    section telephony
    # The owner's requirement: calls and SMS must keep working. This records
    # what the modem is doing so a later change can be judged against it.
    dumpsys telephony.registry 2>/dev/null | grep -E "mServiceState|mDataConnectionState|mSignalStrength|mCallState" | head -12

    section sensors
    dumpsys sensorservice 2>/dev/null | grep -E "active|Active|0x" | head -25

    section location
    dumpsys location 2>/dev/null | grep -E "provider|request|Active" | head -20

    section processes
    # Who is actually running. A cached process costs memory, not CPU; a
    # running service costs both.
    dumpsys activity processes 2>/dev/null | grep -cE "^ *Proc " 2>/dev/null
    dumpsys activity services 2>/dev/null | grep -cE "ServiceRecord" 2>/dev/null

    section batterystats_since_unplug
    dumpsys batterystats --charged 2>/dev/null | sed -n '/Statistics since last charge/,/^$/p' | head -50
  fi

  section top_cpu
  # A single ranked snapshot of who is burning CPU right now.
  if have top; then
    top -n 1 -b -o %CPU 2>/dev/null | head -20 || top -n 1 2>/dev/null | head -20
  fi

  section spsm_state
  _sd=${SPSM_DIR:-/data/adb/spsm}
  printf 'spsm_active=%s\n' "$([ -f "$_sd/state/active" ] && echo yes || echo no)"
  printf 'spsm_deep=%s\n' "$([ -f "$_sd/state/deep_report" ] && cat "$_sd/state/deep_report" 2>/dev/null || echo released)"
  printf 'spsm_doze_forced=%s\n' "$([ -f "$_sd/state/doze_forced" ] && echo yes || echo no)"
  printf 'spsm_cores_asleep=%s\n' "$([ -f "$_sd/state/cores_asleep" ] && echo yes || echo no)"
  # Which knobs are actually ENABLED in the on-device config. The field log
  # showed a screen-off with no deep knob applying at all, and this is the file
  # that decides that.
  printf '--- config ---\n'
  [ -r "$_sd/config" ] && grep -E '^knob\.' "$_sd/config" 2>/dev/null
}

# ---------------------------------------------------------------- the window
window() {
  _secs=${1:-600}
  _tag=${2:-$TAG_DEFAULT}
  _a="$OUT_DIR/$_tag.begin"
  _b="$OUT_DIR/$_tag.end"
  _r="$OUT_DIR/$_tag.report"

  printf 'SPSM power window: %ss, tag=%s\n' "$_secs" "$_tag"
  printf 'Take your hands off the phone now. Screen off if that is what you are measuring.\n'
  snapshot > "$_a" 2>/dev/null
  sleep "$_secs"
  snapshot > "$_b" 2>/dev/null
  report "$_a" "$_b" "$_secs" > "$_r" 2>/dev/null
  cat "$_r"
  printf '\nsaved: %s\n' "$_r"
}

# Pull one scalar out of a snapshot file.
val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

report() {
  _a=$1; _b=$2; _secs=$3

  printf '===== SPSM POWER REPORT (%s seconds) =====\n\n' "$_secs"

  # --- did the phone sleep at all -----------------------------------------
  _u0=$(val "$_a" uptime); _u1=$(val "$_b" uptime)
  _s0=$(val "$_a" suspend_time_total); _s1=$(val "$_b" suspend_time_total)
  printf -- '--- SUSPEND ---\n'
  if [ -n "$_s0" ] && [ -n "$_s1" ]; then
    # These are usually "seconds.nanoseconds" or plain ms depending on kernel.
    printf 'suspend_time: %s -> %s\n' "$_s0" "$_s1"
  else
    printf 'suspend_time: not exposed by this kernel\n'
  fi
  printf 'uptime: %s -> %s\n' "$_u0" "$_u1"
  _w0=$(val "$_a" wakeup_count); _w1=$(val "$_b" wakeup_count)
  [ -n "$_w0" ] && printf 'wakeup_count: %s -> %s (delta %s)\n' "$_w0" "$_w1" "$((${_w1:-0} - ${_w0:-0}))"
  for _f in success fail failed_freeze failed_suspend; do
    _x=$(val "$_a" "suspend_$_f"); _y=$(val "$_b" "suspend_$_f")
    [ -n "$_x" ] && [ "$_x" != "$_y" ] && printf 'suspend_%s: %s -> %s\n' "$_f" "$_x" "$_y"
  done

  # --- battery -------------------------------------------------------------
  printf -- '\n--- BATTERY ---\n'
  _c0=$(val "$_a" charge_counter); _c1=$(val "$_b" charge_counter)
  if [ -n "$_c0" ] && [ -n "$_c1" ] && [ "$_c0" != "$_c1" ]; then
    # charge_counter is in microampere-hours. This is the honest drain figure:
    # far finer than the percent gauge, and directly comparable between runs.
    _d=$((_c0 - _c1))
    printf 'charge_used_uAh=%s over %ss\n' "$_d" "$_secs"
    [ "$_secs" -gt 0 ] && printf 'implied_mA=%s\n' "$(( _d * 3600 / _secs / 1000 ))"
  fi
  printf 'current_now: %s -> %s (uA)\n' "$(val "$_a" current_now)" "$(val "$_b" current_now)"
  printf 'capacity: %s%% -> %s%%\n' "$(val "$_a" capacity)" "$(val "$_b" capacity)"

  # --- cpu idle residency --------------------------------------------------
  # The question this answers: did the cores reach their deep idle states, or
  # did they only run slowly? Those are completely different energy outcomes,
  # and the owner asked for exactly this distinction.
  printf -- '\n--- CPU IDLE RESIDENCY (delta) ---\n'
  awk '
    FNR==NR { if ($1=="idle") { k=$2" "$3; nm[k]=$4; u0[k]=$5; t0[k]=$6 } ; next }
    $1=="idle" { k=$2" "$3; u1[k]=$5; t1[k]=$6 }
    END {
      for (k in u1) {
        gsub(/usage=/,"",u0[k]); gsub(/usage=/,"",u1[k])
        gsub(/time=/,"",t0[k]);  gsub(/time=/,"",t1[k])
        du = u1[k]-u0[k]; dt = t1[k]-t0[k]
        if (du>0 || dt>0) printf "  %-14s %-22s entries=%-8d time_us=%d\n", k, nm[k], du, dt
      }
    }
  ' "$_a" "$_b" 2>/dev/null | sort

  # --- cpu time in state ---------------------------------------------------
  printf -- '\n--- CPU TIME IN STATE (delta, 10ms units) ---\n'
  awk '
    FNR==NR {
      if ($1=="tis" && $3=="BEGIN") { p=$2; inb=1; next }
      if ($1=="tis" && $3=="END")   { inb=0; next }
      if (inb && NF==2) a[p" "$1]=$2
      next
    }
    $1=="tis" && $3=="BEGIN" { p=$2; inb=1; next }
    $1=="tis" && $3=="END"   { inb=0; next }
    inb && NF==2 { k=p" "$1; d=$2-a[k]; if (d>0) printf "  %-12s %-10s %d\n", p, $1, d }
  ' "$_a" "$_b" 2>/dev/null

  # --- wakeup sources ------------------------------------------------------
  # Ranked by how many times each source fired during the window. This is the
  # list that answers "what is waking the phone".
  printf -- '\n--- TOP WAKEUP SOURCES (delta active_count) ---\n'
  awk '
    function isnum(x) { return (x ~ /^[0-9]+$/) }
    FNR==NR {
      if (NF>=6 && isnum($2)) { a[$1]=$2; ap[$1]=$0 }
      next
    }
    NF>=6 && isnum($2) {
      d=$2-a[$1]
      if (d>0) printf "  %-34s fired=%-8d\n", $1, d
    }
  ' "$_a" "$_b" 2>/dev/null | sort -t= -k2 -rn | head -25

  # --- interrupts ----------------------------------------------------------
  printf -- '\n--- TOP INTERRUPTS (delta) ---\n'
  awk '
    FNR==NR {
      if ($1 ~ /^[0-9]+:$/) { s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i
        nm=""; for(i=2;i<=NF;i++) if ($i !~ /^[0-9]+$/) nm=nm" "$i
        a[$1]=s; n[$1]=nm }
      next
    }
    $1 ~ /^[0-9]+:$/ {
      s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i
      d=s-a[$1]
      if (d>50) printf "  %-8s %-40s %d\n", $1, substr(n[$1],1,40), d
    }
  ' "$_a" "$_b" 2>/dev/null | sort -k3 -rn | head -20

  # --- framework verdicts --------------------------------------------------
  printf -- '\n--- DOZE STATE ---\n'
  grep -E "mState=|mLightState=|mForceIdle=|mActiveReason" "$_b" 2>/dev/null | head -8
  printf -- '\n--- SPSM STATE ---\n'
  grep -E "^spsm_" "$_b" 2>/dev/null
  printf -- '\n--- ENABLED KNOBS ---\n'
  sed -n '/--- config ---/,$p' "$_b" 2>/dev/null | grep -E '^knob\.' | head -40

  printf -- '\n--- DEEP KNOBS: ENABLED vs APPLIED ---\n'
  # The field log for v3.8.1 showed a screen-off in which the deep phase ran
  # and applied NOTHING: no "snap <knob>" lines, and doze=no. The deep knobs
  # are the entire standby story - Doze, app restriction, the ROM's background
  # services - so if they are off, the mode is only a screen-on saver. An
  # absent knob.<id> line means the DEFAULT applies (most deep knobs default
  # on); an explicit 0 means something switched it off.
  for _k in deep_doze app_restrict rom_bg_off cores_sleep ged_boost_off freeze_google; do
    _cv=$(sed -n "s/^knob\.$_k=//p" "${SPSM_DIR:-/data/adb/spsm}/config" 2>/dev/null | tail -1)
    case "$_cv" in
      "")      printf '  %-18s config=(unset -> default)\n' "$_k" ;;
      1|true)  printf '  %-18s config=ON\n' "$_k" ;;
      *)       printf '  %-18s config=OFF  <-- this deep saving is disabled\n' "$_k" ;;
    esac
  done

  printf -- '\n--- VERDICT HINTS ---\n'
  # A few mechanical conclusions the numbers support on their own, so the
  # report is useful even before anyone reads the raw sections.
  _wd=$((${_w1:-0} - ${_w0:-0}))
  if [ "$_wd" -gt 0 ] 2>/dev/null; then
    printf 'The phone came out of suspend %s times in %ss (%s/min).\n' \
      "$_wd" "$_secs" "$(( _wd * 60 / (_secs>0?_secs:1) ))"
  fi
  if grep -q "mState=ACTIVE" "$_b" 2>/dev/null; then
    printf 'Doze is NOT engaged (mState=ACTIVE) - something is holding the phone awake.\n'
  fi
  if grep -q "spsm_doze_forced=no" "$_b" 2>/dev/null && grep -q "spsm_active=yes" "$_b" 2>/dev/null; then
    printf 'SPSM is on but deep_doze has NOT been applied this idle period.\n'
  fi
}

compare() {
  _x="$OUT_DIR/$1.report"; _y="$OUT_DIR/$2.report"
  [ -r "$_x" ] || { echo "no such report: $1"; exit 1; }
  [ -r "$_y" ] || { echo "no such report: $2"; exit 1; }
  printf '########## %s ##########\n' "$1"; cat "$_x"
  printf '\n\n########## %s ##########\n' "$2"; cat "$_y"
}

case "${1:-}" in
  snapshot) shift; snapshot ;;
  window)   shift; window "${1:-600}" "${2:-$TAG_DEFAULT}" ;;
  report)   shift; report "$1" "$2" "${3:-0}" ;;
  compare)  shift; compare "$1" "$2" ;;
  *)
    cat <<'USAGE'
SPSM power profiler - read-only. Nothing here changes a setting.

  POWER-PROFILE.sh snapshot            one reading to stdout
  POWER-PROFILE.sh window 600 spsm-off two readings 600s apart + the delta
  POWER-PROFILE.sh compare A B         two saved reports side by side

The measurement that matters most:

  # with SPSM ON, screen off, phone untouched for 10 minutes
  su -c 'sh /data/adb/spsm/tools/POWER-PROFILE.sh window 600 spsm-on'

  # then turn SPSM off and repeat
  su -c 'sh /data/adb/spsm/tools/POWER-PROFILE.sh window 600 normal'

  su -c 'sh /data/adb/spsm/tools/POWER-PROFILE.sh compare spsm-on normal'

Reports land in /data/local/tmp/spsm-power/.
USAGE
    ;;
esac
