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
