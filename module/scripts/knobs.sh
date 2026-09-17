#!/system/bin/sh
# Axion SPSM v3 - the knob registry.
#
# Every single thing SPSM is allowed to change is declared here as a knob with
# three functions:
#
#   meta_<id>        category|label|description|default|scope|tags
#   snapshot_<id>    print the current value(s), one "target<TAB>value" per line
#   apply_<id>       make the change
#   restore_<id> F   put back whatever file F holds (F is a saved snapshot)
#
# scope=session  -> applied for the whole time SPSM is on
# scope=deep     -> applied only while the screen is off, undone on wake
#
# Values are addressed with a small target syntax so one generic snapshot/apply
# path covers sysfs nodes, Settings rows and properties:
#
#   /sys/...          sysfs or procfs node
#   @ns:key           Settings row (ns = global|secure|system)
#   %prop.name        system property
#
# The APK reads this same list (engine.sh dump-knobs writes knobs.list) so the
# options screen can never drift from what the scripts actually do.

# ------------------------------------------------------------------ targets
# A failed read must never look like a value.
#
# On the device this module was written for, the settings provider occasionally
# answers a get with a sentence instead of a value:
#
#   cmd: Failure calling service settings: Failed transaction (2147483646)
#
# That sentence was recorded as if it were the setting, which meant it could be
# written back into the settings database on revert - a reading error becoming a
# stored value. Anything shaped like a failure is treated as "no reading".
read_failed() {
  case "$1" in
    cmd:*|Error:*|error:*|Failed*|Exception*|java.*|*'Failed transaction'*|*'Exception'*) return 0 ;;
    *) return 1 ;;
  esac
}

kv_read() { # kv_read target -> value, or (MISSING)
  case "$1" in
    /*) exists "$1" || { printf '(MISSING)'; return; }
        _v=$(rd "$1"); printf '%s' "$_v" ;;
    @*) _ns=${1#@}; _ns=${_ns%%:*}; _key=${1#*:}
        _v=$(sget "$_ns" "$_key" 2>/dev/null)
        if read_failed "$_v"; then
          # The failure seen on the device is a refused binder transaction,
          # which is usually momentary; one retry after a breath costs a fifth of
          # a second and turns most of these into a real reading.
          sleep 0.2 2>/dev/null || sleep 1
          _v=$(sget "$_ns" "$_key" 2>/dev/null)
        fi
        if read_failed "$_v"; then printf '(MISSING)'; return; fi
        [ -z "$_v" ] && _v=null
        printf '%s' "$_v" ;;
    %*) _v=$(gprop "${1#%}"); printf '%s' "$_v" ;;
    *)  printf '(MISSING)' ;;
  esac
}

kv_write() { # kv_write target value
  case "$1" in
    /*) exists "$1" || return 1; w "$2" "$1" ;;
    @*) _ns=${1#@}; _ns=${_ns%%:*}; _key=${1#*:}
        if [ "$2" = "null" ] || [ -z "$2" ]; then sdel "$_ns" "$_key"; else sput "$_ns" "$_key" "$2"; fi ;;
    %*) if [ -z "$2" ]; then dprop "${1#%}"; else sprop "${1#%}" "$2"; fi ;;
    *)  return 1 ;;
  esac
}

# Print "target<TAB>value" for each target, so restore_kv can rebuild it.
# Read several targets at once.
#
# Every read here is a subprocess on the device (`settings`, `getprop`, a file),
# and reading them one after another is where a revert or an apply spends most
# of its wall-clock time: a phone in this mode is slow to fork. The reads are
# independent, so they run together and are collected in order.
#
# The result files are written under a temporary name and moved into place, so a
# reader never sees a half-written value even if the wait is cut short; and if a
# wait does return early, each target without a result is read the slow way
# rather than recorded as empty.
kv_read_many() { # kv_read_many <dir> <target>...
  _d=$1; shift
  mkdir -p "$_d" 2>/dev/null
  _n=0
  for _t in "$@"; do
    ( kv_read "$_t" > "$_d/$$.$_n.part" && mv -f "$_d/$$.$_n.part" "$_d/$$.$_n" 2>/dev/null ) &
    _n=$((_n + 1))
  done
  wait
  _n=0
  for _t in "$@"; do
    [ -f "$_d/$$.$_n" ] || kv_read "$_t" > "$_d/$$.$_n"
    _n=$((_n + 1))
  done
}

kv_result() { cat "$1/$$.$2" 2>/dev/null; }

snap_kv() {
  _d=$SPSM_DIR/.tmp
  _n=0
  _list=''
  for _t in "$@"; do
    [ -n "$_t" ] || continue
    _list="$_list $_t"
  done
  # shellcheck disable=SC2086
  kv_read_many "$_d" $_list
  _n=0
  for _t in $_list; do
    # Values are encoded so that one record is always one line, whatever the
    # value holds; restore_kv decodes them again on the way out.
    printf '%s\t%s\n' "$_t" "$(enc_val "$(kv_result "$_d" "$_n")")"
    rm -f "$_d/$$.$_n" "$_d/$$.$_n.part"
    _n=$((_n + 1))
  done
}

# Apply "target=value" pairs, splitting on the FIRST '=' only.
apply_kv() {
  for _pair in "$@"; do
    _t=${_pair%%=*}
    _v=${_pair#*=}
    # Never change a value we could not read. The engine records the original
    # immediately before this runs, so if that record says there was no reading,
    # writing our value here would be a change with nothing to undo it by - a
    # setting that stays changed after the mode is switched off. On the device
    # one global key refuses to be read at all, and this is what keeps that from
    # becoming an unrevertable change.
    if [ -n "${KNOB_ID:-}" ] && [ -f "$JOURNAL/$KNOB_ID.orig" ]; then
      if [ "$(snap_file_get "$JOURNAL/$KNOB_ID.orig" "$_t")" = "(MISSING)" ]; then
        log "skip $_t: it could not be read, so it is not ours to change"
        continue
      fi
    fi
    kv_write "$_t" "$_v"
  done
}

# Restore from a snapshot file produced by snap_kv.
#
#   restore_kv <orig-file> [<applied-file>]
#
# Values that are (MISSING) are skipped: the node did not exist when we
# started, so there is nothing to put back - writing to a node that was never
# there is how a revert "succeeds" while leaving the device changed.
#
# When the applied snapshot is supplied, the decision is made PER TARGET: a
# value is only written back if the live value is still the one we set. Two
# knobs that happen to share a target (wifi_off and scan_always_off both look
# at wifi_scan_always_enabled) therefore cannot make each other look
# "externally changed", and a change the user made after us is still respected.
restore_kv() {
  [ -f "$1" ] || return 0

  # First pass: work out which targets need a current value, and read all of them
  # at once (see kv_read_many - the comparison reads are half of a revert's
  # cost). Records with nothing to read are skipped here and below, and the
  # result index counts only the records that were actually read.
  _ds=$SPSM_DIR/.tmp
  _idx=0
  _list=''
  while IFS=$TAB read -r _t _v || [ -n "$_t" ]; do
    [ -n "$_t" ] || continue
    [ "$_v" = "(MISSING)" ] && continue
    _list="$_list $_t"
    _idx=$((_idx + 1))
  done < "$1"
  # shellcheck disable=SC2086
  kv_read_many "$_ds" $_list

  # Second pass: decide per value whether it is still ours to undo, and write.
  #
  # The writes go together rather than one after another. They are different
  # values - the order between them means nothing - and each one is an exec that
  # costs a phone a fifth of a second: a knob with six values spent three seconds
  # of the exit writing six independent settings, and there are a dozen such
  # knobs. The applied snapshot is also read once here instead of once per
  # target, which was a `cat` per value.
  _applied=''
  [ -f "$2" ] && _applied=$(cat "$2" 2>/dev/null)
  _idx=0
  while IFS=$TAB read -r _t _v || [ -n "$_t" ]; do
    [ -n "$_t" ] || continue
    [ "$_v" = "(MISSING)" ] && continue
    if [ -n "$_applied" ]; then
      # Both sides are in the encoded form, so this comparison does not care
      # what the value contains.
      _was=$(snap_get "$_applied" "$_t")
      _cur=$(enc_val "$(kv_result "$_ds" "$_idx")")
      # Still ours to undo? If not, a newer value wins.
      if [ -n "$_was" ] && [ "$_cur" != "$_was" ]; then
        rm -f "$_ds/$$.$_idx" "$_ds/$$.$_idx.part"
        _idx=$((_idx + 1))
        continue
      fi
    fi
    ( kv_write "$_t" "$(unesc "$_v")" ) &
    rm -f "$_ds/$$.$_idx" "$_ds/$$.$_idx.part"
    _idx=$((_idx + 1))
  done < "$1"
  wait

  # Nothing of ours may be left in the scratch dir, whatever happened above.
  rm -f "$_ds/$$".* 2>/dev/null
  return 0
}

# ------------------------------------------------------------------ node sets
# RMX3430 / Helio G85 shared DT2W + gesture nodes (same list as FIX-DT2W.sh).
DT2W_NODES="
/proc/touchpanel/double_tap_enable
/proc/touchpanel/double_tap
/proc/touchpanel/gesture_enable
/proc/touchpanel/enable_dt2w
/proc/tp_gesture
/proc/ilitek/gesture
/proc/ilitek/double_tap
/sys/touchpanel/double_tap
/sys/class/touch/tp_gesture
/sys/class/touch/tp_dev/gesture_on
/sys/devices/virtual/touch/tp_dev/gesture_on
/sys/devices/platform/soc/soc:touch/gesture_on
/sys/class/ms-touchscreen-mtk/device/gesture_wakeup
"
DT2W_SETTINGS="@secure:double_tap_to_wake @system:double_tap_to_wake @secure:tap_to_wake @secure:wake_gesture_enabled"

GED_PARAMS=/sys/module/ged/parameters

# ============================================================ Display / UI

meta_home_swap() {
  echo "Display|SPSM home screen|Replaces your home screen with this one while the mode is on, and puts your normal home back when you turn the mode off.|1|session|core"
}
snapshot_home_swap() {
  printf 'home\t%s\n' "$(home_holder)"

  # The role holder is not the only thing that decides what HOME opens: the
  # package manager also stores a configured home activity, and leaving that
  # pointing at us would send the next HOME press to a disabled activity. On the
  # device this was written for, the configured activity is in fact the part
  # that decides, and the role holder is not.
  #
  # resolve-activity needs the action as well as the category. Without it this
  # ROM answers "No activity found" - which was being recorded as the original
  # home, so the revert could not put the launcher back by that route.
  _act=$(cmd package resolve-activity --brief -a android.intent.action.MAIN \
           -c android.intent.category.HOME 2>/dev/null | tail -1)
  # A component looks like pkg/.Activity - one slash, no spaces. Anything else
  # ("No activity found", a command's complaint, an empty read) is recorded as
  # "none" so that nothing can later be configured from it.
  case "$_act" in
    */*) case "$_act" in *' '*|*/*/*) _act=none ;; esac ;;
    *) _act=none ;;
  esac
  printf 'activity\t%s\n' "$_act"

  # Whether our activity was explicitly enabled before we touched it. Not every
  # ROM has this subcommand; "unknown" means the revert must fall back on the
  # manifest default, which is disabled, so that is what it does.
  _en=$(cmd package get-component-enabled-setting dev.axion.spsm/.SpsmHomeActivity 2>/dev/null | tail -1)
  case "$_en" in
    ENABLED*|enabled*|DISABLED*|disabled*) ;;
    *) _en=unknown ;;
  esac
  printf 'component\t%s\n' "$_en"
}
# Returns 2 to tell the engine the change was put back by us (see knob_apply).
apply_home_swap() {
  pm enable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1
  set_home dev.axion.spsm
  launch_home

  # The home is the one change that must never be left half-done. If our
  # activity does not come up, the phone is left with no home screen at all -
  # which is exactly what happened on the first device test of this feature, and
  # what turned a power saving mode into a phone the user had to rescue. So the
  # swap is watched, and the user's launcher goes straight back if it failed.
  _i=0
  _seen=unknown
  while [ "$_i" -lt 24 ]; do
    _seen=$(home_resumed)
    if [ "$_seen" = ours ]; then
      # Two facts worth having in the log the moment the gesture has to be
      # diagnosed: which navigation this phone is using, and what Android says
      # the home is. A bottom-edge swipe means "go home" on a gesture-navigation
      # phone and never reaches an app at all, so whether it can open the recents
      # list depends on these two lines.
      log "home_swap: our home is up - navigation_mode=$(sget secure navigation_mode) (0=3-button 1=2-button 2=gestures) home=$(home_activity_now)"
      return 0
    fi
    _i=$((_i + 1))
    sleep 0.25 2>/dev/null || sleep 1
  done

  case "$_seen" in
    other)
      # Only undo this if we know what to put back: restoring from an empty
      # snapshot would guess a launcher, and guessing wrong is worse than the
      # swap we are trying to repair.
      if [ -s "$JOURNAL/home_swap.orig" ]; then
        log "home_swap: our home did not come up in 6s - putting your launcher back"
        restore_home_swap "$JOURNAL/home_swap.orig" ""
        return 2
      fi
      log "WARN home_swap: our home did not come up and no original was recorded - leaving it"
      ;;
    *)
      # No answer from the device: keep the swap rather than undo a change that
      # may well have worked.
      log "home_swap: could not confirm our home came up - leaving it in place"
      ;;
  esac
  return 0
}
# The launcher before us. The journal recorded it when the swap was applied, and
# that record is the honest answer; a phone whose journal has nothing (the swap
# was switched off, or it is the first run) is asked directly.
home_package() {
  _h=$(snap_file_val "$JOURNAL/home_swap.orig" home)
  if [ -z "$_h" ] && has cmd; then
    _r=$(cmd package resolve-activity --brief -a android.intent.action.MAIN \
            -c android.intent.category.HOME 2>/dev/null | tail -n 1)
    case "$_r" in
      */*) _h=${_r%%/*} ;;
    esac
  fi
  [ -n "$_h" ] || _h=com.android.launcher3
  printf '%s\n' "$_h"
}

# The owner's report: coming out of the mode, the launcher's app drawer was full
# of grey, unloaded icons - apps that opened perfectly well, drawn as if they had
# been suspended - and a force stop and fresh start was what put them right.
#
# The launcher builds its app list once and keeps it. While the mode was on, the
# state that list was built from changed underneath it: the per-app standby
# buckets, the background restrictions, apps stopped. A launcher that is merely
# resumed does not rebuild it; a launcher that is started does. And the launcher
# is what the phone goes back to, so this is repaired once, on the way out.
refresh_launcher() { # refresh_launcher <package>
  _pkg=$1
  case "$_pkg" in
    ''|dev.axion.spsm) return 0 ;;
    *[!A-Za-z0-9._]*) return 0 ;;
  esac
  has am || return 0
  am force-stop "$_pkg" >/dev/null 2>&1
  log "launcher refreshed: $_pkg restarted, so its app list is rebuilt from the phone as it is now"
  # Straight back up: a force-stopped home would otherwise leave the phone with
  # nothing on screen until the next press of Home.
  am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
}

restore_home_swap() {
  _orig=$(snap_file_val "$1" home)
  _act=$(snap_file_val "$1" activity)
  _comp=$(snap_file_val "$1" component)

  cmd role remove-role-holder android.app.role.HOME dev.axion.spsm >/dev/null 2>&1
  if [ -n "$_orig" ] && [ "$_orig" != "dev.axion.spsm" ]; then
    set_home "$_orig"
  else
    set_home com.android.launcher3
  fi
  # Put back the exact home activity that was configured before, if we have one
  # that is believable. A recorded "No activity found" or another command's
  # complaint is not a component, and must not be configured as one.
  case "$_act" in
    ''|none|*' '*|*/*/*) : ;;
    */*) cmd package set-home-activity "$_act" >/dev/null 2>&1 ;;
  esac
  # Only re-disable our activity if it was not already explicitly enabled. The
  # manifest ships it disabled, and an unreadable state means exactly that.
  case "$_comp" in
    ENABLED*|enabled*) : ;;
    *) pm disable --user 0 dev.axion.spsm/.SpsmHomeActivity >/dev/null 2>&1 ;;
  esac
  launch_home
}

