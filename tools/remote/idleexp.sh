#!/system/bin/sh
# idleexp.sh -- long screen-off idle experiment that verifies its own preconditions.
#
#   usage: idleexp.sh <variant> <window_secs> [checkpoint_secs] [grace_secs]
#
#     variant:
#       control   stock behaviour: SPSM deactivated, radio on, background scanning allowed
#       shipped   SPSM activated with its default knobs -- what a user runs
#       gms-trim  control, plus GMS and Play Store removed from the Doze whitelist
#
#   defaults: window 23400 (6.5 h), checkpoint 1800 (30 min), grace 150
#
# WHY THIS SCRIPT LOOKS LIKE THIS -- three lessons paid for in wasted phone time:
#
#   1. TIME. `sleep` here is CLOCK_MONOTONIC and stops while the phone is
#      suspended, so wifiexp's 600 s windows really ran 850-1180 s. Every deadline
#      below is measured against /proc/uptime (CLOCK_BOOTTIME), which counts
#      suspended time, and every window reports how long it actually lasted.
#
#   2. CONFIGURATION. wifiexp's V3 was labelled "Wi-Fi off" and ran with the radio
#      ON: Android re-enabled Wi-Fi by itself after a brief screen-on and nothing
#      checked. Each window here records the state it was meant to be in and the
#      state it was actually in, at both ends, and declares itself INVALID if they
#      disagree.
#
#   3. FOOTPRINT. An ssh session holds a Termux wake lock which blocks suspend and
#      silently invalidates a run. The harness kills the tunnel and the lock holder
#      first, and refuses to start until `Wake Locks:` is empty.
#
# Outputs, all in /data/local/tmp:
#   ie.out            the narrative log + final summary table
#   ie-<tag>.txt      full counter snapshots (window start / end)
#   ie-irq-<tag>.txt  /proc/interrupts at those points
#   ie-chk.tsv        one line per checkpoint -- the drain/wakeup profile over time
#   ie-history.txt    batterystats history for the whole run, for offline analysis

D=/data/local/tmp
VARIANT=${1:-control}
WIN=${2:-23400}
CHK=${3:-1800}
GRACE=${4:-150}
LOW_BAT=${5:-15}   # stop the window and restore the phone below this capacity
ENGINE=/data/adb/spsm/scripts/engine.sh
STATE=/data/adb/spsm/state
CFG=/data/adb/spsm/config
OUT=$D/ie.out
CHKTSV=$D/ie-chk.tsv

# ---------------------------------------------------------------- clocks
# /proc/uptime is CLOCK_BOOTTIME: monotonic plus suspended time. It is the only
# clock on this phone that answers "how long has this really been running".
now() { cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1; }
deadline_in() { echo $(( $(now) + $1 )); }
wait_until() { _d=$1; while [ "$(now)" -lt "$_d" ]; do sleep 5; done; }

# ---------------------------------------------------------------- probes
screen_state() { # reads the cache wlock_state just filled, so a snapshot is one dump
  [ -s "$D/.ie-pwr" ] || timeout 30 dumpsys power > "$D/.ie-pwr" 2>/dev/null
  sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' "$D/.ie-pwr" | head -1
}
screen_state_fresh() { rm -f "$D/.ie-pwr"; screen_state; }
wifi_state() { timeout 20 cmd wifi status 2>/dev/null | head -1 | tr -d '\r'; }
scan_state() { timeout 20 cmd wifi status 2>/dev/null | grep -i 'scanning is' | tr -d '\r' | sed 's/^[[:space:]]*//'; }
wlock_state() { # one dumpsys power, cached for the handful of reads around it
  timeout 40 dumpsys power > "$D/.ie-pwr" 2>/dev/null
  sed -n 's/.*Wake Locks: size=\([0-9]*\).*/\1/p' "$D/.ie-pwr" | head -1
}
doze_state() { timeout 40 dumpsys deviceidle 2>/dev/null | sed -n 's/.*mState=\([A-Z_]*\).*/\1/p' | head -1; }
irqs() { # one line: the interrupts this investigation cares about
  _o=""
  for k in wlan0 ccci silfp touchpanel arch_timer IPI0; do
    _v=$(awk -v k="$k" '$1 ~ k {s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}' /proc/interrupts 2>/dev/null)
    _o="$_o $k=${_v:-0}"
  done
  echo "$_o"
}
sus() { cat /sys/power/suspend_stats/$1 2>/dev/null; }
charge() { cat /sys/class/power_supply/battery/charge_counter 2>/dev/null; }
ua() { cat /sys/class/power_supply/battery/current_now 2>/dev/null; }
cap() { cat /sys/class/power_supply/battery/capacity 2>/dev/null; }
charging() { cat /sys/class/power_supply/battery/status 2>/dev/null; }

