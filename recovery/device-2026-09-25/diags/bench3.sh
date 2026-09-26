#!/system/bin/sh
# v3.9.1 device benchmark: activate, gesturemon injection, grace, deactivate.
exec > /data/local/tmp/bench3.log 2>&1
cd /data/adb/spsm/scripts || exit 1
L=/data/adb/spsm/spsm.log
G=/data/adb/spsm/gesturemon.log
focus() { dumpsys window 2>/dev/null | grep mCurrentFocus | head -1; }
procs() { awk '/^processes/{print $2}' /proc/stat; }
stamp() { date '+%H:%M:%S'; }

echo "=== BENCH3 start $(date) ==="
echo "--- PRE"
sh engine.sh status 2>/dev/null | head -3
echo "config: $(cat /data/adb/spsm/config 2>/dev/null | tr '\n' ' ')"
echo "navigation_mode=$(settings get secure navigation_mode)"
echo "screenon: $(dumpsys deviceidle 2>/dev/null | grep -o 'mScreenOn=[a-z]*' | head -1)"
echo "focus_pre: $(focus)"
echo "processes_pre=$(procs)"
ls /data/adb/spsm/state/ 2>/dev/null | tr '\n' ' '; echo

echo "=== ACTIVATE (timed) ==="
P0=$(procs); T0=$(date +%s)
sh engine.sh activate
T1=$(date +%s); P1=$(procs)
echo "activate_wall=$((T1-T0))s forks_delta=$((P1-P0))"
echo "journal_lines=$(wc -l < /data/adb/spsm/state/journal.tsv 2>/dev/null)"
tail -60 "$L" | grep -E 'nav:|gesturemon|block_other|deep|tool|batch|applied' | tail -14
echo "gesturemon_pid=$(cat /data/adb/spsm/state/gesturemon.pid 2>/dev/null) alive=$(pidof spsm-gesturemon)"
echo "screenmon_pid=$(cat /data/adb/spsm/state/screenmon.pid 2>/dev/null) alive=$(pidof spsm-screenmon)"
echo "focus_after_activate: $(focus)"

echo "=== GESTURE INJECTION ==="
tail -3 "$G" 2>/dev/null
LINE=$(grep 'watching' "$G" 2>/dev/null | tail -1)
NODE=$(echo "$LINE" | sed -n 's/.*watching \(\/dev\/input\/event[0-9]*\).*/\1/p')
DIM=$(echo "$LINE" | sed -n 's/.*, \([0-9]*\)x\([0-9]*\)).*/\1 \2/p')
W=$(echo $DIM | cut -d' ' -f1); H=$(echo $DIM | cut -d' ' -f2)
echo "node=$NODE W=$W H=$H"
if [ -n "$NODE" ] && [ -n "$H" ]; then
  X0=$((W/2)); YS=$((H - H/50))                 # start 2% above the very bottom, inside the 6% band
  DYH=$((H*8/100)); YH=$((YS - DYH))            # home: 8% of screen up
  DYR=$((H*5/100)); YR=$((YS - DYR))            # hold: 5% of screen up (>= 40 raw px)
  input keyevent 224; sleep 0.5; wm dismiss-keyguard 2>/dev/null; sleep 1
  echo "focus_before_swipes: $(focus)"
  echo "--- HOME swipe (down $X0,$YS -> up $X0,$YH)"
  sendevent $NODE 3 57 100; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
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
  echo "--- RECENTS hold (down, up 5%, still 600ms)"
  sendevent $NODE 3 57 101; sendevent $NODE 3 53 $X0; sendevent $NODE 3 54 $YS
  sendevent $NODE 1 330 1; sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $((YS - DYR/2)); sendevent $NODE 0 0 0
  sendevent $NODE 3 54 $YR; sendevent $NODE 0 0 0
  sleep 0.6
  sendevent $NODE 3 57 4294967295; sendevent $NODE 1 330 0; sendevent $NODE 0 0 0
  sleep 2
  echo "focus_after_recents: $(focus)"
  tail -2 "$G"
else
  echo "GESTURE SKIP: gesturemon did not log a device"
fi

echo "=== GRACE: screen off, cheap at 30s, deep at 75s ==="
input keyevent 223
echo "screen_off_at=$(stamp)"
sleep 30
echo "--- log at t+30s:"; tail -6 "$L"
sleep 55
echo "--- log at t+85s:"; tail -10 "$L"
echo "screen_on_at=$(stamp)"
input keyevent 224
sleep 1
TW0=$(date +%s)
sleep 25
TW1=$(date +%s)
echo "wake_window=$((TW1-TW0))s log:"; tail -8 "$L"

echo "=== DEACTIVATE (timed) ==="
P2=$(procs); T2=$(date +%s)
sh engine.sh deactivate
T3=$(date +%s); P3=$(procs)
echo "deactivate_wall=$((T3-T2))s forks_delta=$((P3-P2))"
tail -30 "$L" | grep -E 'checked|drift|unstop|release|tool|batch|gesturemon|nav' | tail -12
echo "gesturemon_alive=$(pidof spsm-gesturemon)"
echo "navigation_mode_post=$(settings get secure navigation_mode)"
sleep 2
echo "focus_post: $(focus)"
echo "processes_post=$(procs)"
echo "=== BENCH3 done $(date) ==="
