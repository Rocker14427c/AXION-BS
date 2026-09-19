#!/system/bin/sh
# Axion SPSM v3 - very early boot safety net.
#
# Runs before the rest of the system is up. If a journal exists, the phone was
# rebooted (or lost power) while SPSM was on, so first put back the things that
# make a phone usable - online cores, a sane governor, a visible backlight -
# and only then let service.sh do the full journalised revert.
#
# This is the reason a crash or a battery pull can never leave the device
# capped, offline or dark.

MODDIR=${0%/*}
SPSM_DIR=${SPSM_DIR:-/data/adb/spsm}

[ -d "$SPSM_DIR" ] || exit 0

# A progress file is only valid while a transition is actually running. One
# left over from a crash or a power cut would tell the Quick Settings tile
# "working" forever, so it does not survive a boot.
rm -f "$SPSM_DIR/state/progress" 2>/dev/null


# shellcheck source=/dev/null
. "$SPSM_DIR/scripts/lib.sh" 2>/dev/null || . "$MODDIR/scripts/lib.sh" 2>/dev/null || exit 0

# This script runs on EVERY boot, so it must be certain there is something to
# undo before it touches the phone. The journal directory always exists; only a
# journal with entries in it, or the active flag, means the last shutdown
# happened with the mode on. Forcing cores/governor/backlight on a normal boot
# would overwrite the user's own settings for no reason.
# A journal is not the same thing as an unfinished session. Only a knob still
# marked applied, or the active flag, means the phone may be running with values
# of ours - force anything on any other boot and the user's own settings pay.
if [ "$(pending_knobs)" = "0" ] && [ ! -f "$ACTIVE" ]; then
  exit 0
fi

log "post-fs-data: unfinished session found, pre-restoring safety valves"
safety_force

# Leave a marker so service.sh knows a revert is owed even if the journal is
# half-written.
touch "$STATE/needs_restore" 2>/dev/null
exit 0
