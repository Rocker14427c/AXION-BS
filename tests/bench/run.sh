#!/bin/sh
# SPSM benchmark: what a cycle of this module actually COSTS a phone.
#
#   tests/bench/run.sh              measure this working tree
#   tests/bench/run.sh --save NAME  measure and write tests/bench/NAME.txt
#   tests/bench/run.sh --cmp A B    print A against B and say what moved
#
# Every number is one a phone pays for:
#
#   forks  processes created by this command and its children. Counted from
#          INSIDE the tree (tests/bench/forkcount.c) rather than from
#          /proc/stat, whose counter is the whole machine's: measured on this
#          box the idle background alone makes ~2800 forks a second, which is
#          more than a whole SPSM activation, so a machine-wide number cannot
#          tell you whether a change helped.
#   execs  images loaded on top of those processes. This is the expensive half
#          on a phone - the linker runs and the binary is paged in - and it is
#          where the field logs' "a fifth of a second per settings call" goes.
#   wall   milliseconds of the user's life, which is what "responsive" means.
#
# The device is the test suite's own fake tree (tests/bench/fixture.sh), so a
# benchmark number and a test result describe the same phone.
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPTS="$REPO/module/scripts"
WORK=${SPSM_BENCH_WORK:-${TMPDIR:-/tmp}/spsm-bench}
# Set by the extracted fixture builders; named here so `set -u` does not trip
# over the first reference before make_stubs has run.
BIN=""; ROOT=""
RESULT=""

# ------------------------------------------------------------------ counter
COUNTER_SO="$REPO/tests/bench/forkcount.so"
COUNTER_FILE="$WORK/.forkcount"
build_counter() {
  [ -f "$COUNTER_SO" ] && [ "$COUNTER_SO" -nt "$REPO/tests/bench/forkcount.c" ] && return 0
  cc -shared -fPIC -O2 -o "$COUNTER_SO" "$REPO/tests/bench/forkcount.c" -ldl 2>/dev/null
}
build_counter
[ -f "$COUNTER_SO" ] || printf 'note: no compiler - fork counts will read 0\n' >&2

counter_reset() { mkdir -p "$WORK" 2>/dev/null; rm -f "$COUNTER_FILE"; }
counter_read() { # prints "forks execs"
  [ -f "$COUNTER_FILE" ] || { printf '0 0'; return; }
  od -A n -t u8 -N 16 "$COUNTER_FILE" 2>/dev/null | tr -s ' ' | sed 's/^ //' \
    || printf '0 0'
}

# shellcheck source=/dev/null
. "$REPO/tests/bench/fixture.sh"

# ------------------------------------------------------------------ measuring
bench() { # bench <name> <command...>
  _name=$1; shift
  counter_reset
  _t0=$(date +%s%N)
  SPSM_FORKCOUNT="$COUNTER_FILE" LD_PRELOAD="$COUNTER_SO" "$@" >/dev/null 2>&1
  _t1=$(date +%s%N)
  set -- $(counter_read)
  _forks=${1:-0}; _execs=${2:-0}
  _ms=$(( (_t1 - _t0) / 1000000 ))
  RESULT="$RESULT$_name	$_forks	$_execs	$_ms
"
  printf '  %-34s forks=%-6s execs=%-6s wall=%sms\n' "$_name" "$_forks" "$_execs" "$_ms"
}

bench_window() { # bench_window <name> <seconds> - measure a running daemon
  _name=$1; _secs=$2
  # The daemon is already running under the counter (started by an activate
  # that ran under it), so this just reads the counter across a window.
  set -- $(counter_read); _f0=${1:-0}; _e0=${2:-0}
  sleep "$_secs"
  set -- $(counter_read); _f1=${1:-0}; _e1=${2:-0}
  _forks=$((_f1 - _f0)); _execs=$((_e1 - _e0))
  RESULT="$RESULT$_name	$_forks	$_execs	$((_secs * 1000))
"
  printf '  %-34s forks=%-6s execs=%-6s (%ss window)\n' "$_name" "$_forks" "$_execs" "$_secs"
}

fresh() { # a clean phone with the given knobs on
  make_tree >/dev/null 2>&1
  make_stubs >/dev/null 2>&1
  seed_stub_state >/dev/null 2>&1
  for _k in ${*:-}; do echo "knob.$_k=1" >> "$WORK/spsm/config"; done
  screen_on
}

