#!/system/bin/sh
# v3.10.1 device verification round.
#   1. identity + the rebuilt natives/jar prove themselves on the phone
#   2. gestures on foreign slots WITH THE FIXED DISPATCH (input/am wrappers):
#      recognition alone is not enough any more - the focus must actually move
#   3. the exit race, live: deactivate mid-pass, bounded stand-down, no
#      stranding, and - the fix under test - no false "want [1] got [1]" drift
#   4. clean cycle scorecard
exec > /data/local/tmp/bench5.log 2>&1
cd /data/adb/spsm/scripts || exit 1
L=/data/adb/spsm/spsm.log
G=/data/adb/spsm/gesturemon.log
J=/data/adb/spsm/journal
focus() { dumpsys window 2>/dev/null | grep mCurrentFocus | head -1; }
stamp() { date '+%H:%M:%S'; }

echo "=== BENCH5 start $(date) ==="
echo "script_version=$(cat /data/adb/spsm/state/script_version /data/adb/spsm/script_version 2>/dev/null | head -1)"
grep -E '^version' /data/adb/modules/axion_spsm/module.prop 2>/dev/null
sh engine.sh status 2>/dev/null | head -2
# the rebuilt jar, through the same eyes the phone uses at publish time:
su 2000 -c "CLASSPATH=/data/local/tmp/spsm/spsm-tool.jar app_process / dev.axion.spsm.tool.Main" 2>&1 | head -1
echo "tool_proof_rc=$?  (expect the usage line; rc=2 is checked by publish_native)"

echo "=== ACTIVATE (timed) ==="
rm -f "$G"
_mark0=$(wc -l < "$L" 2>/dev/null); _mark0=${_mark0:-0}
T0=$(date +%s); sh engine.sh activate; T1=$(date +%s)
echo "activate_wall=$((T1-T0))s"
tail -n +$_mark0 "$L" | grep -E 'SPSM ON|batch tool|native helpers|gesturemon|nav:' | tail -6

echo "=== GESTURES: recognition is not enough - dispatch must move the focus ==="
input keyevent 224; sleep 0.5; wm dismiss-keyguard 2>/dev/null; sleep 1
LINE=$(grep 'watching' "$G" 2>/dev/null | tail -1)
NODE=$(echo "$LINE" | sed -n 's/.*watching \(\/dev\/input\/event[0-9]*\).*/\1/p')
DIM=$(echo "$LINE" | sed -n 's/.*, \([0-9]*\)x\([0-9]*\)).*/\1 \2/p')
W=$(echo $DIM | cut -d' ' -f1); H=$(echo $DIM | cut -d' ' -f2)
echo "node=$NODE W=$W H=$H focus_before: $(focus)"
if [ -n "$NODE" ] && [ -n "$H" ]; then
  X0=$((W/2)); YS=$((H - H/50))
  DYH=$((H*8/100)); YH=$((YS - DYH))
  echo "--- HOME on SLOT 3: fast swipe up $DYH px"
  sendevent $NODE 3 47 3
  sendevent $NODE 3 57 777; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYH/4)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYH/2)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYH*3/4)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $YH; sendevent $NODE 0 0 0
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 2.5
  echo "focus_after_home: $(focus)"
  tail -2 "$G"
  sleep 1
  # The corrected recents injection: bench4 moved 79px in two fast frames -
  # past the 40px hold tolerance - and the recognizer correctly called it a
  # home swipe. A hold means: small movement (2x15px), then TIME (500ms >
  # 350ms), then lift.
  echo "--- RECENTS hold on SLOT 5: 30px over 500ms"
  sendevent $NODE 3 47 5
  sendevent $NODE 3 57 888; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - 15)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - 30)); sendevent $NODE 0 0 0
  sleep 0.5
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 3
  echo "focus_after_recents: $(focus)   (expect dev.axion.spsm/.SpsmRecentsActivity)"
  tail -2 "$G"
  # back home for the noise test
  input keyevent 3; sleep 1
  echo "--- TWO FINGERS: slot 2 owns (down in band, tiny move, up), slot 7 noise swipe"
  sendevent $NODE 3 47 2
  sendevent $NODE 3 57 900; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 47 7
  sendevent $NODE 3 57 901; sendevent $NODE 3 53 100; sendevent $NODE 3 54 $YS
  sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $YH; sendevent $NODE 0 0 0
  sendevent $NODE 3 57 4294967295; sendevent $NODE 0 0 0
  sendevent $NODE 3 47 2
  sendevent $NODE 3 54 $((YS - 10)); sendevent $NODE 0 0 0
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 1.5
  echo "total_recognizer_fires=$(grep -cE 'home \(|recents \(' "$G") (expect exactly 2: home + recents; slot-7 noise and the parked slot-2 finger must not fire)"
  echo "dispatch_failures=$(grep -c 'Failure calling service' "$G") (expect 0 - this is the bug that made recognised swipes do nothing)"
  tail -4 "$G"
