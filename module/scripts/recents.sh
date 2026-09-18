#!/system/bin/sh
# SPSM's own recents list.
#
# The phone's recents are provided by the launcher (com.android.launcher3,
# Quickstep), so every swipe up wakes the whole launcher process - its own
# RecentsActivity is one of the tasks you can see in the dump. In a mode whose
# purpose is running off a nearly empty battery that is an expensive way to
# switch apps, so SPSM reads the task list itself and switches tasks directly,
# without starting the launcher at all.
#
#   engine.sh recents                    -> one line per task, tab separated
#   engine.sh recents-switch <id> [comp] -> bring a task to the front
#   engine.sh recents-remove <id>        -> close a task
#
# The reading is `dumpsys activity recents`, whose shape was taken from the phone
# rather than from documentation - one task per "* Recent #N: Task{...}" block:
#
#   * Recent #0: Task{4a57d49 #1455 type=standard A=10252:com.termux}
#     intent={... cmp=com.termux/.app.TermuxActivity}
#     mActivityComponent=com.termux/.app.TermuxActivity
#     lastActiveTime=725551 (inactive for 6s)
#
# Everything here is read-only until a task is explicitly switched or closed.

RECENTS_MAX=${RECENTS_MAX:-12}

# The task list, newest first, as: id <TAB> package <TAB> component <TAB> last-active-uptime-ms
recents_list() {
  has dumpsys || return 0
  dumpsys activity recents 2>/dev/null | awk -v max="$RECENTS_MAX" '
    function flush() {
      # The recents screen itself and the home screen are not places to switch to:
      # one is what we are replacing, the other is what we are already looking at.
      if (id != "" && pkg != "" && type != "recents" && type != "home" && shown < max) {
        printf "%s\t%s\t%s\t%s\n", id, pkg, comp, active
        shown++
      }
      id = ""; pkg = ""; comp = ""; active = ""; type = ""
    }
    /Recent #[0-9]+: Task\{/ {
      flush()
      if (match($0, /Task\{[^ ]+ #[0-9]+/)) {
        _s = substr($0, RSTART, RLENGTH)
        if (match(_s, /#[0-9]+/)) id = substr(_s, RSTART + 1, RLENGTH - 1)
      }
      if (match($0, /type=[a-z]+/)) type = substr($0, RSTART + 5, RLENGTH - 5)
      if (match($0, /A=[0-9]+:[^ }]+/)) {
        pkg = substr($0, RSTART, RLENGTH); sub(/^A=[0-9]+:/, "", pkg)
        # The interface name (I=...) is a component, and its package is the part
        # before the slash.
      } else if (match($0, /I=[^ }]+/)) {
        _c = substr($0, RSTART + 2, RLENGTH - 2)
        comp = _c
        pkg = _c; sub(/\/.*/, "", pkg)
      }
      next
    }
    id != "" {
      if (match($0, /mActivityComponent=[^ }]+/)) {
        comp = substr($0, RSTART + 19, RLENGTH - 19)
        if (pkg == "") { pkg = comp; sub(/\/.*/, "", pkg) }
      }
      # lastActiveTime is in the same clock as /proc/uptime, so the app can say
      # how long ago it was without another reading.
      if (match($0, /lastActiveTime=[0-9]+/)) active = substr($0, RSTART + 15, RLENGTH - 15)
    }
    END { flush() }
  '
}

# Does this task still exist? Asked of the phone, not assumed from an exit code:
# closing a task is exactly the operation that reported success and did nothing.
task_exists() { # task_exists <task-id>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  has dumpsys || return 1
  dumpsys activity recents 2>/dev/null | grep -Eq "Task\{[^ ]+ #$1( |\})"
}

# Is this task the one the phone would show first?
task_is_front() { # task_is_front <task-id>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  _first=$(recents_list 2>/dev/null | head -1 | cut -f1)
  [ -n "$_first" ] && [ "$_first" = "$1" ]
}