# ------------------------------------------------------------------ compare
if [ "${1:-}" = "--cmp" ]; then
  A="$REPO/tests/bench/${2:?before}.txt"
  B="$REPO/tests/bench/${3:?after}.txt"
  [ -f "$A" ] || { echo "no such run: $A" >&2; exit 1; }
  [ -f "$B" ] || { echo "no such run: $B" >&2; exit 1; }
  printf '\n%-34s %18s %18s %10s\n' "" "$2" "$3" "change"
  awk -F'\t' -v a="$A" -v b="$B" '
    BEGIN {
      while ((getline line < a) > 0) {
        n = split(line, f, "\t"); if (n < 4) continue
        af[f[1]] = f[2]; ae[f[1]] = f[3]; aw[f[1]] = f[4]; order[++k] = f[1]
      }
      while ((getline line < b) > 0) {
        n = split(line, f, "\t"); if (n < 4) continue
        bf[f[1]] = f[2]; be[f[1]] = f[3]; bw[f[1]] = f[4]
      }
      for (i = 1; i <= k; i++) {
        key = order[i]
        if (!(key in bf)) continue
        pf = (af[key] > 0) ? (bf[key] - af[key]) * 100.0 / af[key] : 0
        pw = (aw[key] > 0) ? (bw[key] - aw[key]) * 100.0 / aw[key] : 0
        printf "%-34s %8s f %7s ms %8s f %7s ms   %+6.0f%% f %+6.0f%% ms\n",
               key, af[key], aw[key], bf[key], bw[key], pf, pw
        taf += af[key]; tbf += bf[key]; taw += aw[key]; tbw += bw[key]
      }
      printf "\n%-34s %8s f %7s ms %8s f %7s ms   %+6.0f%% f %+6.0f%% ms\n",
             "TOTAL", taf, taw, tbf, tbw,
             (taf ? (tbf - taf) * 100.0 / taf : 0),
             (taw ? (tbw - taw) * 100.0 / taw : 0)
    }' /dev/null
  exit 0
fi

# ------------------------------------------------------------------ scenarios

printf '\nSPSM benchmark - %s\n' "$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo working-tree)"
printf 'device: the test suite fake tree, %s\n' "$(uname -m)"
printf 'forks/execs counted inside the measured tree, not from /proc/stat\n\n'

say "turning the mode on and off (the two the user presses)"
fresh
bench activate            run_engine activate
bench "deactivate"        run_engine deactivate
quiesce_daemon

say "the screen, which happens dozens of times a day"
fresh
run_engine activate >/dev/null 2>&1
quiesce_daemon
screen_off
bench "screen-off (deep phase on)"  run_engine screen-off
screen_on
bench "screen-on  (deep phase off)" run_engine screen-on
run_engine deactivate >/dev/null 2>&1
quiesce_daemon

say "the things the app asks for while it is open"
fresh
run_engine activate >/dev/null 2>&1
quiesce_daemon
bench "status (the app polls this)"  run_engine status
bench "status again"                 run_engine status
bench "dump-knobs"                   run_engine dump-knobs
bench "verify"                       run_engine verify
run_engine deactivate >/dev/null 2>&1
quiesce_daemon

say "the daemon idling - the cost of doing NOTHING"
# This is the number that decides battery life: the mode is idle for hours at
# a time, and whatever it spends per second is spent all night.
fresh
counter_reset
SPSM_FORKCOUNT="$COUNTER_FILE" LD_PRELOAD="$COUNTER_SO" \
  run_engine activate >/dev/null 2>&1
bench_window "daemon idle 10s, screen on" 10
screen_off
sleep 2
bench_window "daemon idle 10s, screen off" 10
run_engine deactivate >/dev/null 2>&1
quiesce_daemon

# ------------------------------------------------------------------ output
printf '\n'
printf '%s' "$RESULT" | awk -F'\t' '
  { f += $2; e += $3; w += $4 }
  END { printf "TOTAL forks=%d execs=%d wall=%dms\n", f, e, w }'

case "${1:-}" in
  --save)
    _out="$REPO/tests/bench/${2:?name}.txt"
    printf '%s' "$RESULT" > "$_out"
    printf 'saved -> %s\n' "$_out"
    ;;
esac