meta_dt2w_off() {
  echo "Display|Turn off double-tap to wake|Taps and swipes on the sleeping screen will not wake the phone. The power button still works.|1|session|battery"
}
snapshot_dt2w_off() { snap_kv $DT2W_SETTINGS $DT2W_NODES; }
apply_dt2w_off() { apply_kv "@secure:double_tap_to_wake=0" "@system:double_tap_to_wake=0" "@secure:tap_to_wake=0"; for _f in $DT2W_NODES; do w 0 "$_f"; done; }
restore_dt2w_off() { restore_kv "$1" "$2"; }

meta_aod_off() {
  echo "Display|Turn off always-on display|Stops the clock and notifications showing on the screen while it is asleep.|1|session|battery"
}
snapshot_aod_off() { snap_kv @secure:doze_always_on @secure:doze_enabled @system:doze_always_on /sys/devices/platform/soc/soc:mtk-tb/ambient_enable; }
apply_aod_off() { apply_kv "@secure:doze_always_on=0" "@secure:doze_enabled=0" "@system:doze_always_on=0"; }
restore_aod_off() { restore_kv "$1" "$2"; }

meta_brightness_cap() {
  echo "Display|Limit screen brightness|Keeps the screen at a low, fixed brightness. It never makes the screen brighter than you set it.|1|session|battery"
}
snapshot_brightness_cap() { snap_kv "$BL_PATH" @system:screen_brightness @system:screen_brightness_mode; }
# The cap in this phone's own units.
#
# brightness_cap is written as a fraction of the panel's maximum (or as a
# percentage, or as a raw value for someone who knows their node), because the
# node's range is not the same on every device: a hardcoded 160 is a real dim on
# a 0..255 panel and an invisible nudge on this 0..4095 one. Resolving it here
# means a config carried over from another phone cannot silently do nothing.
cap_value() {
  _c=$(cfg brightness_cap 8)
  _max=$(screen_panel_ceiling)
  case "$_c" in
    *%) _pct=${_c%\%} ;;
    *)
      case "$_c" in
        *[!0-9]*) _pct=$_c ;;
        *) [ "$_c" -le 100 ] 2>/dev/null && _pct=$_c || { echo "$_c"; return 0; } ;;
      esac
      ;;
  esac
  case "$_pct" in
    ''|*[!0-9]*) _pct=8 ;;
  esac
  [ "$_pct" -lt 1 ] && _pct=1
  [ "$_pct" -gt 100 ] && _pct=100
  echo $(( _max * _pct / 100 ))
}

apply_brightness_cap() {
  _cap=$(cap_value)
  _cur=$(rd "$BL_PATH")
  # A cap lowers the screen; it never raises it. Someone who keeps the panel
  # darker than the cap gets to keep their eyesight - and their battery. 0 means
  # the panel is off, which is not ours to change either.
  if [ -n "$_cur" ] && [ "$_cur" != "0" ] && [ "$_cur" -gt "$_cap" ] 2>/dev/null; then
    w "$_cap" "$BL_PATH"
  fi
  sput system screen_brightness_mode 0
}
restore_brightness_cap() { restore_kv "$1" "$2"; }

meta_timeout_short() {
  echo "Display|15-second screen timeout|The screen turns itself off 15 seconds after you stop touching it.|1|session|battery"
}
snapshot_timeout_short() { snap_kv @system:screen_off_timeout; }
apply_timeout_short() { apply_kv "@system:screen_off_timeout=$(cfg timeout_ms 15000)"; }
restore_timeout_short() { restore_kv "$1" "$2"; }

meta_animations_off() {
  echo "Display|Turn off animations|Removes screen animations, so everything feels quicker on reduced power.|1|session|perf"
}
snapshot_animations_off() { snap_kv @global:animator_duration_scale @global:transition_animation_scale @global:window_animation_scale; }
apply_animations_off() { apply_kv "@global:animator_duration_scale=0" "@global:transition_animation_scale=0" "@global:window_animation_scale=0"; }
restore_animations_off() { restore_kv "$1" "$2"; }

meta_haptic_off() {
  echo "Display|Turn off vibration|Stops the phone vibrating for taps and key presses.|1|session|battery"
}
snapshot_haptic_off() { snap_kv @system:haptic_feedback_enabled @system:vibrate_on; }
apply_haptic_off() { apply_kv "@system:haptic_feedback_enabled=0" "@system:vibrate_on=0"; }
restore_haptic_off() { restore_kv "$1" "$2"; }

meta_rotate_lock() {
  echo "Display|Lock screen rotation|Keeps the screen upright, so the rotation sensor stays quiet.|0|session|experimental"
}
snapshot_rotate_lock() { snap_kv @system:accelerometer_rotation; }
apply_rotate_lock() { apply_kv "@system:accelerometer_rotation=0"; }
restore_rotate_lock() { restore_kv "$1" "$2"; }

# ============================================================ Radio / network

meta_wifi_off() {
  echo "Radio|Turn off Wi-Fi|Wi-Fi switches off while the mode is on. Calls, SMS and mobile data keep working.|1|session|battery"
}
# ----------------------------------------------------------------- radios
# Wi-Fi, Bluetooth and NFC are not settings: `svc wifi disable` does not appear in
# `settings get` at all, and on modern Android the old *_on globals are either
# gone or stale. The log from the device showed exactly why that matters - the
# recorded "original" for Bluetooth was 0 while the radio was on, and NFC's was
# the literal `null`, so the exit read those and left both radios off. Turning a
# radio off with no believable way to turn it back on is the same mistake that
# was already fixed for location.
#
# So the state is asked of the system, from a list of sources, and if none of
# them answers the radio is not touched at all.
RADIO_STATE="$ORIG_DIR/radio_state.tsv"

radio_enabled() { # radio_enabled wifi|bt|nfc -> true|false, prints nothing when unknown
  case "$1" in
    wifi)
      if has cmd; then
        _o=$(cmd wifi status 2>/dev/null | head -1)
        case "$_o" in
          *"is enabled"*) printf 'true'; return ;;
          *"is disabled"*) printf 'false'; return ;;
        esac
      fi
      if has dumpsys; then
        _o=$(dumpsys wifi 2>/dev/null | sed -n 's/^Wi-Fi is \([a-z]*\).*/\1/p' | head -1)
        case "$_o" in enabled) printf 'true'; return ;; disabled) printf 'false'; return ;; esac
      fi
      _o=$(sget global wifi_on)
      case "$_o" in 1|true|on) printf 'true'; return ;; 0|false|off) printf 'false'; return ;; esac
      ;;
    bt)
      # Android 13+ dropped the bluetooth_on global; the manager knows.
      if has cmd; then
        _o=$(cmd bluetooth_manager is-enabled 2>/dev/null | tr -d '\r' | head -1)
        case "$_o" in true|false) printf '%s' "$_o"; return ;; esac
      fi
      if has dumpsys; then
        _o=$(dumpsys bluetooth_manager 2>/dev/null | sed -n 's/^ *enabled: *\(true\|false\).*/\1/p' | head -1)
        case "$_o" in true|false) printf '%s' "$_o"; return ;; esac
      fi
      _o=$(sget global bluetooth_on)
      case "$_o" in 1|true|on) printf 'true'; return ;; 0|false|off) printf 'false'; return ;; esac
      ;;
    data)
      # mobile_data is a global on AOSP; some ROMs keep it under a numbered name
      # per SIM, so both spellings are tried before giving up.
      for _k in mobile_data mobile_data1 mobile_data2; do
        _o=$(sget global "$_k")
        case "$_o" in
          1|true|on) printf 'true'; return ;;
          0|false|off) printf 'false'; return ;;
        esac
      done
      ;;
    nfc)
      if has dumpsys; then
        _o=$(dumpsys nfc 2>/dev/null | sed -n 's/.*mState=\([A-Za-z]*\).*/\1/p' | head -1)
        # mState=on / mState=off, and this ROM's own spelling of it.
        case "$_o" in on|ON|enabled) printf 'true'; return ;; off|OFF|disabled) printf 'false'; return ;; esac
      fi
      _o=$(sget global nfc_on)
      case "$_o" in 1|true|on) printf 'true'; return ;; 0|false|off) printf 'false'; return ;; esac
      ;;
  esac
  return 1
}

