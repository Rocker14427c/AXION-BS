#!/system/bin/sh
# Re-assert CPU/GPU/Wi-Fi only. Never freeze apps, never touch logd, never doze.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

still_on || exit 0

apply_hw
still_on || exit 0
# A75 must stay down if PowerHAL onlines them
w 0 /sys/devices/system/cpu/cpu6/online
w 0 /sys/devices/system/cpu/cpu7/online
exit 0