# The recents screen this ROM uses, as pkg/component.
#
# The dump names it: mRecentsComponent=ComponentInfo{com.android.launcher3/
# com.android.quickstep.RecentsActivity}. That is the launcher, which is why a
# swipe up anywhere starts it - and why the owner of this phone asked for it to
# be switched off while the mode is on. Read from the phone, never assumed: a
# ROM with a different recents screen names that one instead.
recents_component() {
  has dumpsys || return 0
  dumpsys activity recents 2>/dev/null | awk '
    /^mRecentsComponent=/ {
      line = $0
      sub(/^mRecentsComponent=ComponentInfo\{/, "", line)
      sub(/\}.*$/, "", line)
      if (line ~ /^[A-Za-z0-9._]+\/[A-Za-z0-9._$]+$/) print line
      exit
    }'
}

# Bring a task to the front.
#
# The task id comes from the list above, so it is checked to be digits: nothing
# read from the screen can turn into shell syntax here. Several ways are tried
# because this ROM is Android 16 and the first is the one that exists on most
# builds; the component, when the app passes one, is the last resort.
#
# Each attempt is VERIFIED against the phone's own task list, because a command
# that reports success and then does nothing is the failure this module has been
# bitten by before (closing a task, in the owner's report). Only a task that is
# actually at the front counts.
recents_switch() { # recents_switch <task-id> [component]
  _id=$1
  _comp=$2
  case "$_id" in ''|*[!0-9]*) echo "recents: not a task id: $_id"; return 2 ;; esac
  if has am && am task move-to-front "$_id" >/dev/null 2>&1 && task_is_front "$_id"; then
    log "recents: task $_id to the front"
    return 0
  fi
  if has cmd && cmd activity task move-to-front "$_id" >/dev/null 2>&1 && task_is_front "$_id"; then
    log "recents: task $_id to the front (cmd)"
    return 0
  fi
  # Start the task's activity in its own task again.
  if [ -n "$_comp" ]; then
    case "$_comp" in
      *[!A-Za-z0-9._/-]*)
        log "recents: refusing a component that is not a component name"
        return 2 ;;
    esac
    if has am && am start --task "$_id" -n "$_comp" >/dev/null 2>&1 && task_is_front "$_id"; then
      log "recents: task $_id restarted by component"
      return 0
    fi
  fi
  log "recents: could not switch to task $_id"
  return 1
}

# Close a task, the same thing as swiping it away.
#
# The owner's report: "when i try to close the recent apps from spsm recents it
# didn't close the app and I tried this many time but it didn't work." The old
# code trusted the exit code of `am task remove`. On Android 16 that command is
# `am task` with the subcommand the platform happens to have, and a version that
# does not have it prints a complaint and exits 0 - so the task stayed, every
# time, and the screen even reloaded it as if nothing had been asked.
#
# So: try every form the platform has used, CHECK the phone's own task list after
# each one, and if the task genuinely will not go, stop the app - which does
# remove its task, and is what the person pressing "close" meant anyway.
recents_remove() { # recents_remove <task-id> [package]
  _id=$1
  _pkg=$2
  case "$_id" in ''|*[!0-9]*) echo "recents: not a task id: $_id"; return 2 ;; esac
  # Already gone: nothing to do, and nothing to claim.
  task_exists "$_id" || return 0
  if has am && am task remove "$_id" >/dev/null 2>&1 && ! task_exists "$_id"; then
    log "recents: task $_id removed"
    return 0
  fi
  if has cmd && cmd activity task remove "$_id" >/dev/null 2>&1 && ! task_exists "$_id"; then
    log "recents: task $_id removed (cmd)"
    return 0
  fi
  # An older name for the same thing, kept because the command table moves around
  # between Android versions.
  if has am && am stack remove "$_id" >/dev/null 2>&1 && ! task_exists "$_id"; then
    log "recents: task $_id removed (stack)"
    return 0
  fi
  if [ -n "$_pkg" ]; then
    case "$_pkg" in
      *[!A-Za-z0-9._]*)
        log "recents: refusing a package that is not a package name" ;;
      *)
        if has am && am force-stop "$_pkg" >/dev/null 2>&1 && ! task_exists "$_id"; then
          log "recents: task $_id closed by stopping $_pkg"
          return 0
        fi ;;
    esac
  fi
  log "recents: could not close task $_id"
  return 1
}