# Recorded once per session, before anything is switched, and read back by the
# restore. Written in the apply (not in a snapshot function, which must only
# read; see snapshot_block_other_apps for what that mistake cost).
radio_remember() { # radio_remember <radio>
  [ -f "$RADIO_STATE" ] || : > "$RADIO_STATE"
  [ -n "$(snap_file_get "$RADIO_STATE" "$1")" ] && return 0
  _v=$(radio_enabled "$1") || return 1
  printf '%s\t%s\n' "$1" "$_v" >> "$RADIO_STATE"
  return 0
}
radio_was() { snap_file_val "$RADIO_STATE" "$1"; }
radio_forget() { # radio_forget <radio> - after it was put back
  [ -f "$RADIO_STATE" ] || return 0
  grep -v "^$1	" "$RADIO_STATE" > "$RADIO_STATE.tmp" 2>/dev/null
  mv -f "$RADIO_STATE.tmp" "$RADIO_STATE" 2>/dev/null
}

radio_set() { # radio_set wifi|bt|nfc on|off
  case "$1:$2" in
    wifi:off) has svc && svc wifi disable >/dev/null 2>&1
              has cmd && cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 ;;
    wifi:on)  has svc && svc wifi enable >/dev/null 2>&1
              has cmd && cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 ;;
    bt:off)   has svc && svc bluetooth disable >/dev/null 2>&1
              has cmd && cmd bluetooth_manager disable >/dev/null 2>&1 ;;
    bt:on)    has svc && svc bluetooth enable >/dev/null 2>&1
              has cmd && cmd bluetooth_manager enable >/dev/null 2>&1 ;;
    nfc:off)  has svc && svc nfc disable >/dev/null 2>&1 ;;
    nfc:on)   has svc && svc nfc enable >/dev/null 2>&1 ;;
    data:off) has svc && svc data disable >/dev/null 2>&1 ;;
    data:on)  has svc && svc data enable >/dev/null 2>&1 ;;
  esac
  return 0
}

snapshot_wifi_off() { snap_kv @global:wifi_on @global:wifi_scan_always_enabled; }
# What the probe should look at for this option.
#
# The snapshot above is a settings reading, and switching a radio does not always
# change the setting - so a probe comparing only settings would call a radio
# switch that worked "inert". These lines are appended to the probe's reading of
# this knob, so the verdict is about the thing that actually moves.
probe_wifi_off() { printf 'radio:wifi\t%s\n' "$(radio_enabled wifi || echo unknown)"; }
apply_wifi_off() {
  radio_remember wifi || { log "skip wifi: its state could not be read, so it is not ours to change"; return 0; }
  radio_set wifi off
}
restore_wifi_off() {
  restore_kv "$1" "$2"
  case "$(radio_was wifi)" in
    true) radio_set wifi on ;;
  esac
  radio_forget wifi
}

meta_bt_off() {
  echo "Radio|Turn off Bluetooth|Bluetooth switches off while the mode is on.|1|session|battery"
}
snapshot_bt_off() { snap_kv @global:bluetooth_on; }
probe_bt_off() { printf 'radio:bluetooth\t%s\n' "$(radio_enabled bt || echo unknown)"; }
apply_bt_off() {
  radio_remember bt || { log "skip bluetooth: its state could not be read, so it is not ours to change"; return 0; }
  radio_set bt off
}
restore_bt_off() {
  restore_kv "$1" "$2"
  case "$(radio_was bt)" in
    true) radio_set bt on ;;
  esac
  radio_forget bt
}

meta_nfc_off() {
  echo "Radio|Turn off NFC|NFC switches off while the mode is on. Tap-to-pay will not work.|1|session|battery"
}
snapshot_nfc_off() { snap_kv @global:nfc_on; }
probe_nfc_off() { printf 'radio:nfc\t%s\n' "$(radio_enabled nfc || echo unknown)"; }
apply_nfc_off() {
  radio_remember nfc || { log "skip nfc: its state could not be read, so it is not ours to change"; return 0; }
  radio_set nfc off
}
restore_nfc_off() {
  restore_kv "$1" "$2"
  case "$(radio_was nfc)" in
    true) radio_set nfc on ;;
  esac
  radio_forget nfc
}

meta_scan_always_off() {
  echo "Radio|Stop background scanning|Stops apps scanning for Wi-Fi and Bluetooth devices behind your back.|1|session|battery"
}
snapshot_scan_always_off() {
  snap_kv @global:wifi_scan_always_enabled @global:ble_scan_always_enabled @global:network_recommendations_enabled
}
apply_scan_always_off() {
  apply_kv "@global:wifi_scan_always_enabled=0" "@global:ble_scan_always_enabled=0" "@global:network_recommendations_enabled=0"
  has cmd && cmd wifi set-scan-always-available disabled >/dev/null 2>&1
}
restore_scan_always_off() { restore_kv "$1" "$2"; }

meta_location_off() {
  echo "Radio|Turn off location|Location switches off while the mode is on. Maps, weather and navigation will not update until you turn it off again.|0|session|breaks-features"
}
snapshot_location_off() { snap_kv @secure:location_mode @secure:location_providers_allowed; }
probe_location_off() { printf 'location:enabled\t%s\n' "$(location_enabled_now || echo unknown)"; }
# The location switch is not a setting. `cmd location set-location-enabled` does
# not appear in `settings get` at all, so there is nothing in the journal to
# compare it against - and the first version of this knob decided how to turn it
# back on from secure location_mode, which THIS PHONE REFUSES TO READ. The result
# was in the log: location was switched off, nothing could prove it had been, and
# the exit reported a value it could not restore. A change whose reversal depends
# on a value that cannot be read is exactly the change that must never be made.
#
# So the real state is asked of the power manager's own command and written down
# before anything is switched. If it cannot be read, location is left alone.
LOC_STATE="$ORIG_DIR/location_enabled.tsv"

location_enabled_now() { # prints true|false, or nothing
  has cmd || return 1
  _r=$(cmd location is-location-enabled 2>/dev/null | tr -d '\r' | head -1)
  case "$_r" in
    true|false) printf '%s' "$_r" ;;
    *) return 1 ;;
  esac
}

apply_location_off() {
  if [ ! -f "$LOC_STATE" ]; then
    _cur=$(location_enabled_now) || {
      log "skip location: its state could not be read, so it is not ours to change"
      return 0
    }
    printf '%s\n' "$_cur" > "$LOC_STATE" 2>/dev/null
  fi
  apply_kv "@secure:location_mode=0"
  has cmd && cmd location set-location-enabled false >/dev/null 2>&1
}
restore_location_off() {
  restore_kv "$1" "$2"
  _was=$(cat "$LOC_STATE" 2>/dev/null)
  rm -f "$LOC_STATE"
  # Only a location we switched off ourselves is switched back on. If it was
  # already off when the mode started, that was the user's own choice and stays.
  case "$_was" in
    true) has cmd && cmd location set-location-enabled true >/dev/null 2>&1 ;;
  esac
}

# ============================================================ Processor / GPU

meta_cpu_cap() {
  echo "Processor|Limit the processor while asleep|Lowers the processor's top speed while the screen is off. Nothing is switched off, so the phone still wakes instantly.|1|deep|battery"
}
# /proc/cpufreq/cpufreq_power_mode is written with a number and answers with a
# sentence: write 1 and it reads "Low Power mode", write 0 and it reads
# "Default(Normal) mode". The journal used to record the sentence, so the exit
# wrote "Default(Normal) mode" into a node that only accepts a number. The write
# failed, the phone stayed in Low Power mode, and the exit then ran its safety
# pass - 59 seconds, in the v3.0.12 log on this phone:
#   want [Default(Normal) mode] got [Low Power mode]
# The journal now holds the token, and a reading we cannot map is left alone.
PWRMODE=/proc/cpufreq/cpufreq_power_mode
pwr_mode_token() { # what the node says -> the number it is written with, or nothing
  case "$1" in
    *"Low Power mode"*)       echo 1 ;;
    *"Default(Normal) mode"*) echo 0 ;;
    # A bare number is the node answering before it has translated the state into
    # words (the test double does exactly this). Accepting both keeps the module
    # and the tests describing the same node.
    1) echo 1 ;;
    0) echo 0 ;;
    *) echo "" ;;
  esac
}
pwr_mode_now() { pwr_mode_token "$(rd "$PWRMODE")"; }

# Leave Low Power mode and make sure it actually happened.
#
# The write is not synchronously reflected by this kernel: v3.1.0 wrote 0 and
# read 1 back in the same breath, which is either a refusal or a state that
# settles a moment later. So: write, give it a moment, read, and try again - and
# report honestly whether the phone is back in its normal mode, rather than
# claiming a value we did not achieve.
set_power_mode() { # set_power_mode <0|1>
  _want=$1
  case "$_want" in 0|1) ;; *) return 2 ;; esac
  # Six tries, four tenths of a second apart: the phone was measured taking
  # about a second to show that it had left Low Power mode, and a check that
  # read sooner than that reported a change that had in fact worked. The wait is
  # the whole budget - the loop leaves the moment the node agrees - so a phone
  # that answers at once is not made to wait at all.
  _i=0
  while [ "$_i" -lt 6 ]; do
    w "$_want" "$PWRMODE"
    sleep 0.4 2>/dev/null || :
    [ "$(pwr_mode_now)" = "$_want" ] && return 0
    _i=$((_i + 1))
  done
  return 1
}
release_power_mode() { set_power_mode 0; }

# ==================================================== the power-save governor
#
# The owner's own words: "if you change the governor to powersave then no need to
# change frequency of cpu cores which may reduce time, because its managed by the
# powersave governor."
#
# He is right, and he proved it on the phone himself, in both directions:
#   echo powersave > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
#   echo schedutil > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
# `powersave` holds every core at the lowest frequency there is, continuously and
# inside the kernel; a ceiling written by hand says the same thing once, from
# outside, and costs a blocking write per cluster while the screen is off. So
# while the screen is off the governor is the lever, and the ceiling is left to
# it (see apply_cpu_cap).
meta_gov_powersave() {
  echo "Processor|Power-save governor while idle|While the screen is off, the kernel's own power-save governor runs the processor at its lowest frequency, instead of this module writing a frequency ceiling by hand. The same saving, held continuously by the kernel, and several fewer writes while the screen is off. Confirmed on this phone: both the switch to power-save and the switch back take effect on every cluster.|1|deep|battery"
}
# One governor path per cluster, by the path the owner's own command used:
#   for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo powersave > "$cpu/cpufreq/scaling_governor"; done
#
# The policy paths are not the same set on every kernel. On this phone one policy
# has no scaling_governor node at all, and the v3.5.0 log is what that looked
# like: "power-save on 1 of 2 cluster(s)", with the big cluster left on schedutil
# and the ceiling skipped for the whole phone. `related_cpus` names the cores a
# node drives, so each cluster is named once - on the path that is known to work
# on the phone in question, with the policy nodes as the fallback for kernels
# that only expose those.
gov_glob() { # gov_glob <rooted governor paths...>
  _seen=''
  for _p in "$@"; do
    [ -e "$_p" ] || continue
    _dir=${_p%/scaling_governor}
    _rel=$(cat "$_dir/related_cpus" 2>/dev/null | tr -d '\r')
    [ -n "$_rel" ] || _rel=$(cat "$_dir/affected_cpus" 2>/dev/null | tr -d '\r')
    if [ -n "$_rel" ]; then
      case " $_seen " in
        *" $_rel "*) continue ;;
      esac
      _seen="$_seen $_rel"
    fi
    printf '%s\n' "${_p#"$SPSM_ROOT"}"
  done
}
gov_paths() {
  _out=$(gov_glob "$SPSM_ROOT"/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
  [ -n "$_out" ] || _out=$(gov_glob "$SPSM_ROOT"/sys/devices/system/cpu/cpufreq/policy*/scaling_governor)
  [ -n "$_out" ] && printf '%s\n' "$_out"
}

snapshot_gov_powersave() {
  # shellcheck disable=SC2046
  [ -n "$(gov_paths)" ] && snap_kv $(gov_paths)
}
apply_gov_powersave() {
  _took=0
  _seen=0
  for _f in $(gov_paths); do
    _seen=$((_seen + 1))
    _cur=$(rd "$_f")
    case "$_cur" in
      '') ;;                     # unreadable: not ours to change
      powersave) _took=$((_took + 1)) ;;
      *)
        w powersave "$_f"
        # Read back: a write the kernel accepted and ignored is not a change.
        [ "$(rd "$_f")" = powersave ] && _took=$((_took + 1))
        ;;
    esac
  done
  if [ "$_seen" = 0 ]; then
    log "governor: this phone exposes no power-save governor node"
    return 2
  fi
  log "governor: power-save on $_took of $_seen cluster(s)"
  [ "$_took" = 0 ] && { log "governor: this phone did not accept the power-save governor"; return 2; }
  [ "$_took" = "$_seen" ] || log "governor: the other $((_seen - _took)) cluster(s) keep the frequency ceiling"
  # WHY a cluster refused is worth one line, because the answer decides what to
  # try next and this phone has now refused the same cluster twice. Two things
  # are asked, both read-only: what governors the kernel says it offers at all,
  # and whether MediaTek's own Low Power mode (a separate option, and one this
  # mode turns on by default) is engaged - a vendor power mode is exactly the
  # kind of thing that pins a cluster's governor.
  if [ "$_took" != "$_seen" ] && [ "$_seen" != 0 ]; then
    for _f in $(gov_paths); do
      [ "$(rd "$_f")" = powersave ] && continue
      _av=$(rd "${_f%/*}/scaling_available_governors")
      _node=${_f%/*}; _node=${_node%/*}; _node=${_node##*/}
      [ -n "$_av" ] && log "governor: $_node offers only: $_av"
      if [ "$(pwr_mode_now)" = 1 ]; then
        log "governor: MediaTek's Low Power mode is on and may be what holds $_node; switching that option off lets the governor try instead"
      fi
      break
    done
  fi
  return 0
}
restore_gov_powersave() { restore_kv "$1" "$2"; }
note_gov_powersave() {
  _any=0
  _ps=0
  for _f in $(gov_paths); do
    _any=1
    [ "$(rd "$_f")" = powersave ] && _ps=$((_ps + 1))
  done
  case "$_any$_ps" in
    00) printf 'this phone exposes no governor node to set\n' ;;
    *0) printf 'this phone refused the power-save governor, the frequency keeps its ceiling\n' ;;
    *)  printf 'the governor was already power-save\n' ;;
  esac
}

