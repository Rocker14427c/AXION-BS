#!/bin/sh
# The daemon's waiting behaviour - the part that decides battery life.
#
# The loop itself is covered by tests/run.sh (it asserts that a screen change is
# acted on, and how fast). What this file measures is the COST of the waiting
# between those changes, because that is what the mode spends its whole life
# doing and because it is where the worst bug in the module was hiding:
#
#   * nap() trusted `read -t` to wait after merely opening the fifo. dash
#     accepts -t, ignores it, and returns at once - so on any ROM whose sh is
#     that shell the daemon became a 100% CPU busy loop for as long as the mode
#     was on. Measured: 5400 ticks in two seconds where one a second is the
#     design. The heartbeat could not see it; only a clock can.
#
#   * with the native monitor present the daemon must wait on EVENTS rather
#     than on a one-second timer, and must still answer a screen change.
#
#   tests/run-daemon.sh

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${TMPDIR:-/tmp}/spsm-daemon-test
SCRIPTS="$REPO/module/scripts"
BIN=""; ROOT=""
PASS=0; FAIL=0

# shellcheck source=/dev/null
. "$REPO/tests/bench/fixture.sh"

# AFTER the fixture, not before: fixture.sh stubs out say/ok/bad/check so the
# benchmark can source the suite's builders without their reporting. Defining
# them first meant every assertion here ran into a no-op and the file reported
# "0 checks" while proving nothing - a green test that tests nothing is worse
# than a red one.
say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

# CPU time (user+sys, in clock ticks) of a process and everything under it.
cpu_ticks() { # cpu_ticks <pid>
  awk '{ print $14 + $15 + $16 + $17 }' "/proc/$1/stat" 2>/dev/null || echo 0
}

start_daemon_bg() { # start_daemon_bg  -> sets DPID
  SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" SPSM_STUB="$WORK/stub" \
  SPSM_BIN="${SPSM_TEST_BIN:-$WORK/spsm/bin}" PATH="$BIN:$PATH" \
    sh "$WORK/spsm/scripts/daemon.sh" >>"$WORK/spsm/spsm.log" 2>&1 &
  DPID=$!
}