snap() { # snap <tag>
  _t=$1
  {
    echo "boot_s=$(now)"
    echo "epoch=$(date +%s)"
    echo "iso=$(date '+%F %T')"
    echo "sus_success=$(sus success)"
    echo "sus_fail=$(sus fail)"
    echo "sus_last_dev=$(sus last_failed_dev)"
    echo "sus_last_errno=$(sus last_failed_errno)"
    echo "charge_counter=$(charge)"
    echo "current_now=$(ua)"
    echo "capacity=$(cap)"
    echo "battery_status=$(charging)"
    echo "screen=$(screen_state_fresh)"
    echo "doze=$(doze_state)"
    echo "wifi=$(wifi_state)"
    echo "scan=$(scan_state)"
    echo "wakelocks=$(wlock_state)"
    for c in cpu0 cpu6; do
      for st in 0 1 2; do
        _n=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/name 2>/dev/null)
        [ -n "$_n" ] && echo "idle_${c}_${_n}_usage=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/usage 2>/dev/null)"
        [ -n "$_n" ] && echo "idle_${c}_${_n}_time_us=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/time 2>/dev/null)"
      done
    done
    echo "irq:$(irqs)"
  } > "$D/ie-$_t.txt" 2>/dev/null
  cp /proc/interrupts "$D/ie-irq-$_t.txt" 2>/dev/null
  echo "  [$1] boot=$(now)s $(date '+%T') sus_ok=$(sus success) sus_fail=$(sus fail) charge=$(charge) uA=$(ua) screen=$(sed -n 's/^screen=//p' $D/ie-$_t.txt) wifi=[$(sed -n 's/^wifi=//p' $D/ie-$_t.txt)]"
}

chk() { # chk <label> -- one compact line per checkpoint, appended to ie-chk.tsv
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$(now)" "$(date '+%T')" "$(sus success)" "$(sus fail)" \
    "$(charge)" "$(ua)" "$(screen_state_fresh)" "$(doze_state)" "$(irqs)" >> "$CHKTSV" 2>/dev/null
}

wakeups() { # wakeups <tag> -- the per-reason wakeup counters, for the diff
  timeout 120 dumpsys batterystats --wakeups > "$D/ie-wake-$1.txt" 2>/dev/null
  echo "  wakeup reasons saved ($(wc -l < $D/ie-wake-$1.txt 2>/dev/null) lines)"
  # alarmtimer is the device that refuses suspend here (last_failed_dev), so the
  # alarms themselves are the evidence: who is arming them, and how often.
  timeout 180 dumpsys alarm > "$D/ie-alarm-$1.txt" 2>/dev/null
  echo "  alarm dump saved ($(wc -l < $D/ie-alarm-$1.txt 2>/dev/null) lines)"
}