do_recents() {
  # Traced, not just printed. The recents list is opened by a gesture that leaves
  # no other trace: "did the swipe reach us at all?" is unanswerable from a log
  # that only shows the list's contents going past.
  #
  # The trace is written straight to the log file and never through log(): that
  # also writes the kernel ring buffer, and a kernel write this sandbox refuses
  # prints on stderr - which would land in the middle of the task list this
  # command exists to print. The app parses this output line by line.
  _out=$(recents_list)
  _n=$(printf '%s\n' "$_out" | grep -c . 2>/dev/null)
  printf '%s recents: listed %s task(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${_n:-0}" >> "$LOG" 2>/dev/null
  [ -n "$_out" ] && printf '%s\n' "$_out"
}
do_recents_switch() { recents_switch "$1" "$2"; }
do_recents_remove() { recents_remove "$1" "$2"; }

# ---------------------------------------------------------------- clear all
# The owner's request: "add a clear all button in recents which force stop all
# the processes which is running in the background at once."
#
# What it does, in the order that makes it true:
#   1. every task the list is showing is closed through recents_remove, which
#      reads the phone's own task list back rather than trusting an exit code;
#   2. the frozen background is stopped and its memory released (sweep_background);
#   3. the phone's own task list is read once more, and THAT number is what is
#      reported - a task that would not close is said so, not rounded away.
do_clear_all() {
  # Every name here is a counter that no callee uses. A shell has no local
  # variables, and sweep_background counts the apps it stops in _n: with this
  # function's own count in _n as well, a two-task list was reported as three
  # ("asked=3") on the first run of this command - the sweep's number, read as if
  # it were the task count.
  _asked=0
  _before=$(mem_available)
  _d=$SPSM_DIR/.tmp
  mkdir -p "$_d" 2>/dev/null
  _t="$_d/clearall.$$"
  recents_list > "$_t" 2>/dev/null
  while IFS="$TAB" read -r _id _pkg _comp _active; do
    [ -n "$_id" ] || continue
    _asked=$((_asked + 1))
    recents_remove "$_id" "$_pkg" >/dev/null 2>&1
  done < "$_t"
  rm -f "$_t"
  sweep_background "clear all"
  _left=$(recents_list 2>/dev/null | grep -c . 2>/dev/null)
  case "$_left" in ''|*[!0-9]*) _left=0 ;; esac
  _after=$(mem_available)
  _gone=$((_asked - _left))
  [ "$_gone" -lt 0 ] && _gone=0
  log "clear all: $_asked task(s) asked to close, $_gone gone, $_left still listed, free memory $(mem_words "$_before") -> $(mem_words "$_after")"
  printf 'asked=%s gone=%s left=%s\n' "$_asked" "$_gone" "$_left"
}

# ------------------------------------------- the phone's own Recents button
#
# The owner's instruction: "Make shure that recent button of system 3-button
# navigation bar is sync with spsm recents such that i can easily switch to spsm's
# recent whenever I want like if I am using an app and I want to see recent."
#
# The v3.6.1 log says why it did nothing, and it is a lesson about what the
# button actually is:
#
#   recents-guard: a line about recents it did not act on:
#     I/input_focus( 1910): [Focus entering recents_animation_input_consumer, reason=setFocusedWindow]
#
# That is the only trace the press left. On this ROM the Recents button does not
# start the launcher's RecentsActivity at all - Quickstep handles it as a
# *recents animation*, with a window of its own, and the v3.6.1 guard was written
# to match a RecentsActivity that never appeared. There was nothing wrong with the
# handover; it was never asked to happen.
#
# So the press is now caught two ways, and the list is put up with a read-back:
#
#   1. the phone's event log, for anything that says its recents screen is
#      opening - the animation's own input consumer, the component the phone
#      names, or the activity;
#   2. the touchscreen itself. The Recents button is a place on a screen, and
#      /dev/input says when it is pressed, whoever else is listening. That path
#      does not depend on what the ROM chooses to log.
#
# Both go through recents_take_over(), which starts this mode's list, reads what
# is actually on screen, and - if the phone put its own recents screen up
# instead - takes that screen down and asks again.

