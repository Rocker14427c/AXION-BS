#!/system/bin/sh
# deploy-keep.sh -- put v3.8.2 on the phone: the new scripts, the new APK, the
# keep-awake list, and the proof that each one landed.
#
#   usage: deploy-keep.sh <dir-with-payload>     (default /data/local/tmp/spsm382)
#
# The payload directory holds:
#   knobs.sh engine.sh lib.sh        the updated engine
#   AxionSPSM.apk                    the updated app
#
# TWO destinations, deliberately. /data/adb/spsm/scripts is what RUNS; the module
# directory /data/adb/modules/axion_spsm is what service.sh re-publishes on every
# boot. Updating only the first would look perfect until the next reboot quietly
# restored the old scripts - which is exactly the kind of "it worked yesterday"
# bug this project keeps finding the hard way.

P=${1:-/data/local/tmp/spsm382}
MOD=/data/adb/modules/axion_spsm
RUN=/data/adb/spsm
SAY() { echo "  $*"; }
FAIL=0

echo "== 1. payload =="
for f in knobs.sh engine.sh AxionSPSM.apk; do
  [ -f "$P/$f" ] || { SAY "MISSING $P/$f"; exit 1; }
  SAY "$f  $(wc -c < "$P/$f" | tr -d ' ') bytes"
done
[ -f "$P/lib.sh" ] && SAY "lib.sh present" || SAY "lib.sh absent (only copied if newer)"

echo "== 2. the running copy: $RUN/scripts =="
for f in knobs.sh engine.sh lib.sh; do
  [ -f "$P/$f" ] || continue
  cp -f "$P/$f" "$RUN/scripts/$f" && chmod 755 "$RUN/scripts/$f" || FAIL=1
  SAY "$f -> $RUN/scripts ($(md5sum "$RUN/scripts/$f" | cut -c1-16))"
done

echo "== 3. the boot copy: $MOD =="
if [ -d "$MOD" ]; then
  for f in knobs.sh engine.sh lib.sh; do
    [ -f "$P/$f" ] || continue
    mkdir -p "$MOD/scripts"
    cp -f "$P/$f" "$MOD/scripts/$f" && chmod 755 "$MOD/scripts/$f" || FAIL=1
    SAY "$f -> $MOD/scripts ($(md5sum "$MOD/scripts/$f" | cut -c1-16))"
  done
  [ -f "$P/module.prop" ] && cp -f "$P/module.prop" "$MOD/module.prop" && SAY "module.prop updated"
  SAY "module.prop says: $(sed -n 's/^version=//p' "$MOD/module.prop" 2>/dev/null)"
else
  SAY "!! $MOD is not there - is the module installed?"
  FAIL=1
fi

echo "== 4. the keep-awake list (never overwritten if it exists) =="
if [ -f "$RUN/keep_awake.txt" ]; then
  SAY "already there, $(grep -c . "$RUN/keep_awake.txt") app(s) - left alone"
else
  : > "$RUN/keep_awake.txt" && SAY "created empty"
fi

echo "== 5. the app =="
pm install -r "$P/AxionSPSM.apk" 2>&1 | tail -2
SAY "installed version: $(dumpsys package dev.axion.spsm 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1)"

echo "== 6. does the running engine answer? =="
echo -n "  keep list: "; sh "$RUN/scripts/engine.sh" keep list 2>&1 | head -3
echo -n "  version:   "; sh "$RUN/scripts/engine.sh" version 2>&1 | head -2
grep -c "release_force_stopped" "$RUN/scripts/engine.sh" | sed 's/^/  release_force_stopped references: /'
grep -c "KEEP_AWAKE" "$RUN/scripts/knobs.sh" | sed 's/^/  KEEP_AWAKE references in knobs.sh: /'

echo "== 7. the app carries the new screen? =="
dumpsys package dev.axion.spsm 2>/dev/null | grep -c "KeepAwakeActivity" | sed 's/^/  KeepAwakeActivity entries: /'

echo "== 8. state =="
SAY "spsm active: $( [ -f "$RUN/state/active" ] && echo yes || echo no )"
SAY "scripts in place: $(cat "$RUN/state/script_version" 2>/dev/null)"
if [ -f "$RUN/state/active" ]; then
  SAY "the mode is ON: the new code takes effect at the next screen-off or exit."
  SAY "to use it now:  sh $RUN/scripts/engine.sh deactivate && sh $RUN/scripts/engine.sh activate"
fi
[ "$FAIL" = 0 ] && echo "DEPLOY OK" || echo "DEPLOY HAD FAILURES"
