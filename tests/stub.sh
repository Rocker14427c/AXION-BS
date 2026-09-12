#!/bin/sh
# Fake Android commands for the SPSM test harness.
#
# This is installed into tests' PATH under the names of the real commands
# (settings, getprop, pm, am, cmd, svc, dumpsys, resetprop) so the REAL engine
# scripts can be exercised without a phone. Everything is file-backed under
# $SPSM_STUB so the test can assert on it afterwards.
#
# It deliberately mimics the quirks the engine depends on:
#   * `dumpsys deviceidle whitelist` output format
#   * `cmd appops get <pkg> RUN_ANY_IN_BACKGROUND` output format
#   * `am get-standby-bucket` returning a number
#   * `dumpsys package <pkg>` reporting `enabled=`

S="$SPSM_STUB"
CMD=${CMD_OVERRIDE:-$(basename "$0")}
mkdir -p "$S/props" "$S/settings" "$S/bucket" "$S/appop" "$S/pkg"

log_call() { echo "$CMD $*" >> "$S/calls"; }

# ----------------------------------------------------------------- settings
sget() { cat "$S/settings/$1.$2" 2>/dev/null; }

case "$CMD" in
  settings)
    log_call "$@"
    case "$1" in
      get)
        # printf, not echo: dash's echo reinterprets backslashes inside the
        # value, which the real `settings get` never does. A value that
        # genuinely contained a backslash arrived here mangled.
        v=$(sget "$2" "$3")
        if [ -n "$v" ]; then printf '%s\n' "$v"; else echo "null"; fi
        ;;
      put) printf '%s' "$4" > "$S/settings/$2.$3" ;;
      delete) rm -f "$S/settings/$2.$3" ;;
    esac
    ;;

  getprop)
    cat "$S/props/$1" 2>/dev/null
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
    log_call "$@"
    case "$1" in
      list)
        # pm list packages -3
        cat "$S/pkgs3" 2>/dev/null | sed 's/^/package:/'
        ;;
      path) echo "package:/data/app/$2/base.apk" ;;
      enable|disable)
        # pm enable|disable [--user N] <target>
        _st=default; [ "$1" = "disable" ] && _st=disabled-user
        shift; [ "$1" = "--user" ] && shift 2
        printf '%s\n' "$_st" > "$S/pkg/$1.enabled" ;;
      suspend) printf 'true\n' > "$S/pkg/$2.suspended" ;;
      unsuspend) rm -f "$S/pkg/$2.suspended" ;;
      *) : ;;
    esac
    ;;

  am)
    log_call "$@"
    case "$1" in
      get-standby-bucket) cat "$S/bucket/$2" 2>/dev/null || echo 10 ;;
      set-standby-bucket) printf '%s\n' "$3" > "$S/bucket/$2" ;;
      start)
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
      "appops get") cat "$S/appop/$3" 2>/dev/null || echo "RUN_ANY_IN_BACKGROUND: allow" ;;
      "appops set") printf '%s: %s\n' "$4" "$5" > "$S/appop/$3" ;;
      "role get-role-holders") cat "$S/home_role" 2>/dev/null ;;
      "role add-role-holder")
        printf '%s\n' "$4" > "$S/home_role"
        [ "$4" = "dev.axion.spsm" ] && printf 'dev.axion.spsm/.SpsmHomeActivity\n' > "$S/home_activity"
        ;;
      "role remove-role-holder") rm -f "$S/home_role" ;;
      # Configuring which activity is HOME does not by itself put it on screen;
      # the launch below is what does, and that is where a broken home shows up.
      "package set-home-activity") printf '%s\n' "$3" > "$S/home_activity" ;;
      "package resolve-activity") cat "$S/home_activity" 2>/dev/null || echo "com.android.launcher3/.Launcher" ;;
      "package get-component-enabled-setting") cat "$S/component_enabled" 2>/dev/null || echo "DEFAULT" ;;
      "deviceidle whitelist") cat "$S/deviceidle_whitelist" 2>/dev/null ;;
      "deviceidle step") : ;;
      *) : ;;
    esac
    ;;

  dumpsys)
    case "$1" in
      battery)
        # Level is a file the test sets, so drain reporting can be asserted.
        echo "  level: $(cat "$S/battery_level" 2>/dev/null || echo 100)"
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
        ;;
      power)
        cat "$S/screen" 2>/dev/null | grep -q off && echo "mWakefulness=Asleep" || echo "mWakefulness=Awake"
        ;;
      activity)
        # `dumpsys activity activities` is what the module reads to see which
        # activity is actually on screen; the format below is the one Android
        # prints (topResumedActivity=ActivityRecord{... <component> ...}).
        if [ "$2" = "activities" ]; then
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