# ---------------------------------------------------------------- restore
ORIG_LOCK=/data/local/tmp/ie-orig.env
[ -f "$ORIG_LOCK" ] && . "$ORIG_LOCK"
restore_all() {
  echo
  echo "################ RESTORING ################"
  input keyevent 26 2>/dev/null       # bring the screen back
  # Radio first, then scanning: set-scan-always-available silently does nothing
  # while the radio is down, which is how wifiexp left scanning switched off.
  case "${ORIG_WIFI_ON:-1}" in
    0) settings put global wifi_on 0 >/dev/null 2>&1 ;;
    *) settings put global wifi_on 1 >/dev/null 2>&1; svc wifi enable >/dev/null 2>&1 ;;
  esac
  _i=0
  while [ "$_i" -lt 12 ]; do
    case "$(wifi_state)" in *enabled*) break ;; esac
    sleep 5; _i=$((_i + 1))
  done
  if [ "${ORIG_SCAN:-1}" = "1" ]; then
    cmd wifi set-scan-always-available enabled >/dev/null 2>&1
    settings put global wifi_scan_always_enabled 1 >/dev/null 2>&1
  fi
  # Only write back values that are actually values: a settings read can fail with
  # "cmd: Failure calling service settings..." and writing that string back would
  # corrupt the setting we were trying to preserve.
  case "${ORIG_SLEEP:-}" in ''|*[!0-9]*) : ;; *) settings put global wifi_sleep_policy "$ORIG_SLEEP" >/dev/null 2>&1 ;; esac
  case "${ORIG_WAKEUP:-}" in ''|*[!0-9]*) : ;; *) settings put global wifi_wakeup_enabled "$ORIG_WAKEUP" >/dev/null 2>&1 ;; esac
  case "${ORIG_WIFI_ON:-}" in ''|*[!0-9]*) : ;; *) ;; esac
  if [ "${ORIG_GMS_EXEMPT:-1}" = "1" ]; then
    dumpsys deviceidle whitelist +com.google.android.gms >/dev/null 2>&1
    dumpsys deviceidle whitelist +com.android.vending >/dev/null 2>&1
  fi
  case "${ORIG_SPSM:-off}" in
    on)  sh "$ENGINE" activate  >/dev/null 2>&1 ;;
    off) sh "$ENGINE" deactivate >/dev/null 2>&1 ;;
  esac
  echo "  screen=$(screen_state)  wifi=[$(wifi_state)]"
  echo "  scan=[$(scan_state)]"
  echo "  whitelist total=$(dumpsys deviceidle whitelist 2>/dev/null | wc -l) gms=$(dumpsys deviceidle whitelist 2>/dev/null | grep -c 'com.google.android.gms')"
  echo "  spsm active marker: $( [ -f $STATE/active ] && echo yes || echo no )"
  echo "  FINAL: sus_success=$(sus success) fail=$(sus fail) last_dev=$(sus last_dev)"
  echo "  battery: $(cap)% charge_counter=$(charge)"
}
trap 'restore_all; echo "################ DONE $(date "+%F %T") — reopen Termux, restart sshd and the tunnel ################"' EXIT

# ---------------------------------------------------------------- setup
echo "################ IDLE EXPERIMENT — variant=$VARIANT window=${WIN}s checkpoint=${CHK}s  $(date '+%F %T') ################"
echo "status=$(charging) level=$(cap)%  usb_online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)"
case "$(charging)" in
  Discharging) : ;;
  *) echo "!! The phone is on the charger ($(charging)). Charging current swamps the drain"
     echo "   this run is trying to measure. Unplug it and start again. Stopping."
     exit 1 ;;
esac
echo "spsm active before: $( [ -f $STATE/active ] && echo yes || echo no )  (config: $(sed -n 's/^knob\.//p' $CFG 2>/dev/null | tr '\n' ' '))"

# Save the state we are going to disturb, so the restore is exact.
{
  echo "ORIG_WIFI_ON=$(settings get global wifi_on 2>/dev/null)"
  echo "ORIG_WAKEUP=$(settings get global wifi_wakeup_enabled 2>/dev/null)"
  echo "ORIG_SLEEP=$(settings get global wifi_sleep_policy 2>/dev/null)"
  case "$(scan_state)" in *"always available"*) echo "ORIG_SCAN=1" ;; *) echo "ORIG_SCAN=0" ;; esac
  echo "ORIG_GMS_EXEMPT=$(dumpsys deviceidle whitelist 2>/dev/null | grep -c 'com.google.android.gms')"
  echo "ORIG_SPSM=$( [ -f $STATE/active ] && echo on || echo off )"
} > "$ORIG_LOCK" 2>/dev/null
cat "$ORIG_LOCK"

echo
echo "===== GRACE ${GRACE}s: the tunnel and the wake lock holder are killed at the end of it ====="
wait_until "$(deadline_in $GRACE)"

echo
echo "===== REMOVING THE AGENT'S FOOTPRINT ====="
for p in $(ps -A -o PID,CMD 2>/dev/null | grep -E "pinggy|localhost\.run|ssh .*-R " | grep -v grep | awk '{print $1}'); do
  echo "  killing tunnel pid $p"; kill -9 "$p" 2>/dev/null