stop_daemon_bg() {
  [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  # The monitor is the daemon's child and must go with it; a leak here would
  # show up as a stray process in the next case.
  pkill -f "$WORK/spsm/bin/spsm-screenmon" 2>/dev/null
  DPID=''
}

setup() {
  make_tree >/dev/null 2>&1
  make_stubs >/dev/null 2>&1
  seed_stub_state >/dev/null 2>&1
  mkdir -p "$WORK/spsm/state" "$WORK/spsm/bin"
  echo 1 > "$WORK/spsm/state/active"
  screen_on
}

# =====================================================================
say "the daemon does not burn a core while it waits"
# This is the regression test for the busy loop. The number is CPU time, not
# tick count: a loop that spins reports plenty of ticks and looks healthy.
setup
rm -f "$WORK/spsm/bin/spsm-screenmon"    # the poll path, explicitly
start_daemon_bg
sleep 1
_c0=$(cpu_ticks "$DPID")
sleep 6
_c1=$(cpu_ticks "$DPID")
_used=$((_c1 - _c0))
# 100 ticks is one second of CPU per second of wall time - a spinning loop is
# at or near that. A polling daemon costs a few ticks; an event-driven one
# costs none. Anything under a quarter of a core is comfortably "not spinning".
[ "$_used" -lt 150 ]
check "6 seconds of waiting cost ${_used} CPU ticks, not a whole core" $?
grep -q "daemon: " "$WORK/spsm/spsm.log"
check "and the daemon said which waiting strategy it chose" $?
stop_daemon_bg

# =====================================================================
say "a screen change is still acted on (poll path)"
setup
rm -f "$WORK/spsm/bin/spsm-screenmon"
start_daemon_bg
sleep 2
screen_off
_i=0
while [ "$_i" -lt 40 ] && ! grep -q "screen on -> off" "$WORK/spsm/spsm.log"; do
  sleep 0.25; _i=$((_i + 1))
done
grep -q "screen on -> off" "$WORK/spsm/spsm.log"
check "the screen going dark is noticed by the poll ($((_i * 250))ms)" $?
stop_daemon_bg

# =====================================================================
say "the native monitor, when this machine can build one"
MON="$REPO/build/native/host/spsm-screenmon"
if [ ! -x "$MON" ]; then
  ( cd "$REPO" && ./native/build.sh --host >/dev/null 2>&1 )
fi
if [ -x "$MON" ]; then
  # --- the helper itself, in isolation
  mkdir -p "$WORK/mon"
  echo 900 > "$WORK/mon/brightness"
  # A 2-second tick, because the fixture is a regular file on tmpfs. A real
  # backlight attribute announces itself - the driver calls sysfs_notify() and
  # the kernel broadcasts a uevent - but an ordinary file does neither, so on
  # this fixture the timerfd backstop is the ONLY source that can fire. That is
  # the right thing to test here: the backstop is the guarantee that the module
  # still works on a kernel that announces nothing, and it is the one source
  # that can be exercised off-device. Asking a plain file for an instant event
  # would be asserting something the fixture cannot do.
  "$MON" "$WORK/mon/brightness" 2 > "$WORK/mon/out" 2>/dev/null &
  MPID=$!
  sleep 0.5
  [ "$(head -1 "$WORK/mon/out")" = "state on" ]
  check "it reports the state it starts in, without being asked" $?

  echo 0 > "$WORK/mon/brightness"
  _i=0
  while [ "$_i" -lt 60 ] && ! grep -q "state off" "$WORK/mon/out"; do
    sleep 0.1; _i=$((_i + 1))
  done
  grep -q "state off" "$WORK/mon/out"
  check "a dark panel is reported within the backstop ($((_i * 100))ms, tick 2s)" $?

  # And the state is reported as a CHANGE, once - not repeated every tick. A
  # monitor that re-announced the same state each tick would wake the daemon
  # for nothing, which is the cost this whole component exists to remove.
  sleep 3
  [ "$(grep -c 'state off' "$WORK/mon/out")" = 1 ]
  check "an unchanged state is not re-announced on every tick" $?

  # The point of the whole exercise: no CPU while nothing happens.
  _c0=$(cpu_ticks "$MPID")
  sleep 5
  _c1=$(cpu_ticks "$MPID")
  [ "$((_c1 - _c0))" -lt 5 ]
  check "5 seconds blocked in epoll cost $((_c1 - _c0)) CPU ticks" $?

  # And it must not be large: it lives for as long as the mode is on.
  _rss=$(awk '/VmRSS/{print $2}' "/proc/$MPID/status" 2>/dev/null || echo 99999)
  [ "$_rss" -lt 8192 ]
  check "and it holds ${_rss} kB of memory" $?

  # The APK's instant path: a SIGUSR1 must always produce a line.
  #
  # The app signals the monitor when it hears SCREEN_ON/SCREEN_OFF, and the
  # daemon spends its wait blocked reading this pipe. On bash a USR1 trap does
  # NOT break a blocking read - measured: the read never returned at all - so
  # the line on the pipe is the only thing that can wake the daemon on every
  # shell. A poke that found the panel unchanged must therefore still speak;
  # staying silent would swallow the very poke sent to make it instant.
  _n0=$(wc -l < "$WORK/mon/out")
  kill -USR1 "$MPID" 2>/dev/null
  sleep 1
  [ "$(wc -l < "$WORK/mon/out")" -gt "$_n0" ]
  check "a poke always produces a line, even when the panel has not moved" $?

  kill "$MPID" 2>/dev/null

  # --- the adaptive rule, with a REAL kernel uevent
  # The whole design rests on one claim: that a uevent delivers a panel change
  # faster than any timer, and that the timer may therefore be relaxed once the
  # kernel has shown it announces. That is only worth believing if it has been
  # seen to happen, so this broadcasts an actual netlink uevent and checks both
  # halves - the instant delivery, and the relaxation that follows it.
  #
  # Broadcasting needs CAP_NET_ADMIN, which `unshare -r -n` provides without
  # root. Where that is unavailable the check is skipped rather than faked.
  if cc -o "$WORK/uevent-send" "$REPO/tests/bench/uevent-send.c" 2>/dev/null &&
     unshare -r -n true 2>/dev/null; then
    echo 900 > "$WORK/mon/brightness"
    # Both intervals set to ten minutes: nothing but a real event can deliver
    # anything here, so a result cannot come from a timer by accident.
    unshare -r -n sh -c "
      '$MON' '$WORK/mon/brightness' 600 600 > '$WORK/mon/ev' 2>/dev/null &
      MP=\$!
      sleep 1                       # let the 1s starting timer lapse
      echo 0 > '$WORK/mon/brightness'; '$WORK/uevent-send' >/dev/null
      sleep 1
      echo 900 > '$WORK/mon/brightness'   # change again, announce nothing
      sleep 3
      cp '$WORK/mon/ev' '$WORK/mon/ev.mid'
      '$WORK/uevent-send' >/dev/null
      sleep 1
      kill \$MP 2>/dev/null
    " 2>/dev/null

    grep -q "state off" "$WORK/mon/ev.mid" 2>/dev/null
    check "a kernel uevent delivers a panel change with no timer to help it" $?

    # The second change - made after the event was credited, and deliberately
    # NOT announced - must still be unreported three seconds later. That silence
    # is the timer having been relaxed to its slow value; at the starting one
    # second it would have been found almost immediately.
    #
    # The assertion is on the last line rather than the line count, because the
    # log legitimately contains a "tick" from the one-second starting timer that
    # lapses before the first event arrives. Counting lines made this fail while
    # the behaviour was right, which is a test reporting its own arithmetic.
    [ "$(tail -1 "$WORK/mon/ev.mid" 2>/dev/null)" = "state off" ]
    check "and the backstop relaxes once this kernel has proven it announces" $?

    # The relaxed timer must not have cost anything: the next announcement is
    # still acted on at once.
    [ "$(tail -1 "$WORK/mon/ev" 2>/dev/null)" = "state on" ]
    check "while announcements are still answered immediately" $?
  else
    printf '  (skipped: cannot broadcast a uevent here)\n'
  fi

  # --- and the daemon actually using it
  setup
  cp -f "$MON" "$WORK/spsm/bin/spsm-screenmon"
  chmod 755 "$WORK/spsm/bin/spsm-screenmon"
  start_daemon_bg
  sleep 2
  grep -q "screen events from spsm-screenmon" "$WORK/spsm/spsm.log"
  check "the daemon picks the event path up when the helper is there" $?

  # The app needs the monitor's pid to poke it; without this file the instant
  # path silently degrades to whatever the backstop happens to be.
  _mp=$(cat "$WORK/spsm/state/monitor.pid" 2>/dev/null)
  [ -n "$_mp" ] && [ -d "/proc/$_mp" ]
  check "and publishes the monitor's pid for the app to poke" $?

  screen_off
  _i=0
  while [ "$_i" -lt 40 ] && ! grep -q "screen on -> off" "$WORK/spsm/spsm.log"; do
    sleep 0.25; _i=$((_i + 1))
  done
  grep -q "screen on -> off" "$WORK/spsm/spsm.log"
  check "and a screen change still lands ($((_i * 250))ms)" $?

  _c0=$(cpu_ticks "$DPID")
  sleep 6
  _c1=$(cpu_ticks "$DPID")
  [ "$((_c1 - _c0))" -lt 150 ]
  check "with the event path, 6 idle seconds cost $((_c1 - _c0)) CPU ticks" $?

  # The helper belongs to the daemon and must not outlive it.
  stop_daemon_bg
  sleep 1
  ! pgrep -f "$WORK/spsm/bin/spsm-screenmon" >/dev/null 2>&1
  check "the monitor is ended with the daemon, not left behind" $?
else
  printf '  (skipped: no host compiler for the native helper)\n'
fi

# =====================================================================
say "the module works with no native helper at all"
# The helper is an optimisation and nothing may depend on it. A daemon with an
# empty bin directory must behave exactly as it always did.
setup
rm -rf "$WORK/spsm/bin"
start_daemon_bg
sleep 2
grep -q "no event monitor - polling the panel" "$WORK/spsm/spsm.log"
check "it says so and polls" $?
screen_off
_i=0
while [ "$_i" -lt 40 ] && ! grep -q "screen on -> off" "$WORK/spsm/spsm.log"; do
  sleep 0.25; _i=$((_i + 1))
done
grep -q "screen on -> off" "$WORK/spsm/spsm.log"
check "and the screen is still tracked without it" $?
stop_daemon_bg

printf '\n  %d checks, %d failed\n\n' "$((PASS + FAIL))" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
