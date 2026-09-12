#!/system/bin/sh
# Exit Super Power Saving — restore from snapshot files (sysfs first).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

log "===== EXIT SPSM v2 ====="
echo 1 > "$EXITING"
rm -f "$ACTIVE"

restore_all
verify_restore

rm -f "$EXITING"
# Keep snap until verify looks sane, then drop it so next enter is a fresh backup
online=$(cat /sys/devices/system/cpu/online 2>/dev/null)
gov=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_governor 2>/dev/null)
if echo "$online" | grep -q 6 && echo "$online" | grep -q 7; then
  rm -rf "$SNAP"
  mkdir -p "$SNAP"
  log "snap cleared (cores back)"
else
  log "WARN cores not fully online ($online) — keeping snap"
fi

log "===== SPSM OFF ====="
exit 0