# Is this mode's own list the activity on screen? Read back from the phone, the
# same way everything else in this module decides what happened.
recents_is_front() {
  has dumpsys || return 1
  dumpsys activity activities 2>/dev/null \
    | grep -m1 -E 'topResumedActivity|ResumedActivity|mResumedActivity' \
    | grep -q 'dev.axion.spsm/.SpsmRecentsActivity'
}

# Put this mode's list up, and make sure it is up.
#
#   recents_take_over <what asked for it>
recents_take_over() {
  _why=${1:-unknown}
  [ -f "$ACTIVE" ] || return 1
  # One press, one list: the log line and the touch arrive a moment apart, and
  # the event log carries the activity being created and then resumed. Two
  # seconds is longer than that gap and shorter than anyone pressing twice.
  _stamp="$STATE/recents_take.stamp"
  _now=$(date +%s)
  if [ -f "$_stamp" ] && [ "$((_now - $(cat "$_stamp" 2>/dev/null || echo 0)))" -lt 2 ]; then
    return 0
  fi
  printf '%s' "$_now" > "$_stamp" 2>/dev/null
  has am || return 1
  # Already up: nothing to do.
  recents_is_front && return 0
  _pkg=$(home_package 2>/dev/null)
  case "$_pkg" in ''|dev.axion.spsm) _pkg=com.android.launcher3 ;; esac

  # Starting an activity is a request, not a guarantee: the phone can start the
  # launcher's recents screen over ours, and an `am start` that was accepted and
  # then covered up leaves the button looking broken. So the screen is read back,
  # the screen the button did open is taken down, and the list is asked for again
  # - three tries, a couple of seconds at worst.
  _i=0
  _out=''
  while [ "$_i" -lt 3 ]; do
    _i=$((_i + 1))
    _out=$(am start -n dev.axion.spsm/.SpsmRecentsActivity 2>&1)
    _w=0
    while [ "$_w" -lt 6 ]; do
      recents_is_front && break
      sleep 0.2 2>/dev/null || sleep 1
      _w=$((_w + 1))
    done
    recents_is_front && break
    am force-stop "$_pkg" >/dev/null 2>&1
  done
  if recents_is_front; then
    log "recents: the list was put up for $_why (${_i} attempt(s))"
    # The screen the button actually opened, taken down: without this, closing
    # our list would show the phone's recents still standing behind it.
    am force-stop "$_pkg" >/dev/null 2>&1
    return 0
  fi
  log "recents: could not put SPSM's list up for $_why${_out:+ - am start said: $(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-150)}"
  return 1
}

