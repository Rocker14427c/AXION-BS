#!/system/bin/sh
# Re-assert G85 PPM / GPU / hotplug. libperfmgr will try to undo this.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

still_on || {
  [ -f "$DISABLE" ] && [ ! -f "$EXITING" ] && sh "$SCRIPT_DIR/exit.sh"
  exit 0
}

apply_hw
still_on || exit 0

silence_logs
if screen_is_off; then
  # Push toward deep doze, but do NOT step once IDLE (that oscillates
  # IDLE <-> IDLE_MAINTENANCE and wakes jobs). Never force-idle: blocks calls.
  st=$(dumpsys deviceidle get deep 2>/dev/null)
  case "$st" in
    IDLE) ;;
    *) dumpsys deviceidle step deep >/dev/null 2>&1 ;;
  esac
  freeze_google
else
  dumpsys deviceidle unforce >/dev/null 2>&1
  sput global low_power 1
  sput global low_power_sticky 1
fi

still_on || exit 0

# App freeze is expensive; only every ~60s (service loop is 15s)
cnt_file="$SPSM_DIR/wd_count"
cnt=$(cat "$cnt_file" 2>/dev/null)
[ -n "$cnt" ] || cnt=0
cnt=$((cnt + 1))
echo "$cnt" > "$cnt_file"
if [ $((cnt % 4)) -eq 0 ]; then
  pm list packages -3 2>/dev/null | sed 's/package://' | while read -r pkg; do
    [ -n "$pkg" ] || continue
    is_protected "$pkg" && continue
    pm suspend "$pkg" >/dev/null 2>&1
  done
  # A75 must stay down if PowerHAL / hotplug brings them back
  w 0 /sys/devices/system/cpu/cpu6/online
  w 0 /sys/devices/system/cpu/cpu7/online
fi

exit 0
