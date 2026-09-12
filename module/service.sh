#!/system/bin/sh
# Late-start service: install APK, wire /data/adb/spsm, resume SPSM after reboot.

MODDIR=${0%/*}
SPSM_DIR=/data/adb/spsm
mkdir -p "$SPSM_DIR"

# Wait for boot
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do
  sleep 2
  i=$((i + 1))
done
sleep 8

# Stable paths the app calls
echo "$MODDIR" > "$SPSM_DIR/moddir"
cp -af "$MODDIR/scripts/"*.sh "$SPSM_DIR/" 2>/dev/null
chmod 755 "$SPSM_DIR/"*.sh 2>/dev/null

# Install / update the companion app
APK="$MODDIR/app/AxionSPSM.apk"
if [ -f "$APK" ]; then
  pm install -r --user 0 "$APK" >/dev/null 2>&1
  pm grant dev.axion.spsm android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
  appops set dev.axion.spsm QUERY_ALL_PACKAGES allow >/dev/null 2>&1
  appops set dev.axion.spsm RUN_IN_BACKGROUND allow >/dev/null 2>&1
fi

# If mode was on, re-apply after reboot
if [ -f "$SPSM_DIR/active" ] && [ ! -f "$SPSM_DIR/disable" ]; then
  rm -f "$SPSM_DIR/exiting"
  sh "$MODDIR/scripts/enter.sh" >/dev/null 2>&1
fi

# Watchdog loop
while true; do
  if [ -f "$SPSM_DIR/active" ] && [ ! -f "$SPSM_DIR/exiting" ]; then
    sh "$MODDIR/scripts/watchdog.sh" >/dev/null 2>&1
    sleep 15
  else
    sleep 45
  fi
done