# Only the frequency ceilings. The governor is its own option (gov_powersave):
# two knobs recording the same file is how a revert ends up writing the wrong
# value back, because the second snapshot records the first knob's change as if
# it were the user's.
snapshot_cpu_cap() {
  snap_kv /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq \
          /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
}
apply_cpu_cap() {
  # Per cluster, not per phone. A cluster whose governor is power-save is already
  # held at the lowest frequency there is by the kernel, so no ceiling is written
  # for it - but a cluster that did NOT take the governor is exactly the cluster
  # the ceiling is for. v3.5.0 asked only the little cluster: on this phone that
  # read "powersave" (the phone's own Low Power mode had already set it), so the
  # ceiling was skipped for the whole phone and the big cluster, which had kept
  # schedutil, was left with no idle limit at all.
  _skipped=0
  _wrote=0
  for _p in 0 6; do
    _d=/sys/devices/system/cpu/cpufreq/policy$_p
    [ -d "$(rp "$_d")" ] || continue
    if [ "$(rd "$_d/scaling_governor")" = powersave ]; then
      _skipped=$((_skipped + 1))
      continue
    fi
    _max=$(rd "$_d/cpuinfo_max_freq")
    [ -n "$_max" ] || _max=$(rd "$_d/scaling_max_freq")
    case "$_p" in
      0) _target=$(cfg cpu_little_cap_khz 1100000) ;;
      6) _target=$(cfg cpu_big_cap_khz 1300000) ;;
    esac
    # Only ever lower the ceiling, never raise it.
    if [ -n "$_max" ] && [ "$_target" -gt "$_max" ] 2>/dev/null; then
      _target=$_max
    fi
    w "$_target" "$_d/scaling_max_freq"
    _wrote=$((_wrote + 1))
  done
  if [ "$_skipped" != 0 ] && [ "$_wrote" = 0 ]; then
    log "cpu_cap: the power-save governor holds the frequency - no ceiling written"
  elif [ "$_skipped" != 0 ]; then
    log "cpu_cap: ceiling written for the $_wrote cluster(s) the governor did not take"
  fi

  # MediaTek's Low Power mode is deliberately NOT set here any more.
  #
  # v3.1.0 recorded the value in the form the node is written with, which fixed
  # the journal - the exit then wrote 0 in the right form, and the node still
  # read 1 afterwards:
  #   WARN cpu_cap did not return: /proc/cpufreq/cpufreq_power_mode: want [0] got [1]
  # Entering a state this phone has not accepted leaving is exactly the kind of
  # change that must never be made: the phone comes out of the mode slower than
  # it went in. So we do not enter it, and instead put the phone back to its
  # normal power mode if an earlier version left it in Low Power mode.
  # The CPU power mode is not touched here any more. It has its own option
  # (mtk_low_power): it is a lever in its own right for saving power WHILE the
  # screen is on, and a state this important deserves its own switch rather than
  # riding along with a frequency ceiling.
}
restore_cpu_cap() { restore_kv "$1" "$2"; }

# Extra evidence for the probe: the snapshot records the token the node is
# written with, and this records the sentence it answers with, so the report
# shows both sides of the same knob. Read-only - a probe must not change the
# phone to find out what it does.
probe_cpu_cap() {
  printf 'power_mode\t%s\n' "$(rd "$PWRMODE")"
}

# The MediaTek power mode, as its own option.
#
# This is the in-use lever on this chip: engaged, the kernel runs the phone in
# its low-power state for as long as the mode is on, not only while the screen is
# off. It is also the state the exit used to fail to leave, so the whole path is
# written carefully: the value is recorded as the token the node is written with,
# entering it is verified, leaving it is verified and retried, and a state we
# cannot read is never written at all.
meta_mtk_low_power() {
  echo "Power|Keep the processor in Low Power mode|Runs the phone in its own low-power processor state for as long as the mode is on, not only while the screen is off. The biggest saving while you are actually using the phone. It feels slower, and it can be switched off on its own without affecting anything else.|1|session|perf,battery"
}
snapshot_mtk_low_power() {
  _m=$(pwr_mode_now)
  # A state we cannot read is a state we must not change: (MISSING) makes
  # apply_kv refuse to write it, here and on exit.
  [ -n "$_m" ] || _m='(MISSING)'
  printf '%s\t%s\n' "$PWRMODE" "$(enc_val "$_m")"
}
apply_mtk_low_power() {
  [ -e "$(rp "$PWRMODE")" ] || return 0
  case "$(pwr_mode_now)" in
    1) return 0 ;;                # already there: nothing to change, nothing to claim
    0) ;;
    *) log "skip $PWRMODE: it does not read as a state we can put back"; return 0 ;;
  esac
  if set_power_mode 1; then
    log "cpu low power mode engaged"
  else
    log "NOTE this phone did not accept Low Power mode; leaving it as it is"
  fi
  return 0
}
restore_mtk_low_power() {
  _want=$(snap_file_val "$1" "$PWRMODE")
  restore_kv "$1" "$2"
  # Then confirm it settled: the read-back is the only proof on this kernel.
  case "$_want" in
    0|1)
      if set_power_mode "$_want"; then
        # A line in the log, not silence: this is the state the whole exit used
        # to get stuck on, and "the power mode really is back where it started"
        # is the first thing to look for in a log from the phone.
        log "cpu low power mode released to its original state ($_want)"
      else
        log "NOTE this phone did not accept leaving Low Power mode; a reboot clears it"
      fi
      ;;
  esac
  return 0
}
probe_mtk_low_power() { printf 'power_mode\t%s\n' "$(rd "$PWRMODE")"; }

# Window blur is drawn by the graphics chip every frame, behind panels and the
# notification shade. Removing it costs nothing on a black, plain interface and
# gives the chip less to do on every frame - a saving while the phone is in use,
# not while it sleeps.
# On by default since v3.3.1, at the owner's direction, in a mode whose purpose
# is to save everything it can while the phone is in use. It is the one option
# here that changes how the interface looks, so its description says so and the
# switch takes it straight back.
meta_blur_off() {
  echo "Display|Turn off window blur|Stops the graphics chip redrawing blurred panels behind the interface - a saving on every frame while you use the phone. The screen looks plainer; switch this off to get the blur back.|1|session|perf"
}
snapshot_blur_off() { snap_kv @global:disable_window_blurs; }
apply_blur_off() { sput global disable_window_blurs 1; }
restore_blur_off() { restore_kv "$1" "$2"; }
probe_blur_off() { printf 'blurs_disabled\t%s\n' "$(sget global disable_window_blurs 2>/dev/null || echo unset)"; }

# The status bar, from the system's side.
#
# The app no longer asks for full screen (that was the theme's
# android:windowFullscreen, and it is gone), but a status bar can also be hidden
# from outside the app: Android keeps a global immersive-mode rule in
# Settings.Global.policy_control, and a ROM or a tuning app that once wrote
# "immersive.full=*" there keeps every screen full screen, whatever the app asks
# for. That is invisible in the app's own log, so this option exists to make it
# visible and fixable: the value is looked up, cleared for the duration of the
# mode and put back afterwards. On a phone with no such rule this option has
# nothing to do, and the probe says exactly that rather than pretending.
meta_statusbar_on() {
  echo "Display|Keep the status bar visible|Some ROMs hide the status bar with an immersive-mode rule (policy_control). This clears that rule while the mode is on and puts it back on exit, so the clock, the battery and the way back stay where they belong.|1|session|core"
}
snapshot_statusbar_on() { snap_kv @global:policy_control; }
apply_statusbar_on() { apply_kv "@global:policy_control=null"; }
restore_statusbar_on() { restore_kv "$1" "$2"; }
probe_statusbar_on() {
  _v=$(sget global policy_control 2>/dev/null)
  case "$_v" in
    ''|null) printf 'policy_control\tunset - this phone keeps the status bar visible\n' ;;
    *)       printf 'policy_control\t%s\n' "$_v" ;;
  esac
}

