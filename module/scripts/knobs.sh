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
  _idx=0
  while IFS=$TAB read -r _t _v || [ -n "$_t" ]; do
    [ -n "$_t" ] || continue
    [ "$_v" = "(MISSING)" ] && continue
    if [ -f "$2" ]; then
      # Both sides are in the encoded form, so this comparison does not care
      # what the value contains.
      _was=$(snap_get "$(cat "$2" 2>/dev/null)" "$_t")
      _cur=$(enc_val "$(kv_result "$_ds" "$_idx")")
      # Still ours to undo? If not, a newer value wins.
      if [ -n "$_was" ] && [ "$_cur" != "$_was" ]; then
        rm -f "$_ds/$$.$_idx" "$_ds/$$.$_idx.part"
        _idx=$((_idx + 1))
        continue
      fi
    fi
    kv_write "$_t" "$(unesc "$_v")"
    rm -f "$_ds/$$.$_idx" "$_ds/$$.$_idx.part"
    _idx=$((_idx + 1))
  done < "$1"

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
    [ "$_seen" = ours ] && return 0
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
snapshot_cpu_cap() {
  snap_kv /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
          /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq \
          /sys/devices/system/cpu/cpufreq/policy6/scaling_governor \
          /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq \
          /proc/cpufreq/cpufreq_power_mode
}
apply_cpu_cap() {
  # Cache the top of each cluster and cap below it; never touch scaling_min_freq,
  # because a high floor plus a powersave governor was exactly what pinned the
  # little cluster at 500 MHz for the whole session in v2.
  for _p in 0 6; do
    _d=/sys/devices/system/cpu/cpufreq/policy$_p
    [ -d "$(rp "$_d")" ] || continue
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
  done
  w 1 /proc/cpufreq/cpufreq_power_mode
}
restore_cpu_cap() { restore_kv "$1" "$2"; }

meta_cpu_offline_big() {
  echo "Processor|Switch off the big cores|Two of the eight processor cores are switched off completely. Saves the most, but the phone feels slower if something wakes it.|0|deep|experimental"
}
snapshot_cpu_offline_big() {
  snap_kv /sys/devices/system/cpu/cpu6/online /sys/devices/system/cpu/cpu7/online
}
apply_cpu_offline_big() {
  w 0 /sys/devices/system/cpu/cpu7/online
  w 0 /sys/devices/system/cpu/cpu6/online
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
  managed_packages | while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    _ob=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
    [ -n "$_ob" ] || _ob=-
    _oo=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
          | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
    [ -n "$_oo" ] || _oo=-
    [ "$_ob" = "-" ] && [ "$_oo" = "-" ] && continue
    # Only the first sighting of a package in this idle period is a record of
    # what it looked like before we touched it.
    case "$_known" in
      *" $_pkg "*) ;;
      *) printf '%s\t%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_bucket" "$_oo" "deny" >> "$_list" ;;
    esac
    [ "$_ob" != "-" ] && am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
    [ "$_oo" != "-" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
  done
}
restore_app_restrict() {
  _list="$ORIG_DIR/app_restrict.tsv"
  [ -f "$_list" ] || return 0
  while IFS=$TAB read -r _pkg _ob _nb _oo _no || [ -n "$_pkg" ]; do
    [ -n "$_pkg" ] || continue
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
  done < "$_list"
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
  for _p in $(google_packages); do
    pm suspend "$_p" >/dev/null 2>&1
    am force-stop "$_p" >/dev/null 2>&1
  done
}
restore_freeze_google() {
  restore_kv "$1" "$2"
  for _p in $(google_packages); do
    # Unsuspending always: suspending is the change we make, and leaving one
    # behind would keep an app dead until the next reboot.
    pm unsuspend "$_p" >/dev/null 2>&1
    # Enabling is only right for a package that was enabled before we touched
    # it. A Play Store somebody disabled on purpose must not come back to life
    # because the mode was switched off.
    _st=$(awk -F'\t' -v p="$_p" '$1==p{print $2; exit}' "$1" 2>/dev/null)
    case "$_st" in
      disabled*) ;;
      *) pm enable "$_p" >/dev/null 2>&1 ;;
    esac
  done
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
  dumpsys deviceidle force-idle deep >/dev/null 2>&1 && touch "$STATE/doze_forced"
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

apply_block_other_apps() {
  # A second application in the same session (the deep phase runs again on every
  # screen-off) must not re-record anything: the list is what we suspended, once.
  [ -f "$BLOCKED_BY_US" ] || : > "$BLOCKED_BY_US"
  blockable_packages | while read -r _p; do
    [ -n "$_p" ] || continue
    # An app that is already suspended is somebody else's decision - the user's,
    # or another tool's. Never ours to take over, and never ours to release.
    if dumpsys package "$_p" 2>/dev/null | grep -q 'suspended=true'; then
      continue
    fi
    if pm suspend --user 0 "$_p" >/dev/null 2>&1 || pm suspend "$_p" >/dev/null 2>&1; then
      grep -qxF "$_p" "$BLOCKED_BY_US" 2>/dev/null || printf '%s\n' "$_p" >> "$BLOCKED_BY_US"
      am force-stop "$_p" >/dev/null 2>&1
    fi
  done
}

restore_block_other_apps() {
  [ -f "$BLOCKED_BY_US" ] || return 0
  while read -r _p; do
    [ -n "$_p" ] || continue
    # Only if it is still suspended: if something else has since had an opinion
    # about this app, that opinion wins.
    dumpsys package "$_p" 2>/dev/null | grep -q 'suspended=true' || continue
    pm unsuspend --user 0 "$_p" >/dev/null 2>&1 || pm unsuspend "$_p" >/dev/null 2>&1
  done < "$BLOCKED_BY_US"
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
  printf 'little_max=%s big_max=%s governor=%s doze=%s\n' \
    "${_c0:--}" "${_c6:--}" "${_g:--}" "$_d" > "$STATE/deep_report" 2>/dev/null
  log "deep applied: $(cat "$STATE/deep_report" 2>/dev/null)"
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

meta_cap_always() {
  echo "Performance|Keep power limits while using the phone|Normally the processor and graphics limits apply only while the screen is off, so the phone stays quick while you use it. Turn this on to keep them applied the whole time - cooler and slower, and you can see them in any kernel manager.|0|session|perf,breaks-features,control"
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

# ============================================================ registry
# Order matters: cheapest and most visible first, and the deep system-wide
# switches last, so that a failure part-way through never leaves the phone
# without a working launcher or CPU.

KNOBS="
home_swap
dt2w_off
aod_off
brightness_cap
timeout_short
animations_off
haptic_off
rotate_lock
cap_always
block_other_apps
wifi_off
bt_off
data_off
nfc_off
scan_always_off
location_off
ged_boost_off
gpu_cap
cpu_cap
cpu_offline_big
app_restrict
freeze_google
deep_doze
sync_off
battery_saver
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