# One line of the phone's own log, offered to the guard.
recents_guard() { # recents_guard <one line>
  _line=$1
  [ -n "$_line" ] || return 1
  [ -f "$ACTIVE" ] || return 1
  # Never our own screen: this list is in the same log.
  case "$_line" in *dev.axion.spsm*) return 1 ;; esac
  # Which screen the phone's Recents button opens. The name is read from the
  # phone (`dumpsys activity recents` names mRecentsComponent); the daemon reads
  # it once and hands it over, and this falls back to asking.
  _host=${RECENTS_HOST:-}
  [ -n "$_host" ] || _host=$(host_recents_component 2>/dev/null)
  _cls=${_host#*/}
  _match=0
  # The animation this ROM actually uses, in the words of its own log line.
  case "$_line" in *recents_animation_input_consumer*) _match=1 ;; esac
  if [ "$_match" = 0 ]; then
    case "$_host" in
      */*)
        case "$_line" in *"$_host"*) _match=1 ;; esac
        if [ "$_match" = 0 ]; then
          case "$_cls" in
            ''|recents) ;;
            *) case "$_line" in *"$_cls"*) _match=1 ;; esac ;;
          esac
        fi
        # The short form, and the one this ROM's log carries.
        [ "$_match" = 0 ] && case "$_line" in *RecentsActivity*) _match=1 ;; esac ;;
      *) case "$_line" in *RecentsActivity*) _match=1 ;; esac ;;
    esac
  fi
  if [ "$_match" = 0 ]; then
    # A line about this phone's recents that was not the screen itself. Written
    # down once per burst: if the button ever opens the phone's recents screen
    # and this mode's list does not follow, the log says whether the line even
    # arrived and what it said.
    case "$_line" in
      *ecents*|*ECENTS*)
        _seen="$STATE/recents_seen.stamp"
        _now=$(date +%s)
        [ -f "$_seen" ] && [ "$((_now - $(cat "$_seen" 2>/dev/null || echo 0)))" -lt 5 ] && return 1
        printf '%s' "$_now" > "$_seen" 2>/dev/null
        log "recents-guard: a line about recents it did not act on: $(printf '%s' "$_line" | tr '\t' ' ' | cut -c1-150)" ;;
    esac
    return 1
  fi
  recents_take_over "the phone's own Recents button"
}

# Where the phone's Recents button is, in the touchscreen's own coordinates.
#
# Print "x1 y1 x2 y2", or nothing when the phone will not say enough to be sure.
# The navigation bar is read from the phone's own insets - not guessed from a
# dp value - and the button in it is the right-hand end of the bar, which is
# where Android puts it in three-button navigation. The right quarter of the bar
# is taken rather than the exact button: the rest of the bar is dead space that
# does nothing when it is tapped, so a tap there costs nothing to answer, and
# being slightly generous is what makes this work on a bar laid out a little
# differently from this one.
recents_button_region() {
  _sz=$(wm size 2>/dev/null | tail -1 | sed -n 's/.*: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p')
  [ -n "$_sz" ] || return 1
  # shellcheck disable=SC2086
  set -- $_sz
  _w=$1
  _h=$2
  _top=$(dumpsys window 2>/dev/null \
         | grep -m1 'ITYPE_NAVIGATION_BAR' \
         | grep -o '\[[0-9-]*,[0-9-]*\]\[[0-9-]*,[0-9-]*\]' | head -1 \
         | tr '[],' '   ')
  # shellcheck disable=SC2086
  set -- $_top
  case "${1:-}" in
    ''|*[!0-9]*) _top='' ;;
    *) [ "${4:-0}" -eq "$_h" ] && [ "$2" -gt $((_h / 2)) ] && _top=$2 || _top='' ;;
  esac
  if [ -z "$_top" ]; then
    # No insets to read: fall back to the bar's standard height, 48dp, in this
    # phone's own density.
    _d=$(wm density 2>/dev/null | tail -1 | sed -n 's/.*[Dd]ensity: *\([0-9][0-9]*\).*/\1/p')
    case "$_d" in ''|*[!0-9]*) _d=280 ;; esac
    _top=$(( _h - _d * 48 / 160 ))
  fi
  [ "$_top" -gt 0 ] 2>/dev/null || return 1
  # The touchscreen does not have to count in the screen's own pixels. Plenty of
  # drivers report their own raw range instead - 0..4095 on either axis is a
  # common one - and a region named in pixels would then point at a place the
  # finger never reaches, which looks exactly like the bug this is here to fix.
  # The device declares its ranges itself, in `getevent -p`, so the same place on
  # the screen is expressed in whatever units the touchscreen actually uses.
  _axes=$(getevent -p 2>/dev/null)
  _rx=$(printf '%s\n' "$_axes" | sed -n 's/.*ABS_MT_POSITION_X.*max \([0-9][0-9]*\).*/\1/p' | head -1)
  _ry=$(printf '%s\n' "$_axes" | sed -n 's/.*ABS_MT_POSITION_Y.*max \([0-9][0-9]*\).*/\1/p' | head -1)
  case "${_rx:-}" in ''|*[!0-9]*) _rx='' ;; esac
  case "${_ry:-}" in ''|*[!0-9]*) _ry='' ;; esac
  if [ -n "$_rx" ] && [ -n "$_ry" ] && [ "$_rx" -gt 0 ] && [ "$_ry" -gt 0 ] &&
     { [ "$_rx" != "$_w" ] || [ "$_ry" != "$_h" ]; }; then
    _y1=$(( _ry * _top / _h ))
    [ "$_y1" -lt "$_ry" ] || _y1=$(( _ry - 1 ))
    printf '%s %s %s %s\n' "$(( _rx - _rx / 4 ))" "$_y1" "$_rx" "$_ry"
    return 0
  fi
  printf '%s %s %s %s\n' "$(( _w - _w / 4 ))" "$_top" "$_w" "$_h"
}

