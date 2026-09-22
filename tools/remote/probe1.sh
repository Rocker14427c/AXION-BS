echo "== probe1 $(date '+%F %T') =="
echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
for f in /sys/power/suspend_stats/*; do echo "sus_$(basename $f)=$(cat $f 2>/dev/null)"; done
echo "wakeup_count=$(cat /sys/power/wakeup_count 2>/dev/null)"
for f in current_now voltage_now capacity charge_counter status; do echo "bat_$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)"; done
echo "spsm_active=$([ -f /data/adb/spsm/state/active ] && echo yes || echo no)"
