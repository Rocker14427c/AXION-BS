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

# Bring a task to the front.
#
# The task id comes from the list above, so it is checked to be digits: nothing
# read from the screen can turn into shell syntax here. Three ways are tried
# because this ROM is Android 16 and the first is the one that exists on most
# builds; the component, when the app passes one, is the last resort.
recents_switch() { # recents_switch <task-id> [component]
  _id=$1
  _comp=$2
  case "$_id" in ''|*[!0-9]*) echo "recents: not a task id: $_id"; return 2 ;; esac
  if has am && am task move-to-front "$_id" >/dev/null 2>&1; then
    log "recents: task $_id to the front"
    return 0
  fi
  if has cmd && cmd activity task move-to-front "$_id" >/dev/null 2>&1; then
    log "recents: task $_id to the front (cmd)"
    return 0
  fi
  # Last resort: start the task's activity in its own task again.
  if [ -n "$_comp" ]; then
    case "$_comp" in
      *[!A-Za-z0-9._/-]*)
        log "recents: refusing a component that is not a component name"
        return 2 ;;
    esac
    if has am && am start --task "$_id" -n "$_comp" >/dev/null 2>&1; then
      log "recents: task $_id restarted by component"
      return 0
    fi
  fi
  echo "recents: could not switch to task $_id"
  return 1
}

# Close a task, the same thing as swiping it away.
recents_remove() {
  _id=$1
  case "$_id" in ''|*[!0-9]*) echo "recents: not a task id: $_id"; return 2 ;; esac
  if has am && am task remove "$_id" >/dev/null 2>&1; then
    log "recents: task $_id removed"
    return 0
  fi
  if has cmd && cmd activity task remove "$_id" >/dev/null 2>&1; then
    log "recents: task $_id removed (cmd)"
    return 0
  fi
  return 1
}

do_recents() { recents_list; }
do_recents_switch() { recents_switch "$1" "$2"; }
do_recents_remove() { recents_remove "$1"; }
