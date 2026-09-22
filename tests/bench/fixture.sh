#!/bin/sh
# The benchmark's fake device is the SUITE's fake device, not a second copy of
# it. A benchmark that builds its own tree drifts away from the tests within a
# release or two and then measures a phone nobody ships, so the fixture
# builders are lifted out of tests/run.sh at run time: one definition, one
# shape, and a change to the tests is a change to what the benchmark measures.
#
# Only the pure builders are taken (make_tree, make_stubs, seed_stub_state,
# screen_on, screen_off, enable_knobs, disable_knobs, run_engine, stop_daemons,
# quiesce_daemon) - nothing that asserts, counts or prints.

_bench_extract() { # _bench_extract <run.sh> <out>
  # Two shapes have to be recognised, because the suite uses both: a block
  # function that closes on a line of its own, and a one-liner (screen_on,
  # screen_off) that opens and closes on the same line. Taking only the first
  # shape silently dropped the two that set the panel, and the benchmark then
  # measured a phone whose screen never changed.
  awk '
    /^(make_tree|make_stubs|seed_stub_state|dump_state|stop_daemons|quiesce_daemon|run_engine|run_shell|run_shell_env|enable_knobs|disable_knobs|screen_on|screen_off)\(\)/ {
      if ($0 ~ /\}[[:space:]]*$/) { print; next }   # one-liner
      take = 1
    }
    take { print }
    take && /^\}$/ { take = 0 }
  ' "$1" > "$2"
}

_BENCH_FIX="${WORK:-${TMPDIR:-/tmp}/spsm-bench}.fixture.sh"
mkdir -p "$(dirname "$_BENCH_FIX")" 2>/dev/null
_bench_extract "$REPO/tests/run.sh" "$_BENCH_FIX"
# shellcheck source=/dev/null
. "$_BENCH_FIX"

# The one thing the suite does at top level rather than in a function.
say()  { printf '\n== %s\n' "$*"; }
ok()   { :; }
bad()  { :; }
check(){ :; }
