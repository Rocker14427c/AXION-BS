#!/system/bin/sh
# =============================================================================
# Controlled Wi-Fi / Doze experiment: four screen-off windows, one variable each.
#
#   su -c 'setsid sh /data/local/tmp/wifiexp.sh </dev/null >/dev/null 2>&1 &'
#
# Requires: unplugged, discharging, battery >= 25%, and the agent will kill the
# tunnel + Termux wake lock at 2:30 so the phone is free to suspend. Reopen
# Termux afterwards.
#
#   V0  control - nothing changed (reproduces the "deep window" baseline)
#   V1  scan-always off, Wi-Fi sleep policy = always
#   V2  V1 + Wi-Fi radio off (cellular stays registered: calls/SMS unaffected)
#   V3  V2 + GMS and Play Store removed from the Doze whitelist
#
# Each window is 600 s of wall clock, screen off, phone untouched. Every counter
# is cumulative, so only deltas are reported. Everything is restored at the end.
# =============================================================================
OUT=/data/local/tmp/wifiexp.out
D=/data/local/tmp
GRACE=150
SETTLE=45
WIN=600
: > "$OUT"; exec >> "$OUT" 2>&1

revert_all() {
  cmd wifi set-scan-always-available enabled >/dev/null 2>&1
  settings put global wifi_scan_always_enabled 1 >/dev/null 2>&1
  [ -n "$SAVED_SLEEP" ] && settings put global wifi_sleep_policy "$SAVED_SLEEP" >/dev/null 2>&1
  cmd wifi set-wifi-enabled enabled >/dev/null 2>&1
  settings put global wifi_on 1 >/dev/null 2>&1
  for p in com.google.android.gms com.android.vending; do
    dumpsys deviceidle whitelist +"$p" >/dev/null 2>&1
  done
}
trap 'revert_all' EXIT

wait_for() { while [ "$(date +%s)" -lt "$1" ]; do sleep 20; done; }
until_in() { echo $(( $(date +%s) + $1 )); }

snap() { # snap <tag>
  _t=$1
  {
    echo "wall_epoch=$(date +%s)"
    echo "sus_success=$(cat /sys/power/suspend_stats/success 2>/dev/null)"
    echo "sus_fail=$(cat /sys/power/suspend_stats/fail 2>/dev/null)"
    echo "sus_last_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null)"
    echo "charge_counter=$(cat /sys/class/power_supply/battery/charge_counter 2>/dev/null)"
    echo "current_now=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"
    echo "capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
    for c in cpu0 cpu6; do
      for st in 0 1; do
        _n=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/name 2>/dev/null)
        echo "idle_${c}_${_n}_usage=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/usage 2>/dev/null)"
        echo "idle_${c}_${_n}_time_us=$(cat /sys/devices/system/cpu/$c/cpuidle/state$st/time 2>/dev/null)"
      done
    done
    echo "wifi_enabled=$(cmd wifi status 2>/dev/null | head -1 | tr -d '\r')"
  } > "$D/we-$_t.txt" 2>/dev/null
  cp /proc/interrupts "$D/we-irq-$_t.txt" 2>/dev/null
  echo "  [$1] $(date '+%T') sus_ok=$(sed -n 's/^sus_success=//p' $D/we-$_t.txt) sus_fail=$(sed -n 's/^sus_fail=//p' $D/we-$_t.txt) charge=$(sed -n 's/^charge_counter=//p' $D/we-$_t.txt) uA=$(sed -n 's/^current_now=//p' $D/we-$_t.txt)"
}

wakeups() { timeout 60 dumpsys batterystats --charged 2>/dev/null | sed -n '/All wakeup reasons/,/^$/p' > "$D/we-wake-$1.txt"; }

irqs() {
  awk 'NR>1 {irq=$1; sub(":","",irq); c=0; nm="";
        for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/){c+=$i} else {nm=substr($0,index($0,$i)); break} }
        printf "%s\t%d\t%s\n", irq, c, nm}' "$D/we-irq-$1.txt" 2>/dev/null | sort > "$D/wei-$1.tmp"
}