# ------------------------------------------------------------------- recents
# The recents screen the phone's own launcher provides, switched off for the
# session.
#
# The owner's report: swiping up (or going home from an app) kept starting the
# launcher and showing its wallpaper, over and over, in a mode whose whole point
# is not to run the launcher. The recents screen is not the launcher's home
# activity - it is its own component, and this ROM names it in the task dump:
#
#   mRecentsComponent=ComponentInfo{com.android.launcher3/com.android.quickstep.RecentsActivity}
#
# Component on/off state is exact, per-user and reversible, and it is the only
# lever that stops the system STARTING it - which is what was happening. The
# reading is taken before anything is written, the write is verified against a
# read-back, and the recorded state is put back on exit. A phone whose recents
# screen cannot be read is left completely alone: an unreadable value is never
# written, and an unverifiable change is never made.
host_recents_component() {
  if type recents_component >/dev/null 2>&1; then
    recents_component
    return
  fi
  # Standing on its own (an option list built without the engine): the same
  # reading, from the same dump.
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

# What the phone says the component's own on/off setting is: default, enabled,
# disabled, disabled-user or disabled-until-used. Empty means "no reading" - the
# command may not exist on this ROM, and then the package dump is asked instead.
component_setting() { # component_setting <pkg/component>
  _c=$1
  case "$_c" in */*) ;; *) return 0 ;; esac
  _out=$(cmd package get-component-enabled-setting "$_c" 2>/dev/null | tail -1)
  case "$_out" in
    *EFAULT*|*efault*)                     printf 'default'; return 0 ;;
    *ISABLED_UNTIL_USED*|*isabled-until-used*) printf 'disabled-until-used'; return 0 ;;
    *ISABLED_USER*|*isabled-user*)         printf 'disabled-user'; return 0 ;;
    *ISABLED*|*isabled*)                   printf 'disabled'; return 0 ;;
    *ENABLED*|*nabled*)                    printf 'enabled'; return 0 ;;
    *[0-9]*)
      # A bare number is the PackageManager constant: 0 default, 1 enabled,
      # 2 disabled, 3 disabled-user, 4 disabled-until-used. The last number on
      # the line is the value.
      case "$(printf '%s' "$_out" | grep -o '[0-9]' | tail -1)" in
        0) printf 'default' ;;
        1) printf 'enabled' ;;
        2) printf 'disabled' ;;
        3) printf 'disabled-user' ;;
        4) printf 'disabled-until-used' ;;
      esac
      return 0 ;;
  esac
  # No usable answer from that command. The package dump lists components that
  # were switched off by setting; anything else is at its manifest default.
  _d=$(dumpsys package "${_c%%/*}" 2>/dev/null)
  case "$_d" in
    *"disabled"*"$_c"*) printf 'disabled' ; return 0 ;;
    *"enabled"*"$_c"*)  printf 'enabled' ; return 0 ;;
  esac
  printf 'default'
}

# Set it, in whichever form this ROM accepts, and say whether it worked.
component_set() { # component_set <pkg/component> <default|enabled|disabled>
  _c=$1
  _v=$2
  case "$_c" in */*) ;; *) return 1 ;; esac
  if cmd package set-component-enabled-setting --user 0 "$_c" "$_v" >/dev/null 2>&1; then return 0; fi
  if cmd package set-component-enabled-setting "$_c" "$_v" >/dev/null 2>&1; then return 0; fi
  case "$_v" in
    disabled) has pm && pm disable --user 0 "$_c" >/dev/null 2>&1 && return 0 ;;
    *)        has pm && pm enable  --user 0 "$_c" >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

meta_host_recents_off() {
  # Off by default, and this phone's own log is the reason: it does not accept the
  # switch ("this phone did not accept switching
  # com.android.launcher3/com.android.quickstep.RecentsActivity off"), so every
  # activation spent seconds asking for something it then had to undo. The option
  # stays - other ROMs do accept it - but nothing asks for it by default.
  echo "Display|Switch the launcher's recents off|The phone's own recents belong to the launcher: swiping up starts it and draws its screen over whatever you were doing. This switches that screen off for as long as the mode is on, and puts its setting back on exit. This phone does not accept the switch (see the log), so it is off by default.|0|session|core"
}
snapshot_host_recents_off() {
  _c=$(host_recents_component)
  printf 'recents\t%s\n' "$(enc_val "$_c")"
  printf 'setting\t%s\n' "$(enc_val "$(component_setting "$_c")")"
}
apply_host_recents_off() {
  _c=$(host_recents_component)
  case "$_c" in
    ''|none|*' '*) log "host recents: this phone does not name a recents screen"; return 2 ;;
  esac
  case "${_c%%/*}" in
    dev.axion.spsm) return 0 ;;      # already ours: nothing to switch off
  esac
  _cur=$(component_setting "$_c")
  case "$_cur" in
    '') log "host recents: $_c cannot be read, so it is left alone"; return 2 ;;
    disabled*) return 0 ;;           # switched off by someone else: their choice
  esac
  component_set "$_c" disabled
  if [ "$(component_setting "$_c")" = "disabled" ] || [ "$(component_setting "$_c")" = "disabled-user" ]; then
    log "host recents: $_c switched off for this session"
    return 0
  fi
  log "host recents: this phone did not accept switching $_c off"
  return 2
}
restore_host_recents_off() {
  _want=$(snap_file_val "$1" setting)
  _c=$(snap_file_val "$1" recents)
  [ -n "$_c" ] || _c=$(host_recents_component)
  case "$_c" in ''|*' ') return 0 ;; esac
  case "$_want" in
    ''|disabled*)
      # It was already off before us, so there is nothing of ours to put back.
      return 0 ;;
  esac
  # Only if it is still switched off by us: a user who switched it back on
  # themselves has said what they want.
  case "$(component_setting "$_c")" in
    disabled*) ;;
    *) return 0 ;;
  esac
  component_set "$_c" "$_want"
  case "$(component_setting "$_c")" in
    disabled*) log "host recents: $_c did not come back on; a reboot restores it" ;;
  esac
  return 0
}
probe_host_recents_off() {
  _c=$(host_recents_component)
  case "$_c" in
    '') printf 'recents_screen\tthis phone does not name its recents screen\n' ;;
    *)  printf 'recents_screen\t%s (%s)\n' "$_c" "$(component_setting "$_c")" ;;
  esac
}

meta_cpu_offline_big() {
  echo "Processor|Switch off the big cores|Two of the eight processor cores are switched off completely. Saves the most, but the phone feels slower if something wakes it.|0|deep|experimental"
}
snapshot_cpu_offline_big() {
  snap_kv /sys/devices/system/cpu/cpu6/online /sys/devices/system/cpu/cpu7/online
}
apply_cpu_offline_big() {
  # Only write to a core that is on. Offlining is a blocking request the kernel
  # finishes when it can, and the v3.4.1 log shows it taking 23s and then 52s on a
  # phone that was busy at the time - while a core that is already off needs no
  # request at all. The deep phase runs again on every screen-off, so re-asking
  # for something that is already true was most of that wait.
  _did=0
  for _c in 7 6; do
    _f=/sys/devices/system/cpu/cpu$_c/online
    [ -e "$(rp "$_f")" ] || continue
    [ "$(rd "$_f")" = 0 ] && continue
    w 0 "$_f" && _did=$((_did + 1))
  done
  [ "$_did" = 0 ] && log "cpu_offline_big: the big cores are already off"
  return 0
}
restore_cpu_offline_big() {
  # Faithful restore: whatever the cores were doing before SPSM is what they
  # should be doing after. engine.sh's verify catches it if that fails.
  restore_kv "$1" "$2"
}

meta_gpu_cap() {
  echo "Processor|Limit graphics while asleep|Keeps the graphics chip at its lowest speed while the screen is off.|1|deep|battery"
}
# The GPU step ceiling is set two ways on this kernel: the two MediaTek tuning
# nodes, which read back what was written, and /proc/gpufreq/gpufreq_opp_freq,
# which does not - it is a control node that answers with a sentence about the
# lock, and that sentence changes when the lock is set. Recording it as a value
# meant the exit could never match what it had written, and the device log shows
# what came of that: a GPU left pinned to its lowest step after the mode was
# switched off. So it is written to lock, and released explicitly on the way out.
GPU_OPP=/proc/gpufreq/gpufreq_opp_freq
snapshot_gpu_cap() {
  snap_kv $GED_PARAMS/gpu_cust_upbound_freq \
          $GED_PARAMS/gpu_bottom_freq \
          $GED_PARAMS/gpu_dvfs_enable
}
apply_gpu_cap() {
  _g=$(cfg gpu_cap_khz 300000)
  w "$_g" $GED_PARAMS/gpu_cust_upbound_freq
  w "$_g" $GED_PARAMS/gpu_bottom_freq
  w "$_g" "$GPU_OPP"
}
restore_gpu_cap() {
  restore_kv "$1" "$2"
  # 0 is "do not hold the GPU at one step" on this phone's kernel.
  [ -e "$(rp "$GPU_OPP")" ] && w 0 "$GPU_OPP"
  return 0
}
probe_gpu_cap() {
  printf 'gpu_ceiling\t%s\n' "$(rd $GED_PARAMS/gpu_cust_upbound_freq)"
}

meta_ged_boost_off() {
  echo "Processor|Stop performance boosts|Stops the phone raising processor and graphics speeds for touches and scrolling while the screen is off.|1|deep|battery"
}
snapshot_ged_boost_off() {
  snap_kv $GED_PARAMS/enable_cpu_boost $GED_PARAMS/enable_gpu_boost \
          $GED_PARAMS/ged_boost_enable $GED_PARAMS/is_GED_KPI_enabled
}
apply_ged_boost_off() {
  apply_kv "$GED_PARAMS/enable_cpu_boost=0" "$GED_PARAMS/enable_gpu_boost=0" "$GED_PARAMS/ged_boost_enable=0"
}
restore_ged_boost_off() { restore_kv "$1" "$2"; }

# ============================================================ Apps

meta_app_restrict() {
  echo "Apps|Restrict background apps|While the screen is off, apps outside your six slots are allowed less background work. Their notifications may arrive late.|1|deep|battery"
}
snapshot_app_restrict() {
  # Snapshot is just the set of packages we manage: if that set still matches
  # on restore, our per-app values are still the ones in the sub-journal.
  echo "$(managed_packages | tr '\n' ' ')"
}
apply_app_restrict() {
  _bucket=$(cfg bucket_level restricted)
  case "$_bucket" in restricted|rare|frequent) ;; *) _bucket=restricted ;; esac
  _list="$ORIG_DIR/app_restrict.tsv"
  # The deep phase is applied again on every screen-off cycle, and re-applying
  # over a record of our own making would save our value as if it were the
  # user's - leaving every app restricted after the mode is switched off. The
  # record is written once per idle period; releasing the phase clears it.
  [ -f "$_list" ] || : > "$_list"
  _known=" $(cut -f1 "$_list" 2>/dev/null | tr '\n' ' ') "
  # Each app costs four commands (two reads, two writes) and there are a dozen of
  # them: one after another that was measured at 86-89 seconds in the v3.4.1 log,
  # in every single screen-off period. They run together now, and the records are
  # collected afterwards so the file is built the same way and in the same order
  # as before.
  _d=$SPSM_DIR/.tmp
  mkdir -p "$_d" 2>/dev/null
  _r="$_d/restrict.$$"
  : > "$_r"
  managed_packages > "$_d/restrict.pkgs.$$" 2>/dev/null
  while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    (
      _ob=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
      [ -n "$_ob" ] || _ob=-
      _oo=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
            | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
      [ -n "$_oo" ] || _oo=-
      [ "$_ob" = "-" ] && [ "$_oo" = "-" ] && exit 0
      printf '%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_oo" "$_bucket" >> "$_r"
      [ "$_ob" != "-" ] && am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
      [ "$_oo" != "-" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
    ) &
  done < "$_d/restrict.pkgs.$$"
  wait
  rm -f "$_d/restrict.pkgs.$$"
  # One writer, in a stable order. Only the first sighting of a package in this
  # idle period is a record of what it looked like before we touched it.
  sort -u "$_r" 2>/dev/null | while IFS="$(printf '\t')" read -r _pkg _ob _oo _b; do
    [ -n "$_pkg" ] || continue
    case "$_known" in
      *" $_pkg "*) ;;
      *) printf '%s\t%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_b" "$_oo" "deny" >> "$_list" ;;
    esac
  done
  rm -f "$_r"
}
restore_app_restrict() {
  _list="$ORIG_DIR/app_restrict.tsv"
  [ -f "$_list" ] || return 0
  # Every app here costs two reads and up to two writes, and on the way out they
  # ran one app after another - eight seconds of the exit in the v3.6.0 log for a
  # dozen apps, and it is the same work the apply already does together. The
  # reads and the writes for one app stay in order; the apps themselves do not
  # wait for each other.
  while IFS=$TAB read -r _pkg _ob _nb _oo _no || [ -n "$_pkg" ]; do
    [ -n "$_pkg" ] || continue
    (
      if [ "$_ob" != "-" ]; then
        _now=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
        # Only undo our own change: if the system or the user moved it since,
        # that newer decision wins.
        [ "$_now" = "$_nb" ] && am set-standby-bucket "$_pkg" "$_ob" >/dev/null 2>&1
      fi
      if [ "$_oo" != "-" ]; then
        _now=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
               | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
        [ "$_now" = "$_no" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND "$_oo" >/dev/null 2>&1
      fi
    ) &
  done < "$_list"
  wait
  # The idle period is over: the next one starts from whatever the phone looks
  # like then, not from this record.
  rm -f "$_list"
}

meta_freeze_google() {
  echo "Apps|Pause Google services|Pauses Play Services, the Play Store and Search while the mode is on. Apps that rely on them will not get notifications until you turn the mode off.|0|deep|breaks-features"
}
# The Google packages this option may pause. On the phone this was written for,
# Play Services is not installed at all - it runs ReVanced GMS - so the fixed
# list did nothing there. The base names are kept, and whatever is installed
# that provides GMS is added, so the option does what it says on a phone whose
# Google services have been replaced as well as on a normal one.
GOOGLE_PKGS_BASE="com.google.android.gms com.google.android.gsf com.android.vending com.google.android.googlequicksearchbox com.google.android.gms.location.history"
GOOGLE_PKGS_VARIANTS="app.revanced.android.gms app.morphe.android.gms com.microg.gms com.microg.gms.droidguard"
google_packages() {
  printf '%s\n' $GOOGLE_PKGS_BASE
  for _p in $GOOGLE_PKGS_VARIANTS; do
    has pm || continue
    pm list packages "$_p" 2>/dev/null | grep -q "^package:$_p$" && printf '%s\n' "$_p"
  done
}
# Play Services is suspended, not disabled, so its `enabled` state does not move
# - the probe has to look at the suspension itself.
probe_freeze_google() {
  _any=0
  for _p in $(google_packages); do
    has dumpsys || break
    _o=$(dumpsys package "$_p" 2>/dev/null)
    [ -n "$_o" ] || continue
    _s=$(printf '%s\n' "$_o" | sed -n 's/^[[:space:]]*suspended=\([a-z]*\).*/\1/p' | head -1)
    [ -n "$_s" ] || _s=unknown
    printf 'suspended:%s\t%s\n' "$_p" "$_s"
    _any=$((_any + 1))
  done
  [ "$_any" = "0" ] && printf 'google:none\tno Google services are installed on this phone\n'
  return 0
}
snapshot_freeze_google() {
  _f="$ORIG_DIR/google_state.tsv"
  : > "$_f"
  for _p in $(google_packages); do
    _en=$(dumpsys package "$_p" 2>/dev/null | sed -n 's/^ *enabled=\([a-z]*\).*/\1/p' | head -1)
    [ -n "$_en" ] || continue
    printf '%s\t%s\n' "$_p" "$_en" >> "$_f"
    printf '%s\t%s\n' "$_p" "$_en"
  done
}
apply_freeze_google() {
  # Together: these are the slowest single calls on the phone.
  for _p in $(google_packages); do
    ( pm suspend "$_p" >/dev/null 2>&1
      am force-stop "$_p" >/dev/null 2>&1 ) &
  done
  wait
}
restore_freeze_google() {
  restore_kv "$1" "$2"
  for _p in $(google_packages); do
    # Unsuspending always: suspending is the change we make, and leaving one
    # behind would keep an app dead until the next reboot.
    #
    # Enabling is only right for a package that was enabled before we touched
    # it. A Play Store somebody disabled on purpose must not come back to life
    # because the mode was switched off - which is why the decision is read from
    # the snapshot here, before the work is handed to the background.
    _st=$(awk -F'\t' -v p="$_p" '$1==p{print $2; exit}' "$1" 2>/dev/null)
    case "$_st" in
      disabled*) ( pm unsuspend "$_p" >/dev/null 2>&1 ) & ;;
      *) ( pm unsuspend "$_p" >/dev/null 2>&1
           pm enable "$_p" >/dev/null 2>&1 ) & ;;
    esac
  done
  wait
}