# The touchscreen, watched in the daemon.
#
# The Recents button is a place on a screen. What the ROM does with a tap there
# is its own business; this watches the tap itself, so the button works whatever
# the ROM logs - and it is why v3.6.1's silence is not repeated: the tap is seen
# even on a phone whose log says nothing at all.
#
# The events are parsed by one awk, and the awk prints a line only when it has
# seen a tap inside the button's own region: a press and a release with the
# finger almost still, short enough to be a tap and not a drag.
recents_watch_touch() {
  if ! has getevent; then
    # Said out loud: "the button does nothing" has at least three causes now, and
    # this is the one that would otherwise leave no trace at all in the log.
    log "recents: this phone has no getevent, so the Recents button itself cannot be watched"
    return 0
  fi
  # No Recents button to watch on a phone that is not drawing three buttons -
  # whoever asks. The daemon checks this before it starts the watcher; this is
  # the same answer for anything else that might call it.
  [ "$(nav_now)" = three ] || return 0
  _reg=$(recents_button_region 2>/dev/null)
  case "$_reg" in
    ''|*[!0-9\ ]*) log "recents: this phone would not say where its navigation bar is, so the buttons themselves are not watched"; return 0 ;;
  esac
  log "recents: watching the phone's Recents button itself (x1 y1 x2 y2 = $_reg)"
  # shellcheck disable=SC2086
  set -- $_reg
  getevent -lt 2>/dev/null | awk -v x1="$1" -v y1="$2" -v x2="$3" -v y2="$4" '
    function h2d(s,  i, c, d, n) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) d = 0
        n = n * 16 + d
      }
      return n
    }
    function release(  d) {
      if (!started) return
      d = ts - st
      if (!moved && d < 0.8 && sx >= x1 && sx <= x2 && sy >= y1 && sy <= y2) {
        printf "%d %d %.2f\n", sx, sy, d
      }
      started = 0; moved = 0
    }
    {
      if ($1 == "[" && $2 != "") {
        t = substr($2, 1, length($2) - 1) + 0
        if (t > 0) ts = t
      }
    }
    /ABS_MT_POSITION_X/ { x = h2d($NF) }
    /ABS_MT_POSITION_Y/ { y = h2d($NF) }
    /EV_ABS .*TRACKING_ID/ { if ($NF == "ffffffff") release() }
    /BTN_TOUCH/ {
      if ($NF == "DOWN" || $NF == "00000001") down = 1
      else { down = 0; release() }
    }
    /SYN_REPORT/ {
      if (down) {
        if (!started) { started = 1; sx = x; sy = y; st = ts; moved = 0 }
        else if ((x - sx > 40 || sx - x > 40) || (y - sy > 40 || sy - y > 40)) moved = 1
      }
    }
  ' | while read -r _hit; do
    [ -f "$ACTIVE" ] || break
    recents_take_over "a tap on the phone's Recents button (${_hit})"
  done
}

