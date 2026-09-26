#!/system/bin/sh
# v3.9.1 batch-tool benchmark: shell fork vs in-process JVM, cold and warm.
cd /data/adb/spsm/scripts || exit 1
exec > /data/local/tmp/bench2.log 2>&1
echo "=== BENCH1 start $(date) ==="
cat /proc/loadavg
grep -E 'MemFree|SwapFree' /proc/meminfo

t() { # t LABEL cmd...
  _l=$1; shift
  _s=$(date +%s)
  "$@" >/dev/null 2>&1
  _e=$(date +%s)
  echo "$_l=$(( _e - _s ))s"
}
su_t() { # su_t LABEL <shell command string>
  _s=$(date +%s)
  su 2000 -c "$2" >/dev/null 2>&1
  _e=$(date +%s)
  echo "$1=$(( _e - _s ))s"
}
rt() { # rt LABEL <shell command string> - run as ROOT (tool_shellbatch does its own su 2000, exactly like the engine)
  _s=$(date +%s)
  sh -c "$2" >/dev/null 2>&1
  _e=$(date +%s)
  echo "$1=$(( _e - _s ))s"
}

echo "=== JVM_BOOT_ALONE (no verb -> usage rc=2) ==="
su_t jvm_boot 'CLASSPATH=/data/local/tmp/spsm/spsm-tool.jar app_process / dev.axion.spsm.tool.Main'

echo "=== SHELL_FORKS ==="
su_t fork_activity 'cmd activity get-standby-bucket com.whatsapp'
su_t fork_appops 'cmd appops get com.whatsapp RUN_IN_BACKGROUND'
su_t fork_pm 'pm list packages -3'
su_t fork_settings 'cmd settings get global low_power'

echo "=== TOOL 1OP ==="
printf 'activity\tget-standby-bucket\tcom.whatsapp\n' > /data/local/tmp/tb1.in
rt tool_1op '. ./lib.sh && tool_shellbatch /data/local/tmp/tb1.in'
rt tool_1op_warm '. ./lib.sh && tool_shellbatch /data/local/tmp/tb1.in'

echo "=== TOOL 8OPS homogeneous (activity) ==="
: > /data/local/tmp/tb8.in
for p in com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm; do
  printf 'activity\tget-standby-bucket\t%s\n' "$p" >> /data/local/tmp/tb8.in
done
rt tool_8ops '. ./lib.sh && tool_shellbatch /data/local/tmp/tb8.in'
rt tool_8ops_warm '. ./lib.sh && tool_shellbatch /data/local/tmp/tb8.in'
echo "--- 8op frames:"
. ./lib.sh && tool_shellbatch /data/local/tmp/tb8.in | grep '^###'

echo "=== TOOL 20OPS mixed (10 activity + 10 appops) ==="
: > /data/local/tmp/tb20.in
for p in com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.android.settings; do
  printf 'activity\tget-standby-bucket\t%s\n' "$p" >> /data/local/tmp/tb20.in
  printf 'appops\tget\t%s\tRUN_IN_BACKGROUND\n' "$p" >> /data/local/tmp/tb20.in
done
for p in com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.android.settings; do
  printf 'activity\tget-standby-bucket\t%s\n' "$p" >> /data/local/tmp/tb20.in
  printf 'appops\tget\t%s\tRUN_ANY_IN_BACKGROUND\n' "$p" >> /data/local/tmp/tb20.in
done
rt tool_20ops '. ./lib.sh && tool_shellbatch /data/local/tmp/tb20.in'
echo "--- 20op rc summary:"
. ./lib.sh && tool_shellbatch /data/local/tmp/tb20.in | awk -F'\t' '/^###/ && $2!="END" {print $2, $3}' | sort | uniq -c

echo "=== TOOL 20OPS unstop (idempotent) ==="
: > /data/local/tmp/tbu.in
for p in com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.android.settings com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.android.settings; do
  printf 'package\tunstop\t--user\t0\t%s\n' "$p" >> /data/local/tmp/tbu.in
  printf 'package\tunstop\t--user\t0\t%s\n' "$p" >> /data/local/tmp/tbu.in
done
rt tool_unstop20 '. ./lib.sh && tool_shellbatch /data/local/tmp/tbu.in'

echo "=== SHELL_FAN comparison: 20 unstop forks ==="
_s=$(date +%s)
for p in com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.android.settings com.whatsapp com.google.android.gm.lite com.instagram.android dev.axion.spsm com.android.settings; do
  su 2000 -c "pm unstop --user 0 $p" >/dev/null 2>&1
  su 2000 -c "pm unstop --user 0 $p" >/dev/null 2>&1
done
_e=$(date +%s)
echo "shell_unstop20=$(( _e - _s ))s"

rm -f /data/local/tmp/tb1.in /data/local/tmp/tb8.in /data/local/tmp/tb20.in /data/local/tmp/tbu.in
echo "=== BENCH1 done $(date) ==="