# ============================================================ Doze / power

meta_deep_doze() {
  echo "Power|Deep sleep as soon as the screen is off|The phone goes into its deepest sleep immediately instead of waiting, and wakes normally when you pick it up.|1|deep|battery,breaks-features"
}
snapshot_deep_doze() {
  # Record the force flag, which is exactly what this knob changes. mState is a
  # transient the system moves on its own, so recording it makes a healthy phone
  # look broken: as soon as we let go, the state machine steps and the old value
  # never matches again. If a dump has no force flag, say so rather than record
  # something that will not hold.
  _f=$(dumpsys deviceidle 2>/dev/null | sed -n 's/.*mForceIdle=\([a-z]*\).*/\1/p' | head -1)
  printf 'deviceidle-force\t%s\n' "${_f:-unknown}"
}
apply_deep_doze() {
  # `dumpsys deviceidle force-idle deep` does not ask and return: it waits for the
  # phone to actually reach idle. The v3.4.1 log has it blocking for 245s on one
  # screen-off and 619s on another, with the rest of the idle sequence queued
  # behind it - the phone was deep asleep long before the command that asked for
  # it had finished. So it is issued in the background with a ceiling of its own,
  # and what the phone did with it is read back rather than assumed.
  touch "$STATE/doze_forced" 2>/dev/null
  ( has dumpsys && timeout 30 dumpsys deviceidle force-idle deep >/dev/null 2>&1 ) &
  _i=0
  while [ "$_i" -lt 6 ]; do
    _f=$(dumpsys deviceidle 2>/dev/null | sed -n 's/.*mForceIdle=\([a-z]*\).*/\1/p' | head -1)
    [ "$_f" = true ] && { log "deep sleep: the phone has been told to go idle now"; return 0; }
    _i=$((_i + 1))
    sleep 0.5 2>/dev/null || sleep 1
  done
  log "deep sleep: asked the phone to go idle now; it enters when it can"
  return 0
}
note_deep_doze() {
  _f=$(dumpsys deviceidle 2>/dev/null | sed -n 's/.*mForceIdle=\([a-z]*\).*/\1/p' | head -1)
  case "$_f" in
    true) printf 'the phone is going idle now\n' ;;
    false) printf 'the phone was asked to go idle; it has not gone yet (it goes when it can)\n' ;;
    *) printf 'this phone does not report its idle state\n' ;;
  esac
}
restore_deep_doze() {
  # unforce is harmless even if nothing was forced, so it always runs: leaving
  # the device stuck in forced idle would kill every notification.
  has dumpsys && dumpsys deviceidle unforce >/dev/null 2>&1
  # Stepping the state machine is a change of its own, so only do it when we are
  # the ones who forced it - otherwise this knob would nudge the power state of
  # a phone that was minding its own business.
  if [ -f "$STATE/doze_forced" ]; then
    has cmd && cmd deviceidle step >/dev/null 2>&1
  fi
  rm -f "$STATE/doze_forced"
}

meta_battery_saver() {
  echo "Power|Android battery saver|Turns on Android's own battery saver. This phone's version darkens the screen and adds little on top of SPSM.|0|session|experimental"
}
snapshot_battery_saver() { snap_kv @global:low_power @global:low_power_sticky @global:battery_saver_constants; }
apply_battery_saver() { apply_kv "@global:low_power=1" "@global:low_power_sticky=1"; }
# No extra cleanup here: if the ROM had battery_saver_constants before us it is
# in the snapshot and gets written back, and if it did not, restore_kv deletes
# it. Unconditionally deleting it threw away a setting that was never ours.
restore_battery_saver() { restore_kv "$1" "$2"; }

meta_block_other_apps() {
  echo "Apps|Block other apps|Apps that are not in your six slots are stopped and cannot be opened until you turn the mode off. They return to normal afterwards.|1|session|battery,breaks-features"
}
# A snapshot function must only READ. The engine calls it twice for every
# application - once to record the original and once to record what the change
# looks like - so a snapshot that also writes state has that state overwritten by
# its own second call. (That is exactly how the first version of this knob
# managed to record every app as "already suspended before us" and then leave
# them all suspended on exit.)
snapshot_block_other_apps() {
  blockable_packages | while read -r _p; do
    _s=0
    dumpsys package "$_p" 2>/dev/null | grep -q 'suspended=true' && _s=1
    printf '%s\t%s\n' "$_p" "$_s"
  done
}

# Which apps this session suspended, so that the exit undoes exactly those and
# nothing else. Written by the apply, read by the restore, and removed by the
# restore.
BLOCKED_BY_US="$STATE/blocked_by_us.tsv"

# Suspend every app that is not in the six slots.
#
# The per-app work runs TOGETHER rather than one app after another. Each app
# costs this phone three commands (a dumpsys read, the suspend, a force-stop),
# and there are a dozen of them: done in a row that is the better part of half a
# minute, done together it is about as long as the slowest single app. The
# results are collected and only then written down, so the journal (which one
# app was suspended by us) is still built the same way and in the same order.
apply_block_other_apps() {
  # A second application in the same session (the deep phase runs again on every
  # screen-off) must not re-record anything: the list is what we suspended, once.
  [ -f "$BLOCKED_BY_US" ] || : > "$BLOCKED_BY_US"
  _d=$SPSM_DIR/.tmp
  mkdir -p "$_d" 2>/dev/null
  _r="$_d/block.$$"
  : > "$_r"
  for _p in $(blockable_packages); do
    [ -n "$_p" ] || continue
    (
      # An app that is already suspended is somebody else's decision - the user's,
      # or another tool's. Never ours to take over, and never ours to release.
      dumpsys package "$_p" 2>/dev/null | grep -q 'suspended=true' && exit 0
      if pm suspend --user 0 "$_p" >/dev/null 2>&1 || pm suspend "$_p" >/dev/null 2>&1; then
        am force-stop "$_p" >/dev/null 2>&1
        printf '%s\n' "$_p" >> "$_r"
      fi
    ) &
  done
  wait
  # One writer, in a stable order, as before.
  sort -u "$_r" 2>/dev/null | while read -r _p; do
    [ -n "$_p" ] || continue
    grep -qxF "$_p" "$BLOCKED_BY_US" 2>/dev/null || printf '%s\n' "$_p" >> "$BLOCKED_BY_US"
  done
  rm -f "$_r"
}

restore_block_other_apps() {
  [ -f "$BLOCKED_BY_US" ] || return 0
  # Together, like the apply: releasing a dozen apps one at a time is most of a
  # slow exit.
  while read -r _p; do
    [ -n "$_p" ] || continue
    (
      # Only if it is still suspended: if something else has since had an opinion
      # about this app, that opinion wins.
      dumpsys package "$_p" 2>/dev/null | grep -q 'suspended=true' || exit 0
      pm unsuspend --user 0 "$_p" >/dev/null 2>&1 || pm unsuspend "$_p" >/dev/null 2>&1
    ) &
  done < "$BLOCKED_BY_US"
  wait
  rm -f "$BLOCKED_BY_US"
}

# What the deep phase actually did, written down at the moment it happens.
#
# The CPU caps only exist while the screen is off - that is the whole design, so
# that the phone is never slow when somebody is using it - which means that by
# the time anyone looks (a kernel manager, a settings screen) the phone is
# supposed to look normal again. That makes the caps impossible to confirm after
# the fact, so this line is the confirmation: it is logged at screen-off and
# shown by `engine.sh status` until the next one.
deep_report() {
  _c0=$(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)
  _c6=$(rd /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)
  _g=$(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)
  _d=no
  [ -f "$STATE/doze_forced" ] && _d=forced
  # Who is holding the frequency down: the kernel's governor (gov_powersave) or a
  # ceiling we wrote. Both are the idle limit being in force, and naming which one
  # it is stops this line reading like a missing cap. It says governor only when
  # every cluster this phone has is running power-save; a cluster that kept
  # schedutil is held by the ceiling written for it.
  _by=ceiling
  _n=0
  _ps=0
  for _f in $(gov_paths); do
    _n=$((_n + 1))
    [ "$(rd "$_f")" = powersave ] && _ps=$((_ps + 1))
  done
  [ "$_n" != 0 ] && [ "$_ps" = "$_n" ] && _by=governor
  printf 'little_max=%s big_max=%s governor=%s doze=%s held_by=%s\n' \
    "${_c0:--}" "${_c6:--}" "${_g:--}" "$_d" "$_by" > "$STATE/deep_report" 2>/dev/null
  log "deep applied: $(cat "$STATE/deep_report" 2>/dev/null)"
}

# ================================================== honest notes for a knob
#
# A knob whose snapshot reads the same before and after is not necessarily a knob
# that did nothing. Bluetooth and location were already off; the rotation was
# already locked; policy_control does not exist on this ROM at all. The v3.4.1 log
# said "no visible change (optional node missing?)" for every one of those, which
# reads like a fault when it is in fact the phone already being in the wanted
# state. These functions answer the question the note is really asking: what did
# this knob find?

