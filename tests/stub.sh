#!/bin/sh
# Fake Android commands for the SPSM test harness.
#
# This is installed into tests' PATH under the names of the real commands
# (settings, getprop, pm, am, cmd, svc, dumpsys, resetprop, ps, logcat) so the
# REAL engine scripts can be exercised without a phone. Everything is file-backed under
# $SPSM_STUB so the test can assert on it afterwards.
#
# It deliberately mimics the quirks the engine depends on:
#   * `dumpsys deviceidle whitelist` output format
#   * `cmd appops get <pkg> RUN_ANY_IN_BACKGROUND` output format
#   * `am get-standby-bucket` returning a number
#   * `dumpsys package <pkg>` reporting `enabled=`
#   * `ps -A -o NAME` listing process names, one per line

S="$SPSM_STUB"
CMD=${CMD_OVERRIDE:-$(basename "$0")}
mkdir -p "$S/props" "$S/settings" "$S/bucket" "$S/appop" "$S/pkg"

log_call() { echo "$CMD $*" >> "$S/calls"; }

# Suspending a package is not a note the stub keeps to itself: the system owns
# that state and persists it in package-restrictions.xml, which is the file the
# module reads the suspended list from. A fake phone that suspends without
# writing it down would be lying about its own state - and it did: the module
# trusted the file, and the file said the apps it had just suspended were not
# suspended at all.
xml_suspend() { # xml_suspend <pkg> <true|false>
  _x="$S/users/0/package-restrictions.xml"
  [ -f "$_x" ] || return 0
  # The module releases several apps at once on purpose (they run together, the
  # way the phone does it), and the real PackageManager serialises those writes
  # inside the system server. `sed -i` does not: two of them at the same moment
  # on the same file lose one of the two updates, and the module then reads that
  # back as an app it failed to release. So the write is serialised here as well.
  _lock="$S/users/.xml.lock"
  _i=0
  while ! mkdir "$_lock" 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -gt 600 ] && break      # never hang the phone over a test lock
    sleep 0.05 2>/dev/null || sleep 1
  done
  if grep -q "<pkg name=\"$1\"" "$_x"; then
    sed -i "s#\(<pkg name=\"$1\"[^>]*suspended=\"\)[a-z]*#\1$2#" "$_x"
  else
    [ "$2" = true ] || return 0
    sed -i "s#^</package-restrictions>#<pkg name=\"$1\" ceDataInode=\"900\" enabled=\"1\" installed=\"1\" stopped=\"0\" hidden=\"false\" suspended=\"true\" />\n</package-restrictions>#" "$_x"
  fi
  rmdir "$_lock" 2>/dev/null
}

# ----------------------------------------------------------------- settings
sget() { cat "$S/settings/$1.$2" 2>/dev/null; }

# ------------------------------------------------------------------- tasks
# The recent-task list is edited in place rather than modelled separately: the
# fixture is the phone's real dump, and it must stay in that shape so the parser
# keeps being tested against the format it has to read. Removing a task drops its
# block; bringing one to the front moves its block above the others and renumbers
# the "Recent #N" counters, exactly as the phone's list would then print.
recents_rewrite() { # recents_rewrite <drop|front> [id]
  [ -f "$S/recents.dump" ] || return 0
  _mode=$1
  _id=$2
  awk -v mode="$_mode" -v id="$_id" '
    function flush() {
      if (buf == "") return
      if (mode == "drop" && mine) { buf = ""; mine = 0; return }
      if (mode == "front" && mine) { target = buf; buf = ""; mine = 0; return }
      out[++n] = buf; buf = ""
    }
    /^  \* Recent #[0-9]+: Task\{/ {
      flush()
      buf = $0 "\n"
      mine = 0
      if (id != "" && ($0 ~ (" #" id " ") || $0 ~ (" #" id "}"))) mine = 1
      next
    }
    {
      if (buf == "") { head = head $0 "\n" }
      else buf = buf $0 "\n"
    }
    END {
      flush()
      printf "%s", head
      if (mode == "front" && target != "") out[0] = target
      for (i = 0; i <= n; i++) {
        if (out[i] == "") continue
        block = out[i]
        # Keep the "Recent #N" counter in step with the order it now prints in.
        idx++
        sub(/Recent #[0-9]+:/, "Recent #" (idx - 1) ":", block)
        printf "%s", block
      }
    }
  ' "$S/recents.dump" > "$S/recents.dump.new" && mv -f "$S/recents.dump.new" "$S/recents.dump"
}