report() { # report <pre> <post> <label>
  _a=$(sed -n 's/^wall_epoch=//p' "$D/we-$1.txt" | head -1)
  _b=$(sed -n 's/^wall_epoch=//p' "$D/we-$2.txt" | head -1)
  _w=$(( _b - _a ))
  echo
  echo "######## $3  (wall ${_w}s) ########"
  for k in sus_success sus_fail; do
    _x=$(sed -n "s/^$k=//p" "$D/we-$1.txt" | head -1)
    _y=$(sed -n "s/^$k=//p" "$D/we-$2.txt" | head -1)
    printf "  %-12s +%s   (%s/min)\n" "$k" "$(( _y - _x ))" "$(awk "BEGIN{printf \"%.1f\", ($_y-$_x)/($_w/60)}")"
  done
  _x=$(sed -n 's/^charge_counter=//p' "$D/we-$1.txt" | head -1)
  _y=$(sed -n 's/^charge_counter=//p' "$D/we-$2.txt" | head -1)
  printf "  drained_uAh  %s  (%.2f%% of 6000000 uAh)\n" "$(( _x - _y ))" "$(awk "BEGIN{printf \"%.2f\", ($_x-$_y)/60000}")"
  printf "  uA at end    %s\n" "$(sed -n 's/^current_now=//p' "$D/we-$2.txt" | head -1)"
  for c in cpu0 cpu6; do
    for n in rgidle mcdi; do
      _x=$(grep -m1 "^idle_${c}_${n}_time_us=" "$D/we-$1.txt" | cut -d= -f2)
      _y=$(grep -m1 "^idle_${c}_${n}_time_us=" "$D/we-$2.txt" | cut -d= -f2)
      [ -n "$_x" ] && [ -n "$_y" ] && printf "  idle %s %-7s %5.1f%% of window\n" "$c" "$n" "$(awk "BEGIN{printf \"%.1f\", ($_y-$_x)/10000/$_w}")"
    done
  done
  irqs "$1"; irqs "$2"
  echo "  -- interrupts: wlan0 / ccci / silfp / arch_timer deltas --"
  for pat in wlan0 ccci silfp touchpanel arch_timer; do
    _x=$(grep -m1 "$pat" "$D/wei-$1.tmp" 2>/dev/null | awk -F'\t' '{print $2}')
    _y=$(grep -m1 "$pat" "$D/wei-$2.tmp" 2>/dev/null | awk -F'\t' '{print $2}')
    [ -n "$_x" ] && [ -n "$_y" ] && printf "    %-10s +%s\n" "$pat" "$(( _y - _x ))"
  done
  echo "  -- top 8 wakeup reasons by increase --"
  sed -n 's/^ *Wakeup reason \(.*\): .* (\([0-9]*\) times).*/\2|\1/p' "$D/we-wake-$1.txt" 2>/dev/null | sort -t'|' -k2 > "$D/wew-$1.tmp"
  sed -n 's/^ *Wakeup reason \(.*\): .* (\([0-9]*\) times).*/\2|\1/p' "$D/we-wake-$2.txt" 2>/dev/null | sort -t'|' -k2 > "$D/wew-$2.tmp"
  awk -F'|' 'NR==FNR{a[$2]=$1; next} {d=$1-(a[$2]+0); if (d>0) printf "    %6d  %s\n", d, $2}' \
      "$D/wew-$1.tmp" "$D/wew-$2.tmp" 2>/dev/null | sort -rn | head -8
}

window() { # window <tag> <variant_name>
  echo
  echo "################ $2 ################"
  snap "$1"
  wakeups "$1"
  wait_for "$(until_in $WIN)"
  snap "$1-end"
  wakeups "$1-end"
  report "$1" "$1-end" "$2"
}

echo "################ WIFI / DOZE EXPERIMENT  $(date '+%F %T') ################"
echo "status=$(cat /sys/class/power_supply/battery/status) level=$(cat /sys/class/power_supply/battery/capacity)% usb=$(cat /sys/class/power_supply/usb/online 2>/dev/null)"
echo "spsm_active=$( [ -f /data/adb/spsm/state/active ] && echo yes || echo no )"
SAVED_SLEEP=$(settings get global wifi_sleep_policy 2>/dev/null)
echo "saved wifi_sleep_policy=[$SAVED_SLEEP] scan_always=[$(cmd wifi status 2>/dev/null | grep -i 'scanning is' | tr -d '\r')]"

echo; echo "===== GRACE ${GRACE}s: the tunnel will be killed at the end of this ====="
wait_for "$(until_in $GRACE)"