note_bt_off() {
  case "$(sget global bluetooth_on)" in
    0) printf 'Bluetooth was already off\n' ;;
    1) printf 'Bluetooth was asked to switch off and still reports on\n' ;;
    *) printf 'this phone does not report its Bluetooth state\n' ;;
  esac
}

note_location_off() {
  case "$(location_enabled_now)" in
    false) printf 'location was already off\n' ;;
    true)  printf 'location can be switched off but this phone still reports it on\n' ;;
    *)     printf 'location was switched off through the settings that could be read\n' ;;
  esac
}

note_rotate_lock() {
  case "$(sget system accelerometer_rotation)" in
    0) printf 'screen rotation was already locked\n' ;;
    1) printf 'screen rotation is locked again through the settings\n' ;;
    *) printf 'this phone does not report the rotation setting\n' ;;
  esac
}

note_statusbar_on() {
  _v=$(sget global policy_control 2>/dev/null)
  case "$_v" in
    ''|null) printf 'this ROM sets no policy_control, so the status bar was never hidden by one\n' ;;
    *) printf 'policy_control is now %s\n' "$_v" ;;
  esac
}

note_app_restrict() {
  _n=0
  _see=0
  for _p in $(managed_packages 2>/dev/null); do
    _see=$((_see + 1))
    [ "$_see" -gt 3 ] && break
    case "$(am get-standby-bucket "$_p" 2>/dev/null | tr -d '\r')" in
      restricted|rare|frequent) _n=$((_n + 1)) ;;
    esac
  done
  if [ "$_n" -gt 0 ]; then
    printf 'the background of the apps outside your six is restricted (checked %s of them)\n' "$_n"
  else
    printf 'this phone did not report the restrictions back; they were written but cannot be confirmed\n'
  fi
}

meta_data_off() {
  echo "Network|Turn off mobile data|Mobile data switches off while the mode is on, so messages arrive only after you turn it off again.|0|session|battery,breaks-features"
}
snapshot_data_off() { snap_kv @global:mobile_data @global:mobile_data1; }
probe_data_off() { printf 'data:enabled\t%s\n' "$(radio_enabled data || echo unknown)"; }
apply_data_off() {
  radio_remember data || { log "skip mobile data: its state could not be read, so it is not ours to change"; return 0; }
  radio_set data off
}
restore_data_off() {
  restore_kv "$1" "$2"
  case "$(radio_was data)" in
    true) radio_set data on ;;
  esac
  radio_forget data
}

# On by default since v3.3.1, at the owner's direction: this is an emergency
# mode whose whole point is to stretch the battery, and the biggest in-use saving
# available is to keep the speed and graphics limits applied instead of lifting
# them every time the phone is woken. It is this mode's own switch: with it off,
# the limits apply only while the screen is off, exactly as before.
meta_cap_always() {
  echo "Performance|Keep power limits while using the phone|The processor and graphics limits stay applied the whole time, not only while the screen is off - the phone runs cooler and slower while you use it, and the battery lasts longer. Switch this off to have the limits lifted the moment you wake the phone.|1|session|perf,breaks-features,control"
}
snapshot_cap_always() { :; }
apply_cap_always() { :; }
restore_cap_always() { :; }

# The restriction shows in the standby bucket and the background app-op of the
# apps it manages, not in a snapshot of its own - so the probe asks those.
probe_app_restrict() {
  _n=0
  for _p in $(managed_packages | head -3); do
    _b=$(am get-standby-bucket "$_p" 2>/dev/null | tr -d '\r')
    _o=$(cmd appops get "$_p" RUN_ANY_IN_BACKGROUND 2>/dev/null | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
    [ -n "$_b" ] && printf 'bucket:%s\t%s\n' "$_p" "$_b"
    [ -n "$_o" ] && printf 'appop:%s\t%s\n' "$_p" "$_o"
    _n=$((_n + 1))
  done
  [ "$_n" = "0" ] && printf 'apps:none\tno app on this phone is in scope\n'
  return 0
}

meta_sync_off() {
  echo "Power|Stop account sync|Email and contacts stop syncing until you turn the mode off.|0|session|breaks-features"
}
snapshot_sync_off() { snap_kv @global:auto_sync; }
apply_sync_off() { apply_kv "@global:auto_sync=0"; }
restore_sync_off() { restore_kv "$1" "$2"; }

# ============================================================ Navigation

# The owner's instruction, verbatim: "better to completely remove the swipe to
# open recents and it's better if you shift the gesture mode to 3-button
# navigation mode, such that you have easy to implement back will back, home
# button will take to the home of spsm and recent button will open recents" -
# and then, after the first build: "i didn't told you to implement a custom three
# button navigation bar, i mean i want system own 3-button navigation bar. Also
# you custom three button navigation bar is too buggy, so remove it completely
# and then just add system one and as always while leaving return back to normal
# state."
#
# The commands below are the owner's own, verified by him on the phone:
#
#   su -c 'cmd overlay enable-exclusive --user 0 --category com.android.internal.systemui.navbar.threebutton'
#   su -c 'cmd overlay enable-exclusive --user 0 --category com.android.internal.systemui.navbar.gestural'
#
# So the bar is the system's own, switched by the system's own mechanism (the
# exclusive RRO that draws it), and this app draws nothing at all. Two things
# identify which navigation the phone is using - the enabled overlay in that
# category, and the secure setting the ROM keeps in step with it (0 three-button,
# 1 two-button, 2 gesture) - and both are recorded before the switch and put back
# on exit.
NAV_CATEGORY=com.android.internal.systemui.navbar
NAV_OVERLAY_ORIG="$ORIG_DIR/nav_overlay.orig"

# The overlay this phone has enabled in the navigation-bar category, or empty if
# the phone will not say. `cmd overlay list` prints one overlay per line with a
# [x] in front of the ones that are on; the shape was taken from this ROM. When
# the list cannot be read the setting the ROM keeps in step is used instead.
nav_overlay_current() {
  if has cmd; then
    _n=$(cmd overlay list --user 0 2>/dev/null | tr -d '\r' \
         | grep -F "$NAV_CATEGORY." | grep -F '[x]' | head -1 \
         | sed -n "s/.*\($NAV_CATEGORY\.[A-Za-z0-9._]*\).*/\1/p")
    [ -n "$_n" ] && { printf '%s' "$_n"; return 0; }
  fi
  nav_overlay_for_mode "$(sget secure navigation_mode)"
}

# The overlay that matches a navigation_mode value.
nav_overlay_for_mode() {
  case "$1" in
    0) printf '%s.threebutton' "$NAV_CATEGORY" ;;
    1) printf '%s.twobutton' "$NAV_CATEGORY" ;;
    2) printf '%s.gestural' "$NAV_CATEGORY" ;;
  esac
}

# Which navigation the phone is drawing now: three | two | gesture | ?
# The setting first (it is what the system changes when the button row changes),
# the overlay as the answer for a phone that does not keep one.
nav_now() {
  case "$(sget secure navigation_mode)" in
    0) printf 'three'; return ;;
    1) printf 'two'; return ;;
    2) printf 'gesture'; return ;;
  esac
  case "$(nav_overlay_current)" in
    "$NAV_CATEGORY.threebutton") printf 'three' ;;
    "$NAV_CATEGORY.twobutton")   printf 'two' ;;
    "$NAV_CATEGORY.gestural")    printf 'gesture' ;;
    *) printf '?' ;;
  esac
}

nav_is_three() { [ "$(nav_now)" = three ]; }

meta_nav_buttons() {
  echo "System|Three-button navigation|While the mode is on the phone itself uses three-button navigation - the system's own bar, on every screen including inside apps. Back is Back, Home comes back to this mode's home, and Recents opens this mode's own list. Your own navigation comes back when you switch the mode off.|1|session|core"
}
snapshot_nav_buttons() { snap_kv @secure:navigation_mode; }

apply_nav_buttons() {
  _was=$(sget secure navigation_mode)
  # `settings get` answers "null" for a setting the phone does not have, and the
  # journal keeps it that way so that the exit deletes it again. For the decision
  # here it is simply "the phone did not say".
  case "$_was" in null) _was='' ;; esac
  _was_overlay=$(nav_overlay_current)
  if nav_is_three; then
    log "nav: the phone already uses three-button navigation"
    return 0
  fi
  if [ -z "$_was_overlay" ] && [ -z "$_was" ]; then
    log "nav: this phone will not say which navigation it uses, so it is left alone"
    return 2
  fi
  # The original, written once per session: the first sighting is the phone's own
  # navigation, and a later screen-off must not record ours as if it were his.
  [ -f "$NAV_OVERLAY_ORIG" ] || printf '%s\n' "$_was_overlay" > "$NAV_OVERLAY_ORIG" 2>/dev/null

  # The owner's own command, and then the setting the ROM keeps in step with it.
  # Either one alone switches the bar on this phone; together they cannot
  # disagree about what the phone should be doing.
  if has cmd; then
    cmd overlay enable-exclusive --user 0 --category "$NAV_CATEGORY.threebutton" >/dev/null 2>&1
  fi
  case "$_was" in 0) ;; *) sput secure navigation_mode 0 ;; esac

  # Read back: the phone is asked what it is drawing now, not what it was told.
  _i=0
  while [ "$_i" -lt 6 ]; do
    nav_is_three && break
    sleep 0.4 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done
  if nav_is_three; then
    log "nav: the phone is on three-button navigation (was ${_was:-unknown}${_was_overlay:+, overlay $_was_overlay}) - Back is Back, Home is this home, the Recents button is this mode's list"
    return 0
  fi
  # Not taken: the phone's own navigation is put back explicitly, so a write that
  # did land cannot be left behind as a change the journal has written off.
  if [ -n "$_was_overlay" ] && has cmd; then
    cmd overlay enable-exclusive --user 0 --category "$_was_overlay" >/dev/null 2>&1
  fi
  if [ -z "$_was" ] || [ "$_was" = null ]; then sdel secure navigation_mode; else sput secure navigation_mode "$_was"; fi
  rm -f "$NAV_OVERLAY_ORIG"
  log "nav: this phone did not take three-button navigation (still ${_was:-unknown}); the system bar is left exactly as it was"
  return 2
}

restore_nav_buttons() {
  restore_kv "$1" "$2"
  # The overlay as well. On a phone where the setting and the bar are kept in
  # step, writing the setting is enough; on one where they are not, the overlay
  # is the thing that actually draws the bar - so both go back.
  if [ -f "$NAV_OVERLAY_ORIG" ]; then
    _o=$(cat "$NAV_OVERLAY_ORIG" 2>/dev/null)
    if [ -n "$_o" ] && has cmd; then
      cmd overlay enable-exclusive --user 0 --category "$_o" >/dev/null 2>&1
      log "nav: the phone's own navigation is back (overlay $_o)"
    fi
    rm -f "$NAV_OVERLAY_ORIG"
  fi
  return 0
}

# ============================================================ Memory

# The owner's report, with numbers: the mode on, 649 processes, 3.78G of 3.83G
# used, 47M free - and a chat app alone holding 490M.
#
# Suspending an app stops it being *started*; it does not give its memory back.
# Stopping it does. Three levers, all of them the phone's own:
#
#   am force-stop <pkg>     stop the app (and its processes)
#   am kill-all             stop everything the phone itself calls background
#   am make-uid-idle <pkg>  tell ActivityManager the app is idle now, so it
#                           releases what it is holding for it
#
# Nothing here changes a setting, so there is nothing to put back on exit: an
# app that was stopped is simply an app that starts again when it is next
# opened. Every package it touches is one this session already suspended.
sweep_background() { # sweep_background <why>
  _why=${1:-on}
  _before=$(mem_available)
  _n=0
  if [ -n "$SPSM_ROOT" ]; then
    # A fake phone has no processes to stop; the test reads the calls instead.
    :
  fi
  if [ -f "$BLOCKED_BY_US" ]; then
    while read -r _p; do
      [ -n "$_p" ] || continue
      _n=$((_n + 1))
      (
        am force-stop "$_p" >/dev/null 2>&1
        # A suspended app cannot have been started by the user, so telling the
        # phone it is idle is a statement of fact.
        am make-uid-idle "$_p" >/dev/null 2>&1 || am make-uid-idle --user 0 "$_p" >/dev/null 2>&1
      ) &
    done < "$BLOCKED_BY_US"
    wait
  fi
  has am && am kill-all >/dev/null 2>&1
  _after=$(mem_available)
  log "background sweep ($_why): $_n frozen app(s) stopped, free memory $(mem_words "$_before") -> $(mem_words "$_after")"
}

