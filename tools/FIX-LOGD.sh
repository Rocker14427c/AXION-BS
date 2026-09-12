#!/system/bin/sh
# Fix Logfox "waiting for log" after SPSM set persist.log.tag=S and stopped logd.
# Run as root (same way as last time):  su -c 'sh /sdcard/FIX-LOGD.sh'

echo "===== LOGD FIX start ====="
echo "uid=$(id -u)"
if [ "$(id -u)" != "0" ]; then
  echo "NOT ROOT. Asking SukiSU..."
  exec su -c "sh \"$0\""
fi

rpdel() {
  key="$1"
  resetprop --delete "$key" >/dev/null 2>&1
  resetprop -p --delete "$key" >/dev/null 2>&1
  if [ -x /data/adb/ksud ]; then
    /data/adb/ksud resetprop --delete "$key" >/dev/null 2>&1
  fi
  if [ -x /data/adb/magisk/resetprop ]; then
    /data/adb/magisk/resetprop --delete "$key" >/dev/null 2>&1
    /data/adb/magisk/resetprop -p --delete "$key" >/dev/null 2>&1
  fi
  setprop "$key" "" >/dev/null 2>&1
}

echo "BEFORE:"
echo "  persist.log.tag=[$(getprop persist.log.tag)]"
echo "  log.tag=[$(getprop log.tag)]"
echo "  persist.logd.size=[$(getprop persist.logd.size)]"
echo "  init.svc.logd=[$(getprop init.svc.logd)]"

# v1.8 silence_logs leftovers (these survive reboot)
rpdel persist.log.tag
rpdel log.tag
rpdel persist.logd.logpersistd
rpdel persist.logd.size
rpdel persist.log.tag.snet_event_log
setprop persist.log.tag ""
setprop log.tag ""
setprop persist.logd.size 262144

echo "4 4 1 7" > /proc/sys/kernel/printk 2>/dev/null

# Start / restart logd (ctl.start works when "start" does not)
setprop ctl.start logd
setprop ctl.start logd-reinit
setprop ctl.restart logd
start logd >/dev/null 2>&1
start logd-reinit >/dev/null 2>&1
start statsd >/dev/null 2>&1
sleep 1
setprop ctl.start logd
sleep 1

echo "AFTER:"
echo "  persist.log.tag=[$(getprop persist.log.tag)]"
echo "  log.tag=[$(getprop log.tag)]"
echo "  persist.logd.size=[$(getprop persist.logd.size)]"
echo "  init.svc.logd=[$(getprop init.svc.logd)]"
echo "  logd pid: $(pidof logd 2>/dev/null)"
echo "logcat sample (should NOT be empty):"
logcat -d -t 8 2>&1 | head -12
echo "===== LOGD FIX done ====="
echo "Force-stop Logfox, open it again. If still waiting: another module (PowerSaverPro) is still silencing logs — disable that module and reboot."