else
  echo "GESTURE SKIP: no watching line"
fi

echo "=== THE EXIT RACE, LIVE (and the false-drift fix under it) ==="
input keyevent 224 >/dev/null 2>&1; sleep 0.5
_mark=$(wc -l < "$L" 2>/dev/null); _mark=${_mark:-0}
echo "screen_off_at=$(stamp)"
input keyevent 223
_i=0
while [ "$_i" -lt 110 ]; do
  tail -n +$_mark "$L" 2>/dev/null | grep -q 'idle 75s' && break
  sleep 1; _i=$((_i + 1))
done
echo "grace_fired_after=${_i}s_at=$(stamp)"
sleep 8   # the pass is mid-flight now (app_restrict takes 30-58s on this phone)
echo "deactivate_at=$(stamp)"
T2=$(date +%s); sh engine.sh deactivate; T3=$(date +%s)
echo "deactivate_wall=$((T3-T2))s"
tail -n +$_mark "$L" | grep -E 'stood down|defence|revert|drift|WARN|safety_force' | tail -10
echo "--- stranding scan (sample of the managed set):"
for p in com.whatsapp com.google.android.gm.lite com.vivi.vivimusic dev.anilbeesetti.nextplayer.release com.instagram.lite com.openai.chatgpt com.android.edge.bar org.lineageos.settings.doze; do
  echo "$p bucket=$(su 2000 -c "cmd activity get-standby-bucket $p" 2>&1) op=$(su 2000 -c "cmd appops get $p RUN_ANY_IN_BACKGROUND" 2>&1 | head -1)"
done
echo "journal_states_left=$(grep -l -E '^(applied|applying|restored-drift)$' "$J"/*.state 2>/dev/null | wc -l)"
echo "tsv_left=$(ls "$J"/orig/*.tsv 2>/dev/null | wc -l)"
echo "pidfile_left=$([ -f /data/adb/spsm/state/deep_restrict.pid ] && echo yes || echo no)"

echo "=== CLEAN CYCLE (scorecard) ==="
sleep 2
input keyevent 224 >/dev/null 2>&1; sleep 0.5
_mark2=$(wc -l < "$L" 2>/dev/null); _mark2=${_mark2:-0}
T4=$(date +%s); sh engine.sh activate; T5=$(date +%s)
echo "activate2_wall=$((T5-T4))s"
tail -n +$_mark2 "$L" | grep -E 'SPSM ON|batch|tool' | tail -2
T6=$(date +%s); sh engine.sh deactivate; T7=$(date +%s)
echo "deactivate2_wall=$((T7-T6))s"
tail -n +$_mark2 "$L" | grep -E 'released|revert|unstop|batch|tool|WARN|drift' | tail -8
echo "final_status: $(sh engine.sh status 2>/dev/null | head -1)"
echo "screen_on_at=$(stamp)"; input keyevent 224 >/dev/null 2>&1
echo "=== BENCH5 done $(date) ==="
