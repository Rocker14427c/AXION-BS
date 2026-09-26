#!/system/bin/sh
# v3.9.2 device verification: gestures on foreign slots, the exit race
# reproduced live (deactivate mid-pass), stranding scan, clean cycle timing.
exec > /data/local/tmp/bench4.log 2>&1
cd /data/adb/spsm/scripts || exit 1
L=/data/adb/spsm/spsm.log
G=/data/adb/spsm/gesturemon.log
J=/data/adb/spsm/journal
focus() { dumpsys window 2>/dev/null | grep mCurrentFocus | head -1; }
stamp() { date '+%H:%M:%S'; }

echo "=== BENCH4 start $(date) ==="
sh engine.sh status 2>/dev/null | head -2

echo "=== ACTIVATE (timed) ==="
rm -f "$G"
T0=$(date +%s); sh engine.sh activate; T1=$(date +%s)
echo "activate_wall=$((T1-T0))s"
tail -30 "$L" | grep -E 'SPSM ON|gesturemon|nav:' | tail -4

echo "=== GESTURES ON FOREIGN SLOTS ==="
input keyevent 224; sleep 0.5; wm dismiss-keyguard 2>/dev/null; sleep 1
LINE=$(grep 'watching' "$G" 2>/dev/null | tail -1)
NODE=$(echo "$LINE" | sed -n 's/.*watching \(\/dev\/input\/event[0-9]*\).*/\1/p')
DIM=$(echo "$LINE" | sed -n 's/.*, \([0-9]*\)x\([0-9]*\)).*/\1 \2/p')
W=$(echo $DIM | cut -d' ' -f1); H=$(echo $DIM | cut -d' ' -f2)
echo "node=$NODE W=$W H=$H focus_before: $(focus)"
if [ -n "$NODE" ] && [ -n "$H" ]; then
  X0=$((W/2)); YS=$((H - H/50))
  DYH=$((H*8/100)); YH=$((YS - DYH))
  DYR=$((H*5/100)); YR=$((YS - DYR))
  echo "--- HOME on SLOT 3 (down $X0,$YS -> $X0,$YH)"
  sendevent $NODE 3 47 3
  sendevent $NODE 3 57 777; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYH/4)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYH/2)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYH*3/4)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $YH; sendevent $NODE 0 0 0
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 2
  echo "focus_after_home: $(focus)"
  tail -2 "$G"
  sleep 1
  echo "--- RECENTS hold on SLOT 5"
  sendevent $NODE 3 47 5
  sendevent $NODE 3 57 888; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYR/2)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $YR; sendevent $NODE 0 0 0
  sleep 0.6
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 2.5
  echo "focus_after_recents: $(focus)"
  tail -2 "$G"
  # a second finger on another slot while one is down must be ignored:
  sleep 1
  echo "--- TWO FINGERS: slot 2 down in band, slot 7 noise swipe, slot 2 up (no fire expected from slot 7)"
  sendevent $NODE 3 47 2
  sendevent $NODE 3 57 900; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 47 7
  sendevent $NODE 3 57 901; sendevent $NODE 3 53 100; sendevent $NODE 3 54 $YS
  sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $YH; sendevent $NODE 0 0 0
  sendevent $NODE 3 57 4294967295; sendevent $NODE 0 0 0
  sendevent $NODE 3 47 2
  sendevent $NODE 3 54 $YS; sendevent $NODE 0 0 0
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 1.5
  _fires=$(grep -cE 'home \(|recents \(' "$G")
  echo "total_recognizer_fires=$_fires (expect 2: home + recents; slot-7 noise must not add one)"
  tail -3 "$G"
else
  echo "GESTURE SKIP: no watching line"
fi

echo "=== THE EXIT RACE, LIVE ==="
input keyevent 224 >/dev/null 2>&1; sleep 0.5
_mark=$(wc -l < "$L" 2>/dev/null); _mark=${_mark:-0}
echo "screen_off_at=$(stamp)"
input keyevent 223
_i=0
while [ "$_i" -lt 110 ]; do
  tail -n +"$_mark" "$L" 2>/dev/null | grep -q 'idle 75s' && break
  sleep 1; _i=$((_i + 1))
done
echo "grace_fired_after=${_i}s_at=$(stamp)"
sleep 8   # the pass is mid-flight now (app_restrict takes ~30-58s on this phone)
echo "deactivate_at=$(stamp)"
T2=$(date +%s); sh engine.sh deactivate; T3=$(date +%s)
echo "deactivate_wall=$((T3-T2))s"
tail -n +"$_mark" "$L" | grep -E 'stood down|revert clean|drift|WARN' | tail -6
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
T4=$(date +%s); sh engine.sh activate; T5=$(date +%s)
echo "activate2_wall=$((T5-T4))s"
tail -5 "$L" | grep -E 'SPSM ON|batch|tool' | tail -2
T6=$(date +%s); sh engine.sh deactivate; T7=$(date +%s)
echo "deactivate2_wall=$((T7-T6))s"
tail -25 "$L" | grep -E 'released|revert clean|unstop|batch|tool' | tail -6
echo "final_status: $(sh engine.sh status 2>/dev/null | head -1)"
echo "screen_on_at=$(stamp)"; input keyevent 224 >/dev/null 2>&1
echo "=== BENCH4 done $(date) ==="
