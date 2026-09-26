#!/system/bin/sh
# P1+P2 benchmark - the same daily round the census measured, with the deep
# grace + native cmd paths in place. NO shims: every call runs the way the
# owner's phone will run it. Forks from /proc/stat, CPU seconds from the cpu
# line, walls from date, and the engine's own log carries the per-knob times.
BDIR=/data/local/tmp/bench2
E=/data/adb/spsm/scripts/engine.sh
OUT=$BDIR/out.log
: > "$OUT"

pforks() { awk '/^processes/ { print $2 }' /proc/stat; }
cpubusy() { # hundredths of a second of non-idle CPU, system-wide
  awk '/^cpu / { t=0; for (i=2;i<=NF;i++) t+=$i; print t - $5 - $6 }' /proc/stat
}
stamp() { date '+%H:%M:%S'; }
snap() { # snap label
  echo "$1 forks=$(pforks) busy=$(cpubusy) epoch=$(date +%s) $(stamp)" >> "$OUT"
}

echo "=== BENCH2 $(stamp) ===" >> "$OUT"
F0=$(pforks); B0=$(cpubusy); sleep 10; F1=$(pforks); B1=$(cpubusy)
echo "IDLE baseline: $(( (F1 - F0) / 10 )) forks/s, $(( (B1 - B0) / 100 )) CPU-s per 10s" >> "$OUT"

echo "=== ACTIVATE ===" >> "$OUT"
snap pre_activate
F0=$(pforks); B0=$(cpubusy); T0=$(date +%s)
su -c "sh $E activate" >> "$OUT" 2>&1; rc=$?
T1=$(date +%s); F1=$(pforks); B1=$(cpubusy)
echo "ACTIVATE rc=$rc wall=$((T1 - T0))s forks=$((F1 - F0)) cpu=$(( (B1 - B0) / 100 ))s" >> "$OUT"
snap post_activate
sleep 15

echo "=== 12 SHORT CYCLES (15s off / 10s on - the census shape) ===" >> "$OUT"
F0=$(pforks); B0=$(cpubusy); T0=$(date +%s)
i=0
while [ $i -lt 12 ]; do
  su -c "input keyevent 26" >> "$OUT" 2>&1
  sleep 15
  su -c "input keyevent 26" >> "$OUT" 2>&1
  sleep 10
  i=$((i + 1))
done
T1=$(date +%s); F1=$(pforks); B1=$(cpubusy)
echo "CYCLES wall=$((T1 - T0))s forks=$((F1 - F0)) cpu=$(( (B1 - B0) / 100 ))s" >> "$OUT"
snap post_cycles
sleep 10

echo "=== ONE LONG SCREEN-OFF (180s - the grace must fire at 75s) ===" >> "$OUT"
F0=$(pforks); B0=$(cpubusy); T0=$(date +%s)
su -c "input keyevent 26" >> "$OUT" 2>&1
sleep 180
T1=$(date +%s); F1=$(pforks); B1=$(cpubusy)
echo "LONGOFF wall=$((T1 - T0))s forks=$((F1 - F0)) cpu=$(( (B1 - B0) / 100 ))s" >> "$OUT"
snap post_longoff
su -c "input keyevent 26" >> "$OUT" 2>&1
sleep 8

echo "=== DEACTIVATE ===" >> "$OUT"
F0=$(pforks); B0=$(cpubusy); T0=$(date +%s)
su -c "sh $E deactivate" >> "$OUT" 2>&1; rc=$?
T1=$(date +%s); F1=$(pforks); B1=$(cpubusy)
echo "DEACTIVATE rc=$rc wall=$((T1 - T0))s forks=$((F1 - F0)) cpu=$(( (B1 - B0) / 100 ))s" >> "$OUT"
snap post_deactivate

su -c "sh $E verify" >> "$OUT" 2>&1
echo "=== DONE $(stamp) ===" >> "$OUT"