meta_sweep_bg() {
  echo "Memory|Hand back background memory|Apps outside your six slots are stopped outright and their memory released - suspending an app stops it starting, it does not give back the memory it already holds. Runs when the mode is switched on, and again every time the screen goes off.|1|session|battery"
}
snapshot_sweep_bg() { :; }
apply_sweep_bg() { sweep_background "mode on"; }
restore_sweep_bg() { :; }

# The ROM's own background work.
#
# The owner's question: "Axion rom put their components all around even in
# system server (a very large process). Can we do something for this."
#
# system_server itself cannot be trimmed - it is the phone's Android, and every
# app is a client of it. What CAN be done is to take away its clients: a system
# package that is working in the background is exactly what keeps Android busy.
#
# The lever is the one Settings offers per app - "Restrict background" - applied
# per package, only while the screen is off, and put back on wake:
#   * the standby bucket moves to restricted (jobs and network deferred)
#   * RUN_ANY_IN_BACKGROUND is denied (no background running)
#   * make-uid-idle puts it to sleep now
#
# Nothing is disabled and nothing is suspended: every one of these packages still
# works the moment it is opened, and no package is touched because it appears on
# a list written somewhere else - the candidates are read off THIS phone, from
# the processes that are running at the moment the screen goes off.
ROM_BG_CORE="com.android.systemui com.android.phone com.android.server.telecom
com.android.providers.telephony com.android.providers.contacts com.android.providers.media
com.android.providers.media.module com.android.providers.settings com.android.providers.downloads
com.android.settings com.android.shell com.android.permissioncontroller com.android.keychain
com.android.se com.android.bluetooth com.android.nfc com.android.wifi com.android.networkstack
com.android.networkstack.tethering com.android.tethering com.android.mtp com.android.location.fused
com.android.deskclock com.android.launcher3 com.android.webview com.android.cellbroadcastreceiver
com.android.emergency com.android.mms com.android.dialer"

rom_bg_core() { printf '%s\n' $ROM_BG_CORE; }

# The candidates, built without forking per package.
#
# The first version tested each running process with `printf | grep -q` twice, so
# every package on the phone cost three execs before anything was even decided,
# and the whole step was measured at 264 seconds off the end of an activation in
# the v3.6.0 log. The sets are turned into strings once and each candidate is
# tested against them with a shell case - no forks at all until the writes below.
rom_bg_candidates() {
  _keep=" $(cfg keep '') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') $(protected_packages | tr '\n' ' ') $(rom_bg_core | tr '\n' ' ') "
  _exempt=$(dumpsys deviceidle whitelist 2>/dev/null | sed -n 's/^ *[a-z-]*,\([a-zA-Z0-9_.]*\),.*/\1/p' | sort -u)
  _sys=$(pm list packages -s 2>/dev/null | sed 's/^package://' | sort -u)
  _sys_s=" $(printf '%s\n' $_sys | tr '\n' ' ') "
  _ex_s=" $(printf '%s\n' $_exempt | tr '\n' ' ') "
  for _p in $(running_packages); do
    [ -n "$_p" ] || continue
    case "$_keep" in *" $_p "*) continue ;; esac
    case "$_sys_s" in *" $_p "*) ;; *) continue ;; esac
    case "$_ex_s" in *" $_p "*) continue ;; esac
    printf '%s\n' "$_p"
  done
}

meta_rom_bg_off() {
  echo "Apps|Restrict the ROM's background work|The phone's own apps and services that are working in the background while you are not using them are restricted while the screen is off - the same switch Settings offers per app, per package. Nothing is disabled or suspended: every one of them still works the moment you open it, and each is put back on wake.|1|deep|battery"
}
# Same shape as app_restrict: the snapshot is the set of packages we manage, so a
# set that still matches means the per-package values in the sub-journal are
# still ours.
snapshot_rom_bg_off() {
  printf '%s\n' "$(rom_bg_candidates | tr '\n' ' ')"
}
apply_rom_bg_off() {
  _bucket=$(cfg bucket_level restricted)
  case "$_bucket" in restricted|rare|frequent) ;; *) _bucket=restricted ;; esac
  _list="$ORIG_DIR/rom_bg.tsv"
  # Re-applied on every screen-off in the same idle period; the record of what a
  # package looked like BEFORE we touched it must be written once, or the exit
  # would restore our own value as if it were the user's.
  [ -f "$_list" ] || : > "$_list"
  _d=$SPSM_DIR/.tmp
  mkdir -p "$_d" 2>/dev/null
  _pkgfile="$_d/rombg.pkgs.$$"
  _r="$_d/rombg.$$"
  : > "$_r"
  rom_bg_candidates > "$_pkgfile" 2>/dev/null
  _names=$(tr '\n' ' ' < "$_pkgfile" 2>/dev/null)
  _known=" $(cut -f1 "$_list" 2>/dev/null | tr '\n' ' ') "
  _n=0
  while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    _n=$((_n + 1))
    case "$_known" in
      *" $_pkg "*)
        # Already recorded in this idle period: these are our values, so there is
        # nothing to read and nothing to write down - just hold them in place.
        (
          am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
          cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
          am make-uid-idle "$_pkg" >/dev/null 2>&1 || am make-uid-idle --user 0 "$_pkg" >/dev/null 2>&1
        ) & ;;
      *)
        (
          _ob=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
          [ -n "$_ob" ] || _ob=-
          _oo=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
                | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
          [ -n "$_oo" ] || _oo=-
          [ "$_ob" = "-" ] && [ "$_oo" = "-" ] && exit 0
          printf '%s\t%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_bucket" "$_oo" deny >> "$_r"
          [ "$_ob" != "-" ] && am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
          [ "$_oo" != "-" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
          am make-uid-idle "$_pkg" >/dev/null 2>&1 || am make-uid-idle --user 0 "$_pkg" >/dev/null 2>&1
        ) & ;;
    esac
  done < "$_pkgfile"
  wait
  rm -f "$_pkgfile"
  # One writer for the journal, in a stable order.
  sort -u "$_r" 2>/dev/null | while IFS=$TAB read -r _pkg _ob _nb _oo _no; do
    [ -n "$_pkg" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_nb" "$_oo" "$_no" >> "$_list"
  done
  rm -f "$_r"
  if [ "$_n" = 0 ]; then
    log "rom background: nothing of the phone's own was running in the background"
  else
    log "rom background: $_n of the phone's own package(s) restricted for this idle period: $_names"
  fi
}
restore_rom_bg_off() {
  _list="$ORIG_DIR/rom_bg.tsv"
  [ -f "$_list" ] || return 0
  while IFS=$TAB read -r _pkg _ob _nb _oo _no || [ -n "$_pkg" ]; do
    [ -n "$_pkg" ] || continue
    (
      if [ "$_ob" != "-" ]; then
        _now=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
        # Only undo our own change: a value something else has moved since is a
        # newer decision than ours.
        [ "$_now" = "$_nb" ] && am set-standby-bucket "$_pkg" "$_ob" >/dev/null 2>&1
      fi
      if [ "$_oo" != "-" ]; then
        _now=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
               | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
        [ "$_now" = "$_no" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND "$_oo" >/dev/null 2>&1
      fi
    ) &
  done < "$_list"
  wait
  rm -f "$_list"
}

# ============================================================ registry
# Order matters: cheapest and most visible first, and the deep system-wide
# switches last, so that a failure part-way through never leaves the phone
# without a working launcher or CPU.

KNOBS="
home_swap
nav_buttons
dt2w_off
aod_off
brightness_cap
timeout_short
animations_off
haptic_off
rotate_lock
cap_always
block_other_apps
sweep_bg
wifi_off
bt_off
data_off
nfc_off
scan_always_off
location_off
ged_boost_off
gpu_cap
gov_powersave
cpu_cap
cpu_offline_big
app_restrict
rom_bg_off
freeze_google
deep_doze
sync_off
battery_saver
mtk_low_power
blur_off
host_recents_off
statusbar_on
"

knobs_all() { for k in $KNOBS; do echo "$k"; done; }

# Membership test. knobs_all prints one knob per line, so a
#   case " $(knobs_all) " in *" $k "*) ...
# test can never match: the command substitution keeps its newlines and the
# knobs are never surrounded by spaces. Always ask this function instead.
knob_exists() { # knob_exists id
  for _e in $KNOBS; do [ "$_e" = "$1" ] && return 0; done
  return 1
}

knob_meta() { # knob_meta id -> category|label|desc|default|scope|tags
  _fn="meta_$1"
  if command -v "$_fn" >/dev/null 2>&1 || type "$_fn" >/dev/null 2>&1; then
    "$_fn"
  else
    echo "Other|$1|(no description)|0|session|"
  fi
}

knob_scope() {
  knob_meta "$1" | awk -F'|' '{print $5}'
}
knob_default() {
  knob_meta "$1" | awk -F'|' '{print $4}'
}

# ------------------------------------------------------------------ app list
# Which packages are we allowed to restrict? Third-party apps, minus anything
# the user pinned, minus anything Android already exempts from battery
# optimisation, minus the things that must keep working (calls, SMS, alarms,
# the root manager itself, and our own app).
#
# The root managers matter twice over: they are how a user gets back control if
# anything goes wrong (the module's Action button lives in one), so restricting
# or suspending them is how a power saving mode locks somebody out of their own
# phone. ResukiSU's package was missing from this list while it was running on
# the device this was written for - it was being treated as an ordinary app.
ESSENTIALS="com.android.dialer com.android.server.telecom com.android.mms com.android.messaging com.google.android.apps.messaging com.android.providers.telephony com.android.phone com.android.deskclock com.android.systemui com.android.settings dev.axion.spsm"
ROOT_APPS="com.topjohnwu.magisk me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra com.resukisu.resukisu me.resukisu.resukisu com.resukisu.manager com.dergoogler.mmrl com.franco.kernel eu.chainfire.supersu com.koushikdutta.superuser com.noshufou.android.su"

# The packages that must keep working whatever the mode does: the essentials
# above, whatever root managers this phone has installed, the keyboard (a phone
# with no keyboard cannot answer anyone) and the launcher.
protected_packages() {
  printf '%s\n' $ESSENTIALS $ROOT_APPS
  # Current and enabled keyboards, e.g. "com.google.android.inputmethod.latin/...".
  for _src in default_input_method enabled_input_methods; do
    _v=$(sget secure "$_src")
    [ -n "$_v" ] || continue
    case "$_v" in null) continue ;; esac
    for _entry in $(printf '%s' "$_v" | tr ':;' '  '); do
      printf '%s\n' "${_entry%%/*}"
    done
  done
  # Whatever is the home app right now.
  home_holder
}

# Third-party apps this mode is allowed to suspend: everything except the apps
# the user allowed, the protected packages above, and anything Android is already
# exempting from battery optimisation (those are exempt for a reason - alarms,
# accessibility, and the like).
blockable_packages() {
  _keep=" $(cfg keep '') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') $(protected_packages | tr '\n' ' ') "
  _all=$(pm list packages -3 2>/dev/null | sed 's/^package://')
  for _p in $_all; do
    [ -n "$_p" ] || continue
    case "$_keep" in *" $_p "*) continue ;; esac
    echo "$_p"
  done
}

managed_packages() {
  _keep=" $(cfg keep '') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') "
  _keep="$_keep $ESSENTIALS "
  _exempt=$(dumpsys deviceidle whitelist 2>/dev/null | sed -n 's/^ *[a-z-]*,\([a-zA-Z0-9_.]*\),.*/\1/p' | sort -u)
  _all=$(pm list packages -3 2>/dev/null | sed 's/^package://')
  for _p in $_all; do
    [ -n "$_p" ] || continue
    case "$_keep" in *" $_p "*) continue ;; esac
    echo "$_exempt" | grep -qxF "$_p" && continue
    echo "$_p"
  done
}
