#!/system/bin/sh
# Module removed: restore snapshot, uninstall leftover user app.
MODDIR=${0%/*}
SPSM_DIR=/data/adb/spsm
touch "$SPSM_DIR/disable" 2>/dev/null
if [ -f "$SPSM_DIR/exit.sh" ]; then
  sh "$SPSM_DIR/exit.sh"
elif [ -f "$MODDIR/scripts/exit.sh" ]; then
  sh "$MODDIR/scripts/exit.sh"
fi
pm uninstall --user 0 dev.axion.spsm >/dev/null 2>&1
pm uninstall dev.axion.spsm >/dev/null 2>&1
rm -rf /data/adb/spsm
