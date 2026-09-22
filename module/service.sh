#!/system/bin/sh
# Axion SPSM v3 - late_start service.
#
# Responsibilities, in order:
#   1. wait for the system to finish booting
#   2. publish a fresh copy of the scripts and the knob list
#   3. if the last shutdown happened while SPSM was on, REVERT rather than
#      resume - a reboot is not a reason for someone to be stuck in a mode
#      they cannot see the exit for. resume_on_boot=1 restores the old
#      behaviour for anyone who wants it.
#   4. otherwise start the screen-aware daemon

MODDIR=${0%/*}
SPSM_DIR=${SPSM_DIR:-/data/adb/spsm}

mkdir -p "$SPSM_DIR"

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do
  sleep 2
  i=$((i + 1))
done
sleep 3

echo "$MODDIR" > "$SPSM_DIR/moddir"
mkdir -p "$SPSM_DIR/scripts"
cp -af "$MODDIR/scripts/." "$SPSM_DIR/scripts/" 2>/dev/null
chmod 755 "$SPSM_DIR/scripts/"*.sh 2>/dev/null
# The same stamp the installer writes, refreshed on every boot: if these two ever
# disagree with module.prop, the phone is running stale scripts.
_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)
[ -n "$_VERSION" ] && printf '%s\n' "$_VERSION" > "$SPSM_DIR/state/script_version" 2>/dev/null

# The native helpers, refreshed on every boot for the same reason the scripts
# are: a module update must not leave the phone running the previous version's
# binary. publish_native verifies the ABI by executing it, and does nothing at
# all if none of the shipped builds run here.
if [ -d "$MODDIR/bin" ]; then
  # shellcheck source=/dev/null
  . "$SPSM_DIR/scripts/lib.sh" 2>/dev/null && publish_native "$MODDIR"
fi

ENGINE="$SPSM_DIR/scripts/engine.sh"
[ -f "$ENGINE" ] || ENGINE="$MODDIR/scripts/engine.sh"

# Publish the knob list for the options screen.
sh "$ENGINE" dump-knobs >> "$SPSM_DIR/spsm.log" 2>&1

# --- release anything a dead session left suspended --------------------------
# Android persists app suspensions across reboots, and only an explicit
# unsuspend clears them. If the last session was killed before its exit ran,
# this is the pass that frees the phone. Runs only when the mode is OFF (when
# it is on, the six-slot record belongs to the live session).
if [ ! -f "$SPSM_DIR/state/active" ] && [ -s "$SPSM_DIR/state/blocked_by_us.tsv" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') service: releasing apps a dead session left suspended" >> "$SPSM_DIR/spsm.log"
  sh "$ENGINE" six-restore >> "$SPSM_DIR/spsm.log" 2>&1
fi

# --- stale per-run caches ----------------------------------------------------
# protected_packages caches its eight binder lookups in a pid-scoped file for
# the length of one engine run. The run's own stamp means a leftover can never
# be read as valid, so this is housekeeping rather than correctness - but on a
# phone whose tmp survives, one file per run would otherwise accumulate for
# ever. Boot is the one moment no engine run is in flight.
rm -f "${TMPDIR:-/tmp}"/.spsm-protected.* 2>/dev/null

# --- crash / reboot recovery -------------------------------------------------
if [ -f "$SPSM_DIR/state/needs_restore" ] || { [ -d "$SPSM_DIR/journal" ] && [ -f "$SPSM_DIR/state/active" ]; }; then
  RESUME=$(sed -n 's/^resume_on_boot=//p' "$SPSM_DIR/config" 2>/dev/null | tail -1)
  if [ "$RESUME" = "1" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') service: resuming SPSM after reboot" >> "$SPSM_DIR/spsm.log"
    sh "$ENGINE" activate >> "$SPSM_DIR/spsm.log" 2>&1
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') service: reverting SPSM left over from last boot" >> "$SPSM_DIR/spsm.log"
    sh "$ENGINE" deactivate >> "$SPSM_DIR/spsm.log" 2>&1
  fi
  rm -f "$SPSM_DIR/state/needs_restore"
fi

# --- daemon ------------------------------------------------------------------
# The engine starts and stops the daemon itself; all we do here is make sure
# one is running if the mode is on (e.g. it was resumed above).
if [ -f "$SPSM_DIR/state/active" ]; then
  sh "$ENGINE" start-daemon >> "$SPSM_DIR/spsm.log" 2>&1
fi