# Which package a task id belongs to, according to that same dump.
recents_pkg_of() { # recents_pkg_of <id>
  awk -v id="$1" '
    /^  \* Recent #[0-9]+: Task\{/ {
      if ($0 ~ (" #" id " ") || $0 ~ (" #" id "}")) {
        if (match($0, /A=[0-9]+:[^ }]+/)) { p = substr($0, RSTART, RLENGTH); sub(/^A=[0-9]+:/, "", p); print p; exit }
        if (match($0, /I=[^ }]+/)) { p = substr($0, RSTART + 2, RLENGTH - 2); sub(/\/.*/, "", p); print p; exit }
      }
    }
  ' "$S/recents.dump" 2>/dev/null
}

case "$CMD" in
  settings)
    [ -n "$STUB_NOLOG" ] || log_call "$@"
    case "$1" in
      get)
        # printf, not echo: dash's echo reinterprets backslashes inside the
        # value, which the real `settings get` never does. A value that
        # genuinely contained a backslash arrived here mangled.
        #
        # A key marked unreadable fails the way the device fails it - a sentence
        # on stdout instead of a value. That sentence must never become a
        # setting.
        if [ -f "$S/fail_read.$2.$3" ]; then
          echo "cmd: Failure calling service settings: Failed transaction (2147483646)"
          exit 1
        fi
        v=$(sget "$2" "$3")
        if [ -n "$v" ]; then printf '%s\n' "$v"; else echo "null"; fi
        ;;
      put)
        # A ROM that accepts the command and does nothing with it. This is the
        # failure the mode has to notice and tell the truth about - most of all
        # for the navigation switch, where a write that quietly did not take
        # would leave the user with no buttons at all.
        [ -f "$S/refuse_put.$2.$3" ] && exit 0
        printf '%s' "$4" > "$S/settings/$2.$3" ;;
      delete) rm -f "$S/settings/$2.$3" ;;
    esac
    ;;

  wm)
    case "$1" in
      size)
        echo "Physical size: 720x1600"
        [ -f "$S/wm_size_override" ] && cat "$S/wm_size_override"
        ;;
      density)
        echo "Physical density: $(cat "$S/wm_density" 2>/dev/null || echo 280)"
        ;;
    esac
    ;;

  # The phone's own frame-rate setting (Game Mode's FPS intervention). A ROM
  # without device_config has no such file at all.
  device_config)
    log_call "$@"
    [ -f "$S/no_device_config" ] && exit 1
    case "$1 $2" in
      "get game_overlay") cat "$S/game_overlay" 2>/dev/null || echo null ;;
      "put game_overlay")
        [ -f "$S/refuse_game_overlay" ] && exit 0
        printf '%s' "$3" > "$S/game_overlay" ;;
      "delete game_overlay") rm -f "$S/game_overlay" ;;
    esac
    ;;

  # The binder caller. The frame-rate cap speaks to SurfaceFlinger through it;
  # the command is recorded by log_call like every other, so the test can assert
  # the exact rate the module asked for.
  service)
    log_call "$@"
    case "$1 $2" in
      "call SurfaceFlinger") echo "Result: Parcel(00000000  '........')" ;;
    esac
    ;;

  getprop)
    cat "$S/props/$1" 2>/dev/null
    ;;

  # The running processes. The phone's own list, kept as a file so a test can
  # decide what is running while the mode is on - which is the only input the
  # ROM-background option works from.
  ps)
    cat "$S/procs" 2>/dev/null
    ;;

  # The event log, as the daemon's watcher reads it: whatever the test put in
  # eventlog is what happened on the phone, and the stream then ends.
  logcat)
    cat "$S/eventlog" 2>/dev/null
    ;;

  setprop)
    log_call "$@"
    if [ -n "$2" ]; then printf '%s\n' "$2" > "$S/props/$1"; else rm -f "$S/props/$1"; fi
    ;;

  resetprop)
    log_call "$@"
    # resetprop --delete NAME | resetprop -p --delete NAME | resetprop NAME VALUE
    case "$1" in
      --delete) rm -f "$S/props/$2" ;;
      -p)
        shift
        [ "$1" = "--delete" ] && rm -f "$S/props/$2" || printf '%s' "$2" > "$S/props/$1"
        ;;
      *) [ -n "$2" ] && printf '%s' "$2" > "$S/props/$1" ;;
    esac
    ;;

  svc)
    log_call "$@"
    # svc wifi disable / svc bluetooth enable ...
    printf '%s\n' "$2" > "$S/svc.$1"
    ;;

  pm)
    [ -n "$STUB_NOLOG" ] || log_call "$@"
    case "$1" in
      list)
        # pm list packages -3  -> the third-party apps
        # pm list packages -s  -> the phone's own packages
        case "$*" in
          *" -s"*) cat "$S/pkgs_sys" 2>/dev/null | sed 's/^/package:/' ;;
          *)        cat "$S/pkgs3"    2>/dev/null | sed 's/^/package:/' ;;
        esac
        ;;
      unstop)
        # pm unstop [--user N] <pkg> - the inverse of a force-stop, and the one
        # release the module cannot skip: a stopped app is not woken by a push,
        # so leaving it stopped is what silences a messaging app after an exit.
        # This phone's `pm unstop` takes exactly one package per call.
        shift
        [ "$1" = "--user" ] && shift 2
        printf '%s\n' "$1" >> "$S/unstopped"
        sed -i "/^$1$/d" "$S/force_stopped" 2>/dev/null
        ;;
      path) echo "package:/data/app/$2/base.apk" ;;
      enable|disable)
        # pm enable|disable [--user N] <target>
        _st=default; [ "$1" = "disable" ] && _st=disabled-user
        _was=$1
        shift; [ "$1" = "--user" ] && shift 2
        # A target with a slash in it is a COMPONENT, not a package: the phone
        # keeps the two apart and so must this.
        case "$1" in
          */*)
            mkdir -p "$S/component/$(dirname "$1")"
            if [ "$_was" = "disable" ]; then
              printf '3\n' > "$S/component/$1"
            else
              rm -f "$S/component/$1"
            fi
            exit 0 ;;
        esac
        # Enabling a package the ROM already has enabled changes nothing, and
        # the real command leaves no trace of having been asked. Recording one
        # anyway made the round-trip test read the stub's own bookkeeping as the
        # device not coming back: "pm enable" is what the mode runs on the way
        # out for every package it suspended.
        if [ "$_st" = "default" ] && [ ! -f "$S/pkg/$1.enabled" ]; then return 0; fi
        printf '%s\n' "$_st" > "$S/pkg/$1.enabled" ;;
      suspend|unsuspend)
        # pm suspend [--user N] <pkg> [<pkg> ...] - the --user form is what the
        # module uses, and the real command takes a WHOLE LIST of packages in
        # one call (that is what the batched path relies on), so both shapes
        # are accepted here exactly as the phone accepts them. A test can make
        # this phone refuse multi-package calls (refuse_batch) to exercise the
        # per-app fallback.
        _action=$1
        shift
        [ "$1" = "--user" ] && shift 2
        if [ -f "$S/refuse_batch" ] && [ "$#" -gt 1 ]; then
          echo "pm: multi-package calls refused" >&2
          exit 1
        fi
        for _target in "$@"; do
          [ -n "$_target" ] || continue
          if [ "$_action" = "suspend" ]; then
            printf 'true\n' > "$S/pkg/$_target.suspended"
            xml_suspend "$_target" true
          else
            rm -f "$S/pkg/$_target.suspended"
            xml_suspend "$_target" false
          fi
        done
        ;;
      *) : ;;
    esac
    ;;

  am)
    [ -n "$STUB_NOLOG" ] || log_call "$@"
    case "$1" in
      get-standby-bucket) cat "$S/bucket/$2" 2>/dev/null || echo 10 ;;
      task)
        # am task move-to-front <id> / am task remove <id>
        case "$2" in
          move-to-front)
            printf '%s\n' "$3" > "$S/task_in_front"
            printf '%s\n' "${_task_component:-}" > "$S/task_front_component"
            # A command that succeeds and does nothing is the failure the owner
            # hit on the phone, so the stub can be told to behave that way too.
            [ -f "$S/task_move_broken" ] || recents_rewrite front "$3"
            ;;
          remove)
            printf '%s\n' "$3" >> "$S/tasks_removed"
            [ -f "$S/task_remove_broken" ] || recents_rewrite drop "$3"
            ;;
          *) ;;
        esac
        ;;
      stack)
        # The older name for the same operation.
        case "$2" in
          remove)
            printf '%s\n' "$3" >> "$S/tasks_removed"
            [ -f "$S/task_remove_broken" ] || recents_rewrite drop "$3"
            ;;
          *) ;;
        esac
        ;;
      force-stop)
        printf '%s\n' "$2" >> "$S/force_stopped"
        # Stopping an app does close its task.
        if [ ! -f "$S/force_stop_broken" ]; then
          for _t in $(awk '/^  \* Recent #[0-9]+: Task\{/ { if (match($0, /#[0-9]+ /)) { s = substr($0, RSTART + 1, RLENGTH - 2); print s } }' "$S/recents.dump" 2>/dev/null); do
            [ "$(recents_pkg_of "$_t")" = "$2" ] && recents_rewrite drop "$_t"
          done
        fi
        ;;
      set-standby-bucket) printf '%s\n' "$3" > "$S/bucket/$2" ;;
      # ActivityManager's own "this app is idle now": the platform lever the
      # module uses to make a stopped app give its memory back.
      make-uid-idle)
        [ "$2" = "--user" ] && shift 2
        printf '%s\n' "$2" >> "$S/uid_idle" ;;
      kill-all)
        printf '%s\n' "$(date +%s)" >> "$S/kill_all" ;;
      start)
        # am start -n dev.axion.spsm/.SpsmRecentsActivity: this mode's own
        # recents list. Starting it is what puts it on screen, and what the
        # `dumpsys activity activities` read-back below then sees. A test can
        # make the phone refuse the start, which is how a background-activity
        # launch restriction looks from here.
        case "$*" in
          *dev.axion.spsm/.SpsmRecentsActivity*)
            if [ -f "$S/start_recents_broken" ]; then
              echo "Error: Activity not started, unable to resolve Intent"
              exit 1
            fi
            printf 'dev.axion.spsm/.SpsmRecentsActivity\n' > "$S/resumed"
            ;;
        esac
        # am start --task <id> -n <comp> is the last-resort way of bringing a
        # task to the front, and on this ROM it works.
        case "$*" in
          *"--task "*)
            _t=$(printf '%s\n' "$@" | awk '/^--task$/{getline; print; exit}')
            [ -n "$_t" ] || _t=$(printf '%s\n' "$*" | sed -n 's/.*--task \([0-9][0-9]*\).*/\1/p')
            if [ -n "$_t" ]; then
              printf '%s\n' "$_t" > "$S/task_started"
              [ -f "$S/task_start_broken" ] || recents_rewrite front "$_t"
            fi
            ;;
        esac
        # am start -a ... -c android.intent.category.HOME
        # A HOME launch brings the configured home to the front. If the test has
        # marked our home as broken, the launcher stays on screen instead -
        # which is what a crashing home activity looks like from here.
        case "$*" in
          *android.intent.category.HOME*)
            _home=$(cat "$S/home_activity" 2>/dev/null)
            if [ -f "$S/home_broken" ] && [ "$_home" = "dev.axion.spsm/.SpsmHomeActivity" ]; then
              # Our home was launched and died: it never becomes the resumed
              # activity, so the one underneath stays on screen. This is the
              # state the module has to notice.
              printf 'com.android.launcher3/.Launcher\n' > "$S/resumed"
            else
              printf '%s\n' "${_home:-com.android.launcher3/.Launcher}" > "$S/resumed"
            fi
            ;;
        esac
        ;;
      *) : ;;
    esac
    ;;

  cmd)
    log_call "$@"
    case "$1 $2" in
      # The module prefers `cmd <service>` over the wrappers: on the phone,
      # `am` and `pm` are shell wrappers that exec exactly these services and
      # `settings` is a JVM around the same provider - the native path is a
      # third of the cost under load (census of 2026-09-25). The stub answers
      # from the same store either way, so the call is handed to the branch
      # that models the service, failure injections included. STUB_NOLOG keeps
      # the call log at one line per call, naming what really ran.
      "settings get"|"settings put"|"settings delete")
        _s=$0; shift; CMD_OVERRIDE=settings STUB_NOLOG=1 exec sh "$_s" "$@" ;;
      "activity get-standby-bucket"|"activity set-standby-bucket"|"activity force-stop"|"activity make-uid-idle"|"activity kill-all"|"activity start")
        _s=$0; shift; CMD_OVERRIDE=am STUB_NOLOG=1 exec sh "$_s" "$@" ;;
      "package suspend"|"package unsuspend"|"package unstop"|"package list"|"package enable"|"package disable")
        _s=$0; shift; CMD_OVERRIDE=pm STUB_NOLOG=1 exec sh "$_s" "$@" ;;
      # The navigation bar is drawn by an exclusive RRO, and the ROM keeps the
      # secure setting in step with it. Both are modelled by one value here, the
      # way the phone behaves: 0 three-button, 1 two-button, 2 gesture.
      "overlay enable-exclusive")
        # cmd overlay enable-exclusive --user N --category <name>
        _cat=''
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --category) _cat=$2; shift 2 ;;
            --user) shift 2 ;;
            *) shift ;;
          esac
        done
        # A ROM that takes the command and ignores it.
        [ -f "$S/refuse_overlay" ] && exit 0
        case "$_cat" in
          com.android.internal.systemui.navbar.threebutton) printf '%s' 0 > "$S/settings/secure.navigation_mode" ;;
          com.android.internal.systemui.navbar.twobutton)   printf '%s' 1 > "$S/settings/secure.navigation_mode" ;;
          com.android.internal.systemui.navbar.gestural)    printf '%s' 2 > "$S/settings/secure.navigation_mode" ;;
        esac
        ;;
      "game mode")
        [ -f "$S/no_game_service" ] && { echo "Game manager service is not available"; exit 1; }
        _m=$2
        [ "$_m" = "--user" ] && _m=$4
        case "$_m" in
          "") ;;   # asked with no mode: the current one, which this phone does not print
          *) printf '%s' "$_m" > "$S/game_mode" ;;
        esac
        ;;
      "overlay list")
        # The shape this ROM prints: the category's overlays, [x] for the one
        # that is on. A test can make the phone refuse to answer at all.
        [ -f "$S/no_overlay_list" ] && exit 0
        _m=$(cat "$S/settings/secure.navigation_mode" 2>/dev/null)
        echo "com.android.internal"
        case "$_m" in
          0) echo "[x] com.android.internal.systemui.navbar.threebutton"
             echo "[ ] com.android.internal.systemui.navbar.gestural" ;;
          1) echo "[ ] com.android.internal.systemui.navbar.threebutton"
             echo "[x] com.android.internal.systemui.navbar.twobutton"
             echo "[ ] com.android.internal.systemui.navbar.gestural" ;;
          2) echo "[ ] com.android.internal.systemui.navbar.threebutton"
             echo "[x] com.android.internal.systemui.navbar.gestural" ;;
          *) echo "[ ] com.android.internal.systemui.navbar.threebutton"
             echo "[ ] com.android.internal.systemui.navbar.gestural" ;;
        esac
        ;;
      "appops get") cat "$S/appop/$3" 2>/dev/null || echo "RUN_ANY_IN_BACKGROUND: allow" ;;
      "appops set") printf '%s: %s\n' "$4" "$5" > "$S/appop/$3" ;;
      "role get-role-holders")
        # HOME keeps its long-standing file; every other role gets its own,
        # so a test can make this phone an OEM phone (a dialer with a maker's
        # name no static list can know).
        case "$3" in
          android.app.role.HOME) cat "$S/home_role" 2>/dev/null ;;
          *)                     cat "$S/role_$3" 2>/dev/null ;;
        esac ;;
      "package query-activities")
        # Every app that can answer the HOME category, one "pkg/Activity" per
        # line - a test seeds $S/home_query to make this phone carry several
        # launchers. Falls back to the configured home, like resolve-activity.
        case "$*" in
          *android.intent.category.HOME*)
            cat "$S/home_query" 2>/dev/null || cat "$S/home_activity" 2>/dev/null \
              || echo "com.android.launcher3/.Launcher" ;;
        esac ;;
      "role add-role-holder")
        printf '%s\n' "$4" > "$S/home_role"
        [ "$4" = "dev.axion.spsm" ] && printf 'dev.axion.spsm/.SpsmHomeActivity\n' > "$S/home_activity"
        ;;
      "role remove-role-holder") rm -f "$S/home_role" ;;
      # Configuring which activity is HOME does not by itself put it on screen;
      # the launch below is what does, and that is where a broken home shows up.
      "package set-home-activity") printf '%s\n' "$3" > "$S/home_activity" ;;
      "activity task move-to-front")
        printf '%s\n' "$3" > "$S/task_in_front"
        [ -f "$S/task_move_broken" ] || recents_rewrite front "$3" ;;
      "activity task remove")
        printf '%s\n' "$3" >> "$S/tasks_removed"
        [ -f "$S/task_remove_broken" ] || recents_rewrite drop "$3" ;;
      # Component on/off state, as `cmd package get-component-enabled-setting`
      # answers it: a number (0 default, 1 enabled, 2 disabled, 3 disabled-user),
      # which is what the phone prints. A test that wants the word form writes it
      # to the same file by hand.
      "package get-component-enabled-setting")
        _c=$3
        [ "$_c" = "--user" ] && _c=$5
        cat "$S/component/$_c" 2>/dev/null || echo 0
        ;;
      # This ROM's `cmd package resolve-activity` answers "No activity found"
      # unless it is given the action as well as the category. The module was
      # calling it without the action, and recording that sentence as the
      # original home.
      "package resolve-activity")
        case "$*" in
          *android.intent.action.MAIN*)
            cat "$S/home_activity" 2>/dev/null || echo "com.android.launcher3/.Launcher" ;;
          *) echo "No activity found" ;;
        esac
        ;;
      # Component on/off state, in the form the phone answers it: a number - 0
      # default, 1 enabled, 2 disabled, 3 disabled-user. A test that wants the
      # word form, or that wants this ROM's "Unknown command" complaint instead,
      # writes it to $S/component_enabled and that is served as-is.
      "package get-component-enabled-setting")
        if [ -f "$S/component_enabled" ]; then
          cat "$S/component_enabled"
        elif [ -f "$S/component.${3:-${5:-x}}" ]; then
          cat "$S/component.${3:-${5:-x}}"
        else
          _c=$3
          [ "$_c" = "--user" ] && _c=$5
          cat "$S/component/$_c" 2>/dev/null || echo 0
        fi
        ;;
      # cmd package set-component-enabled-setting [--user N] <comp> <value>
      "package set-component-enabled-setting")
        _c=$3
        _v=$4
        if [ "$_c" = "--user" ]; then _c=$5; _v=$6; fi
        # A ROM that takes the command and does nothing with it - the failure
        # mode this module refuses to claim as a change.
        if [ ! -f "$S/component_set_broken" ]; then
          mkdir -p "$S/component/$(dirname "$_c")"
          case "$_v" in
            0|default) rm -f "$S/component/$_c" ;;          # the manifest state: no record
            *) printf '%s\n' "$_v" > "$S/component/$_c" ;;
          esac
        fi
        ;;
      # The radio probes, in the order the module asks them. They answer from the
      # same state `svc` writes, so switching a radio is visible to the next read.
      "wifi status")
        [ -f "$S/fail_read.radio.wifi" ] && exit 1
        if [ "$(cat "$S/svc.wifi" 2>/dev/null || echo enable)" = "disable" ]; then
          echo "Wifi is disabled"
        else
          echo "Wifi is enabled"
        fi
        ;;
      "bluetooth_manager is-enabled")
        [ -f "$S/fail_read.radio.bt" ] && exit 1
        if [ "$(cat "$S/svc.bluetooth" 2>/dev/null || echo enable)" = "disable" ]; then
          echo false
        else
          echo true
        fi
        ;;
      "deviceidle whitelist") cat "$S/deviceidle_whitelist" 2>/dev/null ;;
      "deviceidle step") : ;;
      # The location switch is a command, not a setting - there is nothing in
      # `settings get` that describes it, which is exactly why the module has to
      # ask here and keep what it is told.
      "location is-location-enabled")
        if [ -f "$S/fail_read.cmd.location_enabled" ]; then
          echo "cmd: Failure calling service location: Failed transaction (2147483646)"
          exit 1
        fi
        cat "$S/location_enabled" 2>/dev/null || echo true
        ;;
      "location set-location-enabled") printf '%s\n' "$3" > "$S/location_enabled" ;;
      *) : ;;
    esac
    ;;

  dumpsys)
    case "$1" in
      window)
        # The navigation bar, the way the phone prints it in its insets - the
        # frame is what the touch watcher reads to know where the bar is. A test
        # with no file falls back to the 48dp heuristic.
        if [ -f "$S/no_nav_insets" ]; then
          echo "  InsetsState"
          echo "    InsetsSource: {type=ITYPE_STATUS_BAR frame=[0,0][720,72] visible=true}"
        else
          _top=$(cat "$S/navbar_top" 2>/dev/null || echo 1516)
          echo "  InsetsState"
          echo "    InsetsSource: {type=ITYPE_STATUS_BAR frame=[0,0][720,72] visible=true}"
          echo "    InsetsSource: {type=ITYPE_NAVIGATION_BAR frame=[0,$_top][720,1600] visible=true}"
        fi
        ;;
      battery)
        # Level is a file the test sets, so drain reporting can be asserted.
        echo "  level: $(cat "$S/battery_level" 2>/dev/null || echo 100)"
        ;;
      display)
        # The panel's own modes, in the shape the phone prints them. What a
        # frame-rate cap can ask for is decided here: a mode that does not exist
        # is a frame rate the panel cannot show.
        if [ -f "$S/display_modes" ]; then cat "$S/display_modes"; fi
        ;;
      deviceidle)
        if [ "$2" = "whitelist" ]; then cat "$S/deviceidle_whitelist"; fi
        if [ "$2" = "force-idle" ]; then log_call "$@"; : > "$S/doze_forced"; fi
        if [ "$2" = "unforce" ]; then log_call "$@"; rm -f "$S/doze_forced"; fi
        if [ -z "$2" ]; then echo "  mState=ACTIVE"; fi
        ;;
      package)
        e=$(cat "$S/pkg/$2.enabled" 2>/dev/null || echo default)
        echo "  Package [$2]:"
        echo "    enabled=$e"
        if [ -f "$S/pkg/$2.suspended" ]; then echo "    suspended=true"; else echo "    suspended=false"; fi
        ;;
      wifi)
        [ -f "$S/fail_read.radio.wifi" ] && exit 1
        if [ "$(cat "$S/svc.wifi" 2>/dev/null || echo enable)" = "disable" ]; then
          echo "Wi-Fi is disabled"
        else
          echo "Wi-Fi is enabled"
        fi
        ;;
      bluetooth_manager)
        [ -f "$S/fail_read.radio.bt" ] && exit 1
        if [ "$(cat "$S/svc.bluetooth" 2>/dev/null || echo enable)" = "disable" ]; then
          echo "  enabled: false"
        else
          echo "  enabled: true"
        fi
        ;;
      nfc)
        [ -f "$S/fail_read.radio.nfc" ] && exit 1
        if [ "$(cat "$S/svc.nfc" 2>/dev/null || echo enable)" = "disable" ]; then
          echo "  mState=off"
        else
          echo "  mState=on"
        fi
        ;;
      power)
        # Counted: only the degraded path (no readable panel) may ask this, and
        # it must ask rarely - the cache is asserted by counting these.
        log_call "$@"
        cat "$S/screen" 2>/dev/null | grep -q off && echo "mWakefulness=Asleep" || echo "mWakefulness=Awake"
        ;;
      activity)
        # `dumpsys activity activities` is what the module reads to see which
        # activity is actually on screen; the format below is the one Android
        # prints (topResumedActivity=ActivityRecord{... <component> ...}).
        if [ "$2" = "recents" ]; then
          # The task list, in the shape this ROM prints. The fixture is the phone's
          # real output, so the parser is tested against the format it must read.
          if [ -f "$S/recents.dump" ]; then
            cat "$S/recents.dump"
          else
            echo "ACTIVITY MANAGER RECENT TASKS (dumpsys activity recents)"
            echo "No recent tasks."
          fi
        elif [ "$2" = "activities" ]; then
          printf '    topResumedActivity=ActivityRecord{cafe1 u0 %s t879}\n' \
            "$(cat "$S/resumed" 2>/dev/null || echo com.android.launcher3/.Launcher)"
        else
          echo "mKeyguardShowing=false"
        fi
        ;;
    esac
    ;;

  *)
    : ;;
esac
exit 0
