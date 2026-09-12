#!/system/bin/sh
# Late-start: copy scripts, resume SPSM after reboot if it was on.
# Overlay APK is enough; do not pm-install every boot (that left a user copy).

MODDIR=${0%/*}
SPSM_DIR=/data/adb/spsm
mkdir -p "$SPSM_DIR"

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do
  sleep 2
  i=$((i + 1))
done
sleep 5

echo "$MODDIR" > "$SPSM_DIR/moddir"
cp -af "$MODDIR/scripts/"*.sh "$SPSM_DIR/" 2>/dev/null
chmod 755 "$SPSM_DIR/"*.sh 2>/dev/null

# Resume only if user left SPSM on
if [ -f "$SPSM_DIR/active" ] && [ ! -f "$SPSM_DIR/disable" ]; then
  rm -f "$SPSM_DIR/exiting"
  sh "$MODDIR/scripts/enter.sh" >> "$SPSM_DIR/spsm.log" 2>&1
fi

while true; do
  if [ -f "$SPSM_DIR/active" ] && [ ! -f "$SPSM_DIR/exiting" ] && [ ! -f "$SPSM_DIR/disable" ]; then
    sh "$MODDIR/scripts/watchdog.sh" >> "$SPSM_DIR/spsm.log" 2>&1
    sleep 20
  else
    sleep 60
  fi
done