done
pkill -9 -f "/data/data/com.termux/files/usr/bin/sshd" 2>/dev/null && echo "  sshd stopped" || echo "  (sshd not running)"
_wl=$(timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | grep -c "termux")
if [ "${_wl:-0}" -gt 0 ]; then
  _pid=$(timeout 40 dumpsys power 2>/dev/null | sed -n 's/.*termux.*pid=\([0-9]*\).*/\1/p' | head -1)
  echo "  a Termux wake lock is still held by pid ${_pid:-?} — killing that process to release it"
  [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
  sleep 5
fi
pkill -9 -f "com.termux" >/dev/null 2>&1
sleep 10
_held=$(wlock_state)
echo "  Wake Locks: size=${_held}"
if [ "${_held:-0}" != "0" ]; then
  echo "  !! A wake lock is still held. This run would measure the wrong thing — stopping here."
  exit 1
fi
echo "  clean: nothing of ours is holding the phone awake"
echo "  suspend counters now: success=$(sus success) fail=$(sus fail)"

# ---------------------------------------------------------------- variant
echo
echo "===== APPLYING VARIANT: $VARIANT ====="
case "$VARIANT" in
  control)
    sh "$ENGINE" deactivate >/dev/null 2>&1
    settings put global wifi_on 1 >/dev/null 2>&1; svc wifi enable >/dev/null 2>&1
    sleep 8; cmd wifi set-scan-always-available enabled >/dev/null 2>&1
    echo "  SPSM deactivated; radio on; background scanning allowed (stock)"
    ;;
  shipped)
    sh "$ENGINE" activate >/dev/null 2>&1
    rc=$?
    echo "  SPSM activate rc=$rc  active marker: $( [ -f $STATE/active ] && echo yes || echo no )"
    echo "  knobs applied: $(tail -6 /data/adb/spsm/spsm.log 2>/dev/null | tr '\n' '|')"
    ;;
  gms-trim)
    sh "$ENGINE" deactivate >/dev/null 2>&1
    dumpsys deviceidle whitelist -com.google.android.gms >/dev/null 2>&1
    dumpsys deviceidle whitelist -com.android.vending >/dev/null 2>&1
    echo "  stock + GMS/Play out of the Doze whitelist (gms entries now: $(dumpsys deviceidle whitelist 2>/dev/null | grep -c 'com.google.android.gms'))"
    ;;
  *) echo "  unknown variant"; exit 1 ;;
esac
sleep 10

echo
echo "===== SCREEN OFF ====="
_i=0
while [ "$_i" -lt 3 ]; do
  case "$(screen_state_fresh)" in
    Asleep|Dozing) break ;;
    *) input keyevent 26 2>/dev/null; sleep 8 ;;
  esac
  _i=$((_i + 1))
done
SETTLE_END=$(deadline_in 120)
wait_until "$SETTLE_END"
_screen=$(screen_state_fresh)
echo "  screen now: [$_screen]"
if [ "$_screen" != "Asleep" ] && [ "$_screen" != "Dozing" ]; then
  echo "  !! The screen is not off ([$_screen]). A window measured now would be measuring screen-on power — stopping."
  exit 1
fi

# ---------------------------------------------------------------- window
echo
echo "################ WINDOW START — $VARIANT, ${WIN}s ################"
# The heavy captures run BEFORE the clock starts, and the verification dumps run
# AFTER it stops. That ordering is deliberate: a dumpsys issued while the phone is
# suspended makes progress only during wakeups, so one call can take minutes of
# wall time -- and if it sits inside the measured interval it corrupts the length
# of the window (which is how wifiexp's 600s windows came out at 850-1180s).
snap start
wakeups start
chk start
EXTRA_WIFI=$(wifi_state)
echo "  -- clock starts now; nothing but the wait runs until it stops --"
SUS0=$(sus success); FAIL0=$(sus fail); CH0=$(charge); BOOT0=$(now); T0=$(date +%s)
IRQ0=$(irqs)

