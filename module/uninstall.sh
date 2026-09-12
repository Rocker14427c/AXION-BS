#!/system/bin/sh
# Restore the phone if the module is removed while SPSM is on.
SPSM_DIR=/data/adb/spsm
if [ -f "$SPSM_DIR/exit.sh" ]; then
  sh "$SPSM_DIR/exit.sh" >/dev/null 2>&1
elif [ -f "$MODDIR/scripts/exit.sh" ]; then
  sh "$MODDIR/scripts/exit.sh" >/dev/null 2>&1
fi
pm uninstall dev.axion.spsm >/dev/null 2>&1
rm -rf /data/adb/spsm