echo; echo "===== REMOVING THE AGENT'S FOOTPRINT ====="
for p in $(ps -A -o PID,CMD 2>/dev/null | grep -E "pinggy|localhost\.run|ssh .*-R " | grep -v grep | awk '{print $1}'); do kill -9 "$p" 2>/dev/null; echo "  killed tunnel pid $p"; done
pkill -9 -f "/data/data/com.termux/files/usr/bin/sshd" 2>/dev/null
_pid=$(timeout 40 dumpsys power 2>/dev/null | sed -n 's/.*termux.*pid=\([0-9]*\).*/\1/p' | head -1)
[ -n "$_pid" ] && { echo "  releasing Termux wake lock by killing pid $_pid"; kill -9 "$_pid" 2>/dev/null; }
pkill -9 -f "com.termux" 2>/dev/null
sleep 20
echo "  wake locks now: $(timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | head -3 | tr '\n' ' ')"
echo "  agent wake locks remaining: $(timeout 40 dumpsys power 2>/dev/null | sed -n '/Wake Locks:/,/^$/p' | grep -c termux)"

wake_screen() { input keyevent 26 2>/dev/null; sleep 3; input keyevent 26 2>/dev/null; }
screen_off_wait() { input keyevent 26 2>/dev/null; wait_for "$(until_in $SETTLE)"; }

# ---------------------------------------------------------------- V0 control
screen_off_wait
window v0 "V0 CONTROL — nothing changed"

# ---------------------------------------------------------------- V1 scan suppression
wake_screen
echo; echo "===== applying V1: scan-always off + sleep policy always ====="
cmd wifi set-scan-always-available disabled >/dev/null 2>&1; echo "  set-scan-always-available rc=$?"
settings put global wifi_scan_always_enabled 0 >/dev/null 2>&1
case "$SAVED_SLEEP" in ''|null) settings put global wifi_sleep_policy 2 >/dev/null 2>&1 ;; *) settings put global wifi_sleep_policy 2 >/dev/null 2>&1 ;; esac
echo "  scan_always now: $(cmd wifi status 2>/dev/null | grep -i 'scanning is' | tr -d '\r')  sleep_policy=$(settings get global wifi_sleep_policy)"
screen_off_wait
window v1 "V1 SCAN SUPPRESSED — scan-always off, sleep policy always"

# ---------------------------------------------------------------- V2 wifi radio off
wake_screen
echo; echo "===== applying V2: Wi-Fi radio off (cellular stays registered) ====="
cmd wifi set-wifi-enabled disabled >/dev/null 2>&1; svc wifi disable >/dev/null 2>&1
settings put global wifi_on 0 >/dev/null 2>&1
sleep 10
echo "  wifi status: $(cmd wifi status 2>/dev/null | head -1 | tr -d '\r')"
echo "  cellular: $(dumpsys telephony.registry 2>/dev/null | grep -m1 mServiceState | cut -c1-90)"
screen_off_wait
window v2 "V2 WI-FI OFF IN IDLE — scan off + radio off, cellular registered"

# ---------------------------------------------------------------- V3 doze whitelist trim
wake_screen
echo; echo "===== applying V3: + GMS and Play Store out of the Doze whitelist ====="
dumpsys deviceidle whitelist -com.google.android.gms >/dev/null 2>&1
dumpsys deviceidle whitelist -com.android.vending >/dev/null 2>&1
echo "  whitelist entries now: $(dumpsys deviceidle whitelist 2>/dev/null | grep -c gms)\
 / $(dumpsys deviceidle whitelist 2>/dev/null | wc -l) total"
screen_off_wait
window v3 "V3 WI-FI OFF + GMS/PLAY NOT DOZE-EXEMPT"

# ---------------------------------------------------------------- restore
echo; echo "################ RESTORING ################"
input keyevent 26 2>/dev/null
sleep 5
revert_all
sleep 5
echo "  scan_always: $(cmd wifi status 2>/dev/null | grep -i 'scanning is' | tr -d '\r')"
echo "  wifi: $(cmd wifi status 2>/dev/null | head -1 | tr -d '\r')"
echo "  sleep_policy restored to [$SAVED_SLEEP] -> [$(settings get global wifi_sleep_policy)]"
echo "  doze whitelist total: $(dumpsys deviceidle whitelist 2>/dev/null | wc -l)"
echo "  gms exempt again: $(dumpsys deviceidle whitelist 2>/dev/null | grep -c 'com.google.android.gms')"
echo
echo "  FINAL: sus_success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail) last_dev=$(cat /sys/power/suspend_stats/last_failed_dev)"
echo "  battery: $(cat /sys/class/power_supply/battery/capacity)% charge_counter=$(cat /sys/class/power_supply/battery/charge_counter)"
echo; echo "################ DONE $(date '+%F %T') — reopen Termux, restart sshd and the tunnel ################"