END=$(deadline_in "$WIN")
CP=$(( $(now) + CHK ))
EARLY=""
while [ "$(now)" -lt "$END" ]; do
  sleep 5
  _b=$(cap)
  if [ -n "$_b" ] && [ "$_b" -le "$LOW_BAT" ]; then
    EARLY="battery fell to ${_b}% (guard at ${LOW_BAT}%)"
    echo "  !! $_EARLY — ending the window early and restoring the phone"
    break
  fi
  if [ "$(now)" -ge "$CP" ]; then
    _tp=$(awk '/touchpanel/ {s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}' /proc/interrupts 2>/dev/null)
    chk "cp$(($(now) - BOOT0))s"
    echo "  checkpoint at $(($(now) - BOOT0))s: sus_ok=$(sus success) fail=$(sus fail) charge=$(charge) uA=$(ua) screen=$(screen_state_fresh) doze=$(doze_state) touchpanel_total=${_tp:-?}"
    CP=$((CP + CHK))
  fi
done

# clock stops first, cheap reads only, so the window ends exactly where it says
SUS1=$(sus success); FAIL1=$(sus fail); CH1=$(charge); BOOT1=$(now); T1=$(date +%s); IRQ1=$(irqs)
echo
echo "  -- clock stopped at $(date '+%T'), measured $((BOOT1 - BOOT0))s --"
snap end
wakeups end
chk end
END_WIFI=$(wifi_state); END_SCREEN=$(screen_state_fresh)

# ---------------------------------------------------------------- report
echo
echo "################ REPORT — $VARIANT ################"
echo "  requested ${WIN}s   measured: boottime $((BOOT1 - BOOT0))s   wall-clock $((T1 - T0))s"
echo "    (if these two disagree the phone's wall clock is not counting suspended time;"
echo "     the boottime figure is the true one)"
echo "  sus_success  +$((SUS1 - SUS0))"
echo "  sus_fail     +$((FAIL1 - FAIL0))"
echo "  last_failed_dev=[$(sus last_dev)] errno=$(sus last_errno)"
echo "  drained_uAh  $((CH0 - CH1))   of 60000 uAh per 1%"
echo "  capacity     $(cap)%  uA now=$(ua)"
echo "  screen       start=[$EXTRA_SCREEN] end=[$END_SCREEN]"
echo "  wifi         start=[$EXTRA_WIFI] end=[$END_WIFI]"
echo "  -- interrupt deltas --"
awk -v a="$IRQ0" -v b="$IRQ1" 'BEGIN{
  n=split(a,A," "); split(b,B," ");
  for(i=1;i<=n;i++){ split(A[i],x,"="); split(B[i],y,"="); if(x[1]!="") printf "    %-11s +%d\n", x[1], y[2]-x[2] }
}'
echo "  -- per-minute rates over $((BOOT1 - BOOT0))s --"
awk -v d=$((BOOT1 - BOOT0)) -v s=$((SUS1 - SUS0)) -v f=$((FAIL1 - FAIL0)) 'BEGIN{
  if (d<1) d=1;
  printf "    suspends/min %.2f   failures/min %.2f\n", s*60/d, f*60/d
}'
if [ -n "$EARLY" ]; then echo "  !! window ended EARLY: $EARLY"; fi
echo "  -- validity --"
case "$END_SCREEN" in Asleep|Dozing) _sc=ok ;; *) _sc="BAD:screen was [$_END_SCREEN]" ;; esac
case "$END_WIFI" in *enabled) _wf=ok ;; *) _wf="BAD:[$END_WIFI]" ;; esac
echo "    screen at end: $_sc"
echo "    wifi at end:   $_wf"
echo "    wake locks:    size=$(wlock_state)"
echo "    a window is only trustworthy if all three say ok"

echo
echo "===== BATTERYSTATS HISTORY (for offline analysis) ====="
timeout 180 dumpsys batterystats --history > "$D/ie-history.txt" 2>/dev/null
echo "  saved $(wc -l < $D/ie-history.txt 2>/dev/null) lines to $D/ie-history.txt"
echo "  screen-on events in history: $(grep -c 'screen_on' $D/ie-history.txt 2>/dev/null)"
echo "  checkpoints recorded: $(wc -l < $CHKTSV 2>/dev/null)"
