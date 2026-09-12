#!/system/bin/sh
# Axion SPSM v3 - module removal.
#
# Order matters: put the device back FIRST, then remove the code that knows how.
# Uninstalling must never be the reason a cap stays behind.
MODDIR=${0%/*}
SPSM_DIR=${SPSM_DIR:-/data/adb/spsm}

if [ -f "$SPSM_DIR/scripts/engine.sh" ]; then
  sh "$SPSM_DIR/scripts/engine.sh" deactivate >> "$SPSM_DIR/spsm.log" 2>&1
fi
# Only force the safety valves if the revert above did not finish. When it did,
# the phone is already exactly as it was found and forcing cores, governor and
# backlight would overwrite settings the user chose for themselves.
_pending=1
if [ -f "$SPSM_DIR/scripts/lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$SPSM_DIR/scripts/lib.sh" 2>/dev/null
  [ "$(journal_entries 2>/dev/null)" = "0" ] && _pending=0
fi
[ "$_pending" = "1" ] && safety_force

# The app is ours; take it with us.
pm unsuspend com.google.android.gms >/dev/null 2>&1
pm enable --user 0 com.google.android.gms >/dev/null 2>&1
pm uninstall --user 0 dev.axion.spsm >/dev/null 2>&1
pm uninstall dev.axion.spsm >/dev/null 2>&1

rm -rf "$SPSM_DIR"
