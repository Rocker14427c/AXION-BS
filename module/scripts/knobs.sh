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
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
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
  _d=$SPSM_DIR/.tmp/s${KRV_TAG:-main}
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
#
# The writes go out TOGETHER, and the log of what they did is written down as
# they land. Both halves are measured, not guessed:
#   - one `settings put` costs this phone most of a fifth of a second while the
#     activation fan is contending, and a knob with three keys spent seconds
#     writing three values that know nothing about each other (restore_kv made
#     the same argument for the exit, and the exit got its seconds back);
#   - the engine reads every knob a SECOND time after the apply to journal what
#     the change looks like. For the knobs whose snapshot is exactly the set of
#     targets written here, that read is asking the phone for values this
#     function just wrote with its own hand. The writes log is the same answer
#     for free - see SYNTH_KNOBS below.
# A write that fails is logged as FAILED and sends the knob back to a real
# read, so the journal never claims a value that was not confirmed.
apply_kv() {
  _wlog=''
  [ -n "${KNOB_ID:-}" ] && _wlog="$JOURNAL/$KNOB_ID.writes"
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
    if [ -n "$_wlog" ]; then
      ( if kv_write "$_t" "$_v"; then
          printf '%s\t%s\n' "$_t" "$(enc_val "$_v")" >> "$_wlog" 2>/dev/null
        else
          printf 'FAILED\t%s\n' "$_t" >> "$_wlog" 2>/dev/null
        fi ) </dev/null &
    else
      kv_write "$_t" "$_v"
    fi
  done
  [ -n "$_wlog" ] && wait
  return 0
}

# ---------------------------------------------------- synthesised applied read
#
# The knobs whose snapshot targets are EXACTLY the targets apply_kv writes -
# and nothing else - never need the engine's second real read after the apply:
# the writes log holds what the phone confirmed, target by target. A knob that
# writes anything outside apply_kv (dt2w_off's proc nodes, the radios' svc
# calls, the GPU's opp lock, the governor's own read-backs) is deliberately
# NOT listed: for those, the honest applied reading stays a real reading.
#
# The field log that paid for this: activation 2026-09-25 10:59, 67s total,
# with dt2w_off alone at 8s - two full settings passes (before AND after) plus
# sequential puts, on a phone answering each settings call in a fifth of a
# second while three knobs contended for it.
SYNTH_KNOBS="aod_off dt2w_off timeout_short animations_off haptic_off rotate_lock blur_off statusbar_on scan_always_off location_off sync_off battery_saver"

synth_eligible() { # synth_eligible <id>
  case " $SYNTH_KNOBS " in *" $1 "*) return 0 ;; esac
  return 1
}

# synth_applied <id> -> the applied snapshot text, or rc=1 when the writes log
# cannot account for the outcome (missing, empty, or holding a FAILED write).
# Targets the apply skipped or never touched keep their original values -
# which is precisely what a real read would report for them seconds later.
synth_applied() {
  _sw="$JOURNAL/$1.writes"
  [ -s "$_sw" ] || return 1
  _swt=''
  while IFS= read -r _sl || [ -n "$_sl" ]; do
    case "$_sl" in
      FAILED*) return 1 ;;
      *) _swt="$_swt$_sl
" ;;
    esac
  done < "$_sw"
  [ -n "$_swt" ] || return 1
  [ -f "$JOURNAL/$1.orig" ] || return 1
  while IFS=$TAB read -r _st _sv || [ -n "$_st" ]; do
    [ -n "$_st" ] || continue
    _nw=$(snap_get "$_swt" "$_st")
    if [ -n "$_nw" ]; then
      printf '%s\t%s\n' "$_st" "$_nw"
    else
      printf '%s\t%s\n' "$_st" "$_sv"
    fi
  done < "$JOURNAL/$1.orig"
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
  # The scratch dir is per-invocation: reverts run side by side now (see the
# exit), and every one of them used to share .tmp with files named by $$ - the
# same pid in every subshell, so two knobs reverting at once read each other's
# values. The tag comes from the parallel runner; serial callers share "main".
  _ds=$SPSM_DIR/.tmp/w${KRV_TAG:-main}
  # What the restore did, said while it does it - the caller's verdict comes
  # from this file instead of a second full read of every value (which was
  # thirteen knobs' worth of snapshots at once on the exit, a hundred seconds
  # of the owner's life, for an answer the restore already had).
  _out=$SPSM_DIR/.tmp/krv.${KRV_TAG:-main}
  : > "$_out" 2>/dev/null
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
        # Not ours anymore - but check the other side before calling it kept:
        # a value already sitting at the original (the screen-off phase undid
        # it, the user set it back themselves) needs no write and is not an
        # external change. Calling it kept made the whole knob a "left alone"
        # and doze a false unmet promise.
        if [ "$_cur" != "$_v" ]; then
          printf 'kept\t%s\n' "$_t" >> "$_out" 2>/dev/null
        fi
        rm -f "$_ds/$$.$_idx" "$_ds/$$.$_idx.part"
        _idx=$((_idx + 1))
        continue
      fi
    fi
    # The current value is read BEFORE the write is backgrounded - the parent
    # deletes the scratch file the moment the job is spawned, and a failed
    # record that raced it said "got []", naming half the story.
    _got=$(kv_result "$_ds" "$_idx")
    ( kv_write "$_t" "$(unesc "$_v")" 2>/dev/null \
        && printf 'wrote\t%s\n' "$_t" >> "$_out" 2>/dev/null \
        || printf 'failed\t%s: want [%s] got [%s]\n' "$_t" "$(unesc "$_v")" "$_got" >> "$_out" 2>/dev/null ) &
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
  echo "Home|Power-saving home|While the mode is on, this mode's own home screen takes over. Your regular home - every app and widget - returns the moment you switch the mode off.|1|session|core"
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
  echo "Display|No wake on double-tap|Taps and swipes on the sleeping screen no longer wake the phone. The power button always works.|1|session|battery"
}
snapshot_dt2w_off() { snap_kv $DT2W_SETTINGS $DT2W_NODES; }
apply_dt2w_off() {
  # The proc nodes go through apply_kv with the settings: a node whose
  # original reading was (MISSING) is skipped before any write (nothing to
  # undo it by), an existing node joins the same parallel write fan, and the
  # writes log then accounts for EVERY target this knob touches - which is
  # what lets the applied reading be synthesised from the log instead of a
  # second 16-target sweep right after the first one.
  set -- "@secure:double_tap_to_wake=0" "@system:double_tap_to_wake=0" "@secure:tap_to_wake=0"
  for _f in $DT2W_NODES; do set -- "$@" "$_f=0"; done
  apply_kv "$@"
}
restore_dt2w_off() { restore_kv "$1" "$2"; }

meta_aod_off() {
  echo "Display|Always-on display off|The clock and notifications no longer stay lit on the sleeping screen.|1|session|battery"
}
snapshot_aod_off() { snap_kv @secure:doze_always_on @secure:doze_enabled @system:doze_always_on /sys/devices/platform/soc/soc:mtk-tb/ambient_enable; }
apply_aod_off() { apply_kv "@secure:doze_always_on=0" "@secure:doze_enabled=0" "@system:doze_always_on=0"; }
restore_aod_off() { restore_kv "$1" "$2"; }

meta_brightness_cap() {
  echo "Display|Lower screen brightness|Keeps the screen at a gentle, fixed brightness. It never brightens the screen.|1|session|battery"
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
  echo "Display|Shorter screen timeout|The screen switches itself off 15 seconds after your last touch.|1|session|battery"
}
snapshot_timeout_short() { snap_kv @system:screen_off_timeout; }
apply_timeout_short() { apply_kv "@system:screen_off_timeout=$(cfg timeout_ms 15000)"; }
restore_timeout_short() { restore_kv "$1" "$2"; }

meta_animations_off() {
  echo "Display|Animations off|Screen animations are removed, so everything feels quicker on reduced power.|1|session|perf"
}
snapshot_animations_off() { snap_kv @global:animator_duration_scale @global:transition_animation_scale @global:window_animation_scale; }
apply_animations_off() { apply_kv "@global:animator_duration_scale=0" "@global:transition_animation_scale=0" "@global:window_animation_scale=0"; }
restore_animations_off() { restore_kv "$1" "$2"; }

meta_haptic_off() {
  echo "Display|Vibration off|The phone no longer vibrates for taps and key presses.|1|session|battery"
}
snapshot_haptic_off() { snap_kv @system:haptic_feedback_enabled @system:vibrate_on; }
apply_haptic_off() { apply_kv "@system:haptic_feedback_enabled=0" "@system:vibrate_on=0"; }
restore_haptic_off() { restore_kv "$1" "$2"; }

meta_rotate_lock() {
  echo "Display|Portrait lock|The screen stays upright, and the rotation sensor rests.|0|session|experimental"
}
snapshot_rotate_lock() { snap_kv @system:accelerometer_rotation; }
apply_rotate_lock() { apply_kv "@system:accelerometer_rotation=0"; }
restore_rotate_lock() { restore_kv "$1" "$2"; }

# ============================================================ Radio / network

meta_wifi_off() {
  echo "Connectivity|Wi-Fi off|Wi-Fi is switched off while the mode is on. Calls, messages and mobile data continue.|1|session|battery"
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
  _v=$(radio_enabled "$1") || _v=''
  # One short retry: under load the stub/real node can hiccup once, and a
  # reading missed here silently turns into "not ours to put back" at the
  # exit. A node that is REALLY unreadable (a state we must never guess at)
  # is still unreadable a fifth of a second later, so nothing is masked.
  [ -n "$_v" ] || { sleep 0.2 2>/dev/null || :; _v=$(radio_enabled "$1") || return 1; }
  [ -n "$_v" ] || return 1
  # Under the same lock as radio_forget: an append that lands while a sibling is
  # rewriting the file is an append into a temp that is about to be overwritten.
  _rr_lock="$RADIO_STATE.lock"
  _rr_i=0
  while ! mkdir "$_rr_lock" 2>/dev/null; do
    _rr_i=$((_rr_i + 1))
    [ "$_rr_i" -gt 20 ] && { rm -rf "$_rr_lock" 2>/dev/null; break; }
    sleep 0.1 2>/dev/null || sleep 1
  done
  printf '%s\t%s\n' "$1" "$_v" >> "$RADIO_STATE"
  rmdir "$_rr_lock" 2>/dev/null
  return 0
}
radio_was() { snap_file_val "$RADIO_STATE" "$1"; }
radio_forget() { # radio_forget <radio> - after it was put back
  [ -f "$RADIO_STATE" ] || return 0
  # Serialised, and through a PRIVATE temp file.
  #
  # This is a read-modify-write on one file, and wifi, bluetooth and nfc are all
  # session knobs - so they revert together in the same bounded parallel fan,
  # three processes rewriting the same file at once. With a shared "$RADIO_STATE
  # .tmp" they also clobbered each other's temp. The observed result was an
  # intermittent failure where the whole file came back EMPTY: a radio's
  # remembered state vanished before its own restore had read it, so the radio
  # was never switched back on and the device did not come back byte for byte.
  # It reproduced perhaps one run in three, always on whichever radio lost.
  #
  # $$ makes the temp private to this process; the lock makes the whole
  # read-modify-write atomic against its siblings. Both are needed - a private
  # temp alone still loses an update when two rewrites interleave.
  _rf_lock="$RADIO_STATE.lock"
  _rf_i=0
  while ! mkdir "$_rf_lock" 2>/dev/null; do
    _rf_i=$((_rf_i + 1))
    # Never block a revert on a lock: after ~2s take it. A stale lock here can
    # only come from a killed sibling, and losing one row is better than not
    # restoring the radios at all.
    [ "$_rf_i" -gt 20 ] && { rm -rf "$_rf_lock" 2>/dev/null; break; }
    sleep 0.1 2>/dev/null || sleep 1
  done
  _rf_tmp="$RADIO_STATE.$$"
  if grep -v "^$1	" "$RADIO_STATE" > "$_rf_tmp" 2>/dev/null; then
    mv -f "$_rf_tmp" "$RADIO_STATE" 2>/dev/null
  else
    # grep exits non-zero when nothing is left, which is a legitimate outcome
    # (the last radio being forgotten) and must still be written.
    [ -f "$_rf_tmp" ] && mv -f "$_rf_tmp" "$RADIO_STATE" 2>/dev/null
  fi
  rm -f "$_rf_tmp" 2>/dev/null
  rmdir "$_rf_lock" 2>/dev/null
  return 0
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

# ---------------------------------------------------------- netpolicy state
# Data Saver ("restrict background") is not a Settings key on this ROM:
# `settings get global data_saver_on` answers null, so an @global target would
# be recorded as (MISSING) - and apply_kv would then, correctly, refuse to
# change it. The truth lives in the netpolicy service, so it is read from there
# and put back through the same command that set it. `data_saver_idle` uses this
# to stop background network work while the screen is off: measured on the
# device, Wi-Fi accounted for 2451 of the wakeups in the battery-stats ledger
# and cellular data another 739 (docs/POWER-ANALYSIS-2026-09-22.md).
#
# Calls and SMS are untouched by this: it restricts apps' background *data*,
# not the modem's registration, which is the one thing that must keep working.
data_saver_state() { # -> true|false, prints nothing when it cannot be read
  if has cmd; then
    _o=$(cmd netpolicy get restrict-background 2>/dev/null | tr -d '\r' | head -1)
    case "$_o" in
      true|false) printf '%s' "$_o"; return ;;
      # this ROM answers "Restrict background status: enabled|disabled"
      *disabled*) printf 'false'; return ;;
      *enabled*)  printf 'true';  return ;;
    esac
  fi
  if has dumpsys; then
    # grep + awk, not a sed alternation: toybox sed does not honour GNU \| and
    # would silently match nothing - the same class of failure as the bare-pipe
    # parameter expansion that made the deep phase apply nothing.
    _o=$(dumpsys netpolicy 2>/dev/null | grep -m1 -i 'restrict background' | awk '{print $NF}' | tr -d '\r')
    case "$_o" in true|false) printf '%s' "$_o"; return ;; esac
  fi
}

data_saver_set() { # data_saver_set on|off
  case "$1" in
    on)  has cmd && cmd netpolicy set restrict-background true  >/dev/null 2>&1 ;;
    off) has cmd && cmd netpolicy set restrict-background false >/dev/null 2>&1 ;;
  esac
  return 0
}

meta_data_saver_idle() {
  echo "Connectivity|Background data paused while asleep|While the screen is off, apps may not use the network in the background, so their push messages and syncs wait for the next time the phone wakes instead of waking it themselves. Calls and SMS keep arriving. Notifications can be a little late, and everything resumes the moment you pick the phone up.|1|deep|battery"
}

snapshot_data_saver_idle() {
  printf 'netpolicy:restrict-background\t%s\n' "$(enc_val "$(data_saver_state)")"
}

apply_data_saver_idle() {
  # Never change a value that could not be read: with no reading on record there
  # is nothing the exit could put back, and a restriction with no way to lift it
  # is how a power mode strands a phone with no network.
  [ -n "$(data_saver_state)" ] || { log "skip data saver: the netpolicy state could not be read, so it is not ours to change"; return 0; }
  data_saver_set on
}

restore_data_saver_idle() { # restore_data_saver_idle <orig-file> [<applied-file>]
  _want=$(unesc "$(sed -n 's/^netpolicy:restrict-background\t//p' "$1" 2>/dev/null | head -1)")
  case "$_want" in
    true)  data_saver_set on ;;
    false) # only lift what is still ours: if something else turned Data Saver
           # on after we did, that is not ours to undo either
           [ "$(data_saver_state)" = true ] && data_saver_set off ;;
    '')    log "data saver: the original was never read, leaving it exactly as it is" ;;
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
  echo "Connectivity|Bluetooth off|Bluetooth is switched off while the mode is on.|1|session|battery"
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
  echo "Connectivity|NFC off|NFC is switched off. Tap-to-pay resumes when the mode is turned off.|1|session|battery"
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
  echo "Connectivity|Background scanning off|Apps can no longer scan for Wi-Fi and Bluetooth devices in the background.|1|session|battery"
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
  echo "Connectivity|Location off|Location is switched off while the mode is on. Maps, weather and navigation resume when it is turned back on.|0|session|breaks-features"
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
# inside the kernel. And it is the ONLY lever this mode now has on CPU speed:
# v3.7.5 removed the hand-written frequency ceiling at the owner's direction -
# "apply just powersave governor, manage cpu frequencies itself, no need to
# worry, all the time is good enough whether screen is on or off" - so the
# governor is a session option: engaged when the mode comes on, lifted only
# when the mode goes off, never touched by a screen change.
meta_gov_powersave() {
  echo "Performance|Processor power-save|The kernel's own power-save governor holds every core at its lowest speed for the whole session - screen on and off. No frequency limit is ever written by hand; this is the only control that manages speed.|1|session|battery"
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



# Window blur is drawn by the graphics chip every frame, behind panels and the
# notification shade. Removing it costs nothing on a black, plain interface and
# gives the chip less to do on every frame - a saving while the phone is in use,
# not while it sleeps.
# On by default since v3.3.1, at the owner's direction, in a mode whose purpose
# is to save everything it can while the phone is in use. It is the one option
# here that changes how the interface looks, so its description says so and the
# switch takes it straight back.
meta_blur_off() {
  echo "Performance|Window blur off|Blurred panels behind the interface are not drawn - a saving on every frame. The look is plainer; switch back on to restore it.|1|session|perf"
}
snapshot_blur_off() { snap_kv @global:disable_window_blurs; }
apply_blur_off() { apply_kv "@global:disable_window_blurs=1"; }
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
  echo "System|Status bar kept visible|If this ROM hides the status bar with an immersive rule, the rule is cleared while the mode is on, so the clock and battery stay in view. Your own setting returns on exit.|1|session|core"
}
# The switch is gone. The owner removed the option: the status bar is simply
# kept visible the whole time the mode is on - the clock, the battery and the
# way back are part of a usable phone, not a preference. knob_enabled is
# redefined after lib.sh, so even a stored "off" from the old option cannot
# turn it off; the option no longer appears in the app's list (see dump-knobs).
knob_enabled() { # knob_enabled id default
  case "$1" in statusbar_on) return 0 ;; esac
  _v=$(cfg "knob.$1" "$2")
  case "$_v" in 1|true|on|yes) return 0 ;; *) return 1 ;; esac
}
snapshot_statusbar_on() { snap_kv @global:policy_control; }
apply_statusbar_on() {
  # Nothing to clear is not a change: a phone that hides no bar with a policy
  # rule gets no write at all - and the exit then has nothing of ours to undo,
  # so a session that changed nothing also restarts nothing.
  case "$(sget global policy_control)" in
    ''|null) return 2 ;;
  esac
  apply_kv "@global:policy_control=null"
}
note_refused_statusbar_on() {
  printf "this ROM hides no bar with a policy rule, so there was nothing to clear\n"
}
restore_statusbar_on() { restore_kv "$1" "$2"; }
probe_statusbar_on() {
  _v=$(sget global policy_control 2>/dev/null)
  case "$_v" in
    ''|null) printf 'policy_control\tunset - this phone keeps the status bar visible\n' ;;
    *)       printf 'policy_control\t%s\n' "$_v" ;;
  esac
}

# Sleep cores, but only after the screen has been off a minute.
#
# The owner's design, verbatim: "when the screen goes off and user didn't turn
# the screen on within 1 minute then core from 2-7 get disabled, only core 0
# and 1 left on, until the user turn the screen back on - after the user turn
# the screen on all cores get back". The delay is the usability: the first
# minute of sleep still has things finishing (the sweep, notifications in
# flight), and only when a whole minute has passed with nothing happening does
# the phone give up the cores.
#
# The timing does NOT live in the deep phase - the deep phase runs at the
# transition, and this knob's whole point is to wait. The daemon fires it
# (engine.sh core-sleep) once its tick sees a minute of continuous sleep; the
# engine re-checks the mode, the screen and the journal under the lock before
# a single core is touched, so a wake that arrives during the firing wins.
meta_cores_sleep() {
  echo "Performance|Sleep six cores after a minute|After one full minute with the screen off, cores 2 to 7 power down and two remain for the system. Every core returns the instant the screen wakes.|1|deep|battery"
}
snapshot_cores_sleep() {
  # Exactly the cores this option may take down; cores 0 and 1 are never
  # touched, so they are never recorded either.
  snap_kv /sys/devices/system/cpu/cpu2/online \
          /sys/devices/system/cpu/cpu3/online \
          /sys/devices/system/cpu/cpu4/online \
          /sys/devices/system/cpu/cpu5/online \
          /sys/devices/system/cpu/cpu6/online \
          /sys/devices/system/cpu/cpu7/online
}
apply_cores_sleep() {
  # Only write to a core that is on. Offlining is a blocking request the kernel
  # finishes when it can, and the v3.4.1 log shows it taking 23s and then 52s on
  # a phone that was busy at the time - a core already off needs no request at
  # all. A minute asleep, the phone here is not busy.
  _did=0
  for _c in 7 6 5 4 3 2; do
    _f=/sys/devices/system/cpu/cpu$_c/online
    [ -e "$(rp "$_f")" ] || continue
    [ "$(rd "$_f")" = 0 ] && continue
    w 0 "$_f" && _did=$((_did + 1))
  done
  [ "$_did" = 0 ] && log "cores_sleep: cores 2-7 are already asleep"
  [ "$_did" != 0 ] && log "cores_sleep: $_did core(s) asleep - cores 0 and 1 stay awake"
  return 0
}
restore_cores_sleep() {
  # Faithful restore: whatever the cores were doing before is what they should
  # be doing after - on the wake path this runs FIRST, before anything else is
  # even started, because six offline cores are the one change the user feels.
  restore_kv "$1" "$2"
}
probe_cores_sleep() {
  _c=2
  while [ "$_c" -le 7 ]; do
    printf 'cpu%s\t%s\n' "$_c" "$(rd /sys/devices/system/cpu/cpu$_c/online 2>/dev/null || echo '?')"
    _c=$((_c + 1))
  done
}

meta_gpu_cap() {
  echo "Performance|Graphics at minimum|The graphics chip stays at its lowest speed for the whole session - screen on and off.|1|session|battery"
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
  echo "Performance|Performance boosts off|The phone's touch and scroll speed-ups are refused while the screen is off.|1|deep|battery"
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
  echo "Apps|Restrict background work|While the screen is off, apps outside your six slots do less work in the background. Notifications may arrive a little later.|1|deep|battery"
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
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  _r="$_d/restrict.$$_${KRV_TAG:-main}"
  : > "$_r"
  _known=" $(cut -f1 "$_list" 2>/dev/null | tr '\n' ' ') "
  managed_packages > "$_d/restrict.pkgs.$$" 2>/dev/null
  _c=0
  while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    case "$_known" in
      *" $_pkg "*)
        # Already recorded in this idle period: these are our values, so hold
        # them in place without reading anything.
        (
          bg_nice
          am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
          cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
        ) & ;;
      *)
        (
          bg_nice
          _ob=$(am get-standby-bucket "$_pkg" 2>/dev/null | tr -d '\r')
          [ -n "$_ob" ] || _ob=-
          _oo=$(cmd appops get "$_pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null \
                | sed -n 's/^[[:space:]]*RUN_ANY_IN_BACKGROUND:[[:space:]]*\([a-z_]*\).*/\1/p' | head -1)
          [ -n "$_oo" ] || _oo=-
          [ "$_ob" = "-" ] && [ "$_oo" = "-" ] && exit 0
          printf '%s\t%s\t%s\t%s\n' "$_pkg" "$_ob" "$_oo" "$_bucket" >> "$_r"
          [ "$_ob" != "-" ] && am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
          [ "$_oo" != "-" ] && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
        ) & ;;
    esac
    # Bounded, six at a time. Unbounded, this loop once put a hundred pm/cmd
    # calls on the phone IN THE SAME INSTANT - on CPUs the power-save governor
    # holds at minimum - and the load average went through the roof: the
    # owner's v3.7.7 report (everything slow, SystemUI starving, the
    # navigation bar gone for seconds at a time). Six at a time is nearly as
    # fast in wall time and lets the phone breathe.
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
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
  _c=0
  while IFS=$TAB read -r _pkg _ob _nb _oo _no || [ -n "$_pkg" ]; do
    [ -n "$_pkg" ] || continue
    (
      bg_nice
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
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
  done < "$_list"
  wait
  # The idle period is over: the next one starts from whatever the phone looks
  # like then, not from this record.
  rm -f "$_list"
}

meta_freeze_google() {
  echo "Apps|Pause Google services|Play services, the Play Store and Search are paused while the mode is on. Apps that depend on them stay quiet until it is turned off.|0|deep|breaks-features"
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
  # suspend_app, not a bare pm suspend: as root the suspender is recorded as
  # "root", and the system's suspended-app dialog crashes on that name.
  for _p in $(google_packages); do
    ( bg_nice
      suspend_app "$_p"
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
  echo "Battery|Deep sleep immediately|The phone enters its deepest sleep state as soon as the screen goes off, and wakes normally.|1|deep|battery,breaks-features"
}
snapshot_deep_doze() {
  # Record the force flag, which is exactly what this knob changes. mState is a
  # transient the system moves on its own, so recording it makes a healthy phone
  # look broken: as soon as we let go, the state machine steps and the old value
  # never matches again. If a dump has no force flag, say so rather than record
  # something that will not hold.
  # timeout, not faith: this exact read once blocked for 889 SECONDS while
  # the phone was forced idle (the v3.7.5 log) - a snapshot must never wait
  # on the state it is measuring.
  _f=$(timeout 15 dumpsys deviceidle 2>/dev/null | sed -n 's/.*mForceIdle=\([a-z]*\).*/\1/p' | head -1)
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

  # The confirmation runs DETACHED, and this returns at once.
  #
  # It used to poll up to six times, half a second apart, waiting to see
  # mForceIdle=true - and its entire product was one log line. Everything else
  # about the knob (the journal entry, the note in `status`, note_deep_doze's
  # reading) is derived later from the phone itself, so nothing downstream ever
  # depended on this loop having finished.
  #
  # What it did depend on was the user's time. This is the FIRST thing applied
  # when the screen goes off, and the rest of the idle sequence queues behind
  # it, so on a phone that never reports the flag - which is most of them; the
  # note text "this phone does not report its idle state" exists for exactly
  # that case - every single screen-off paid a flat three seconds before any
  # other saving was applied. Measured on the fixture: screen-off 3298ms, of
  # which `apply deep_doze took 3s`.
  #
  # Backgrounding it keeps the log line for the phones that do answer, and
  # hands the three seconds back to every phone that does not. The work itself
  # was already asynchronous - this only stops the shell standing around
  # watching it.
  (
    _i=0
    while [ "$_i" -lt 6 ]; do
      _f=$(timeout 5 dumpsys deviceidle 2>/dev/null | sed -n 's/.*mForceIdle=\([a-z]*\).*/\1/p' | head -1)
      [ "$_f" = true ] && { log "deep sleep: the phone has been told to go idle now"; exit 0; }
      _i=$((_i + 1))
      sleep 0.5 2>/dev/null || sleep 1
    done
    log "deep sleep: asked the phone to go idle now; it enters when it can"
  ) &
  return 0
}
note_deep_doze() {
  _f=$(timeout 15 dumpsys deviceidle 2>/dev/null | sed -n 's/.*mForceIdle=\([a-z]*\).*/\1/p' | head -1)
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
  echo "Battery|Android battery saver|Android's own battery saver runs alongside this mode. On this phone it mainly dims the screen.|0|session|experimental"
}
snapshot_battery_saver() { snap_kv @global:low_power @global:low_power_sticky @global:battery_saver_constants; }
apply_battery_saver() { apply_kv "@global:low_power=1" "@global:low_power_sticky=1"; }
# No extra cleanup here: if the ROM had battery_saver_constants before us it is
# in the snapshot and gets written back, and if it did not, restore_kv deletes
# it. Unconditionally deleting it threw away a setting that was never ours.
restore_battery_saver() { restore_kv "$1" "$2"; }

meta_block_other_apps() {
  echo "Apps|Block other apps|Apps outside your six slots are suspended and cannot be opened until the mode is turned off. Everything returns to normal afterwards.|1|session|battery,breaks-features"
}
# A snapshot function must only READ. The engine calls it twice for every
# application - once to record the original and once to record what the change
# looks like - so a snapshot that also writes state has that state overwritten by
# its own second call. (That is exactly how the first version of this knob
# managed to record every app as "already suspended before us" and then leave
# them all suspended on exit.)
snapshot_block_other_apps() {
  _susp=''
  _susp_read=0
  _suspf="$SPSM_DIR/.tmp/susp.$$_${KRV_TAG:-main}"
  if suspended_packages > "$_suspf" 2>/dev/null; then
    _susp_read=1
    _susp=" $(tr '\n' ' ' < "$_suspf") "
  fi
  rm -f "$_suspf"
  if [ "$_susp_read" = 1 ] && [ "$_susp" = "  " ]; then
    # The phone's own suspension record was READ and says nothing is
    # suspended. That answer used to be double-checked with a `dumpsys
    # package` per candidate - 188 binder round trips, ~8s of every
    # activation on this phone (field, 2026-09-25). The record IS the
    # authority pm itself uses; when it could not be read at all, the
    # per-package check below still runs. One awk pass instead: same bytes,
    # one fork.
    blockable_packages | awk 'BEGIN { OFS = "\t" } NF { print $1, 0 }'
    return 0
  fi
  blockable_packages | while read -r _p; do
    [ -n "$_p" ] || continue
    _s=0
    if [ -n "$_susp" ]; then
      case "$_susp" in *" $_p "*) _s=1 ;; esac
    else
      dumpsys package "$_p" 2>/dev/null | grep -q 'suspended=true' && _s=1
    fi
    printf '%s\t%s\n' "$_p" "$_s"
  done
}

# Which apps this session suspended, so that the exit undoes exactly those and
# nothing else. Written by the apply, read by the restore, and removed by the
# restore.
BLOCKED_BY_US="$STATE/blocked_by_us.tsv"
# What force-stop took away, as opposed to what suspend froze. The two need
# separate records because they need separate inverses: `pm unsuspend` releases
# a freeze, `pm unstop` releases a stop, and only the second one survives a
# reboot or an exit on its own.
STOPPED_BY_US="$STATE/stopped_by_us.tsv"
# Apps the owner has said must keep running in the background. The six slots are
# a shortlist with a hard limit; this is the open-ended version, and it exists
# because of what the owner's phone did: a chat app the mode had force-stopped
# stopped receiving anything at all, because a stopped package is not woken by a
# push. Calls and SMS are protected by ROLES and always were; everything else is
# the owner's call, which is what this file is.
KEEP_AWAKE="$SPSM_DIR/keep_awake.txt"

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
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  _r="$_d/block.$$"
  : > "$_r"
  # Phase timing. The v3.8.1 field log showed this one knob taking 7 of the 13
  # startup seconds - 54% of the whole start - but "apply block_other_apps took
  # 7s" cannot say WHICH of its four phases that was. These stamps cost one
  # now_epoch each (a builtin when the clock is real) and turn the next log
  # into an attribution instead of a guess. They only print when the knob is
  # slow enough to matter, so a normal run's log is unchanged.
  _bo_t0=$(now_epoch)
  # Who is already suspended, read once above rather than asked once per app.
  _susp=''
  _susp_read=0
  _suspf="$_d/susp.$$_${KRV_TAG:-main}"
  if suspended_packages > "$_suspf" 2>/dev/null; then
    _susp_read=1
    _susp=" $(tr '\n' ' ' < "$_suspf") "
  fi
  rm -f "$_suspf"
  _bo_t1=$(now_epoch)
  # Who is a candidate at all: blockable, minus what somebody else already
  # suspended (never ours to take over, and never ours to release).
  _cand="$_d/cand.$$"
  if [ "$_susp_read" = 1 ] && [ "$_susp" = "  " ]; then
    # Nothing is suspended and the phone's record was read to say so: every
    # blockable package is a candidate, and building the list is a straight
    # copy. The per-package shell pass cost 2s on a quiet phone and 5s under
    # the activation's own fan (device probes, 2026-09-25) - for a filter
    # that, in this case, filters nothing.
    blockable_packages > "$_cand"
  else
    # One open for the whole loop: 187 separate `>>` appends were 187
    # open/write/close cycles through SELinux and f2fs - measured 4s of the
    # block knob's candidate phase on the device, for what is really one file.
    {
      for _p in $(blockable_packages); do
        [ -n "$_p" ] || continue
        if [ -n "$_susp" ]; then
          case "$_susp" in *" $_p "*) continue ;; esac
        fi
        printf '%s\n' "$_p"
      done
    } > "$_cand"
  fi
  # One pm call per forty packages - 186 suspensions cost five round-trips,
  # not 186 forks on min-frequency cores. Only what the phone confirmed lands
  # in the record.
  _bo_t2=$(now_epoch)
  pm_batch suspend < "$_cand" > "$_r"
  rm -f "$_cand"
  _bo_t3=$(now_epoch)
  # A suspended app holds memory until it is stopped: same as ever, for
  # exactly the apps this call confirmed. The idle hand-to-AMS is gone: a
  # suspended app cannot run, so "idle" adds nothing a suspension does not
  # already say - and it was a second fork per app, 186 of them, on
  # min-frequency cores. Twelve at a time since v3.9.0: the work per package
  # is one binder call to AMS, which keeps far more threads than twelve -
  # the field run at six spent 5s here; the wall time is AMS's queue, not
  # the fork rate.
  sort -u "$_r" 2>/dev/null > "$_r.s"
  _c=0
  while read -r _p; do
    [ -n "$_p" ] || continue
    (
      bg_nice
      am force-stop "$_p" >/dev/null 2>&1
    ) &
    _c=$((_c + 1))
    [ "$_c" -ge 12 ] && { wait; _c=0; }
  done < "$_r.s"
  wait
  _bo_t4=$(now_epoch)
  # This stopped set IS the sweep's set: the sweep's one full pass would only
  # force-stop the same packages seconds later. Mark the full pass done -
  # the sweep still clears strays with its one-call kill-all.
  : > "$STATE/sweep_full" 2>/dev/null
  # One writer, in a stable order, as before - but the duplicate check is done
  # in the shell instead of with a grep per package.
  #
  # On the owner's phone this loop runs 187 times, and `grep -qxF` is a fork
  # AND a full scan of a file that grows to 187 lines on each pass. Measured
  # standalone: 226 ms for 187 packages against 5 ms for the shell test - 45x -
  # and that was on a desktop; this runs on little cores held at their minimum
  # frequency by the governor knob that has already been applied by this point.
  #
  # The existing record is read once into a space-delimited string and tested
  # with `case`, which is the same technique blockable_packages already uses
  # for its keep-list. Output order and content are unchanged.
  #
  # And the record is WRITTEN once per file, not once per package: 374 open-
  # append-close round trips against /data measured 10s in the field (the
  # 2026-09-25 activation: record=10s for 187 lines). The whole record is
  # built in a variable and lands in one write per file - same bytes, same
  # order, two opens.
  _bu_seen=" "
  if [ -s "$BLOCKED_BY_US" ]; then
    while IFS= read -r _bl; do
      [ -n "$_bl" ] && _bu_seen="$_bu_seen$_bl "
    done < "$BLOCKED_BY_US"
    # `read` returns false on a last line with no trailing newline, which would
    # drop that entry from the seen-set and duplicate it in the record.
    [ -n "$_bl" ] && _bu_seen="$_bu_seen$_bl "
  fi
  _bu_new=''
  while read -r _p; do
    [ -n "$_p" ] || continue
    case "$_bu_seen" in
      *" $_p "*) continue ;;
    esac
    _bu_seen="$_bu_seen$_p "
    _bu_new="$_bu_new$_p
"
  done < "$_r.s"
  if [ -n "$_bu_new" ]; then
    # The same set, recorded a second time for the release that suspend's
    # inverse cannot perform. $_r.s is precisely what was force-stopped above.
    printf '%s' "$_bu_new" >> "$BLOCKED_BY_US" 2>/dev/null
    printf '%s' "$_bu_new" >> "$STOPPED_BY_US" 2>/dev/null
  fi
  rm -f "$_r" "$_r.s"
  # Attribution, only when this knob was actually slow. The four numbers are
  # the phases in order: reading who is already suspended, choosing candidates,
  # the batched pm suspend, and the force-stops.
  _bo_t5=$(now_epoch)
  if [ "$((_bo_t5 - _bo_t0))" -ge 2 ] 2>/dev/null; then
    log "  block_other_apps phases: suspended-read=$((_bo_t1 - _bo_t0))s candidates=$((_bo_t2 - _bo_t1))s pm-suspend=$((_bo_t3 - _bo_t2))s force-stop=$((_bo_t4 - _bo_t3))s record=$((_bo_t5 - _bo_t4))s"
  fi
}

# The applied reading, from the record the apply CONFIRMED rather than from an
# immediate re-read of the disk.
#
# PackageManager answers `pm suspend` the moment the suspension is real, but
# flushes /data/system/users/*/package-restrictions.xml seconds later - and the
# engine's after-read used to race that flush. The field log (2026-09-25, the
# 67s activation) shows the cost: 187 packages suspended and confirmed, the
# knob then reported "no visible change (optional node missing?)" because BOTH
# of its reads of the world said zero - the second one reading a file the
# system had not written yet. A lying note is cosmetic; what it really broke
# is the promise that the journal can tell a kept change from a failed one.
#
# So the after-read is answered from our own confirmed record: every package
# pm confirmed is suspended (1), everything else keeps whatever the before-
# read saw. The engine prefers a function named applied_snapshot_<id> when the
# knob defines one; the before-read is untouched, and `engine.sh verify` still
# reads the live phone end to end.
applied_snapshot_block_other_apps() {
  [ -s "$BLOCKED_BY_US" ] || return 1
  # A record of nothing confirms nothing: refuse, and the knob falls back to
  # the phone's own (re-)reading.
  grep -qm1 . "$BLOCKED_BY_US" 2>/dev/null || return 1
  [ -f "$JOURNAL/block_other_apps.orig" ] || return 1
  # One awk pass over the two files. The record says which packages the phone
  # CONFIRMED suspended - they read 1 here whatever the disk's flush lag says
  # (the 2026-09-25 field race: 187 confirmed suspensions journalled as "no
  # visible change" because the after-read saw the pre-suspend XML). Every
  # other line passes through byte-for-byte as the before-snapshot recorded
  # it. The shell loop this replaces re-checked 188 lines one case-match at
  # a time at the tail of every activation: ~2s on the device.
  awk 'NR == FNR { if (length($0)) b[$0] = 1; next }
       { t = index($0, "\t")
         if (t == 0) { print; next }
         k = substr($0, 1, t - 1)
         if (k in b) print k "\t1"; else print
       }' "$BLOCKED_BY_US" "$JOURNAL/block_other_apps.orig"
}

# ======================================== putting back what force-stop took
#
# `pm suspend` freezes an app, and every path in this file releases that with
# `pm unsuspend`. Force-stop is NOT the same thing, and the difference is the
# bug the owner's phone showed after one night of this mode: a stopped package
# is not merely frozen - the phone will not start it again on a push, an alarm
# or a broadcast; only a person opening it clears the state. So a messaging app
# this mode stopped, stops messaging, and releasing the suspensions on exit does
# not bring it back. Measured on the owner's phone with the mode off: 173
# packages left stopped, WhatsApp and the mail client among them, nothing on
# screen to explain why messages had gone quiet. `pm` has the inverse of
# force-stop - `pm unstop` - and this is where it is finally called. One call
# per package, because this phone's `pm unstop` takes exactly one.
release_force_stopped() {
  [ -f "$STOPPED_BY_US" ] || return 0
  # Twelve at a time, reniced - and
  # NOT one after another: this phone's `pm unstop` takes one package per call,
  # so the exit that released 187 of them sequentially spent 14s in this loop
  # (field, 2026-09-25 07:23 - more than half of that exit's "revert clean in
  # 24s", and the 47s exit the same morning's owner saw at 12:17 was this loop
  # again under a throttled governor). The calls are independent values with
  # no order between them; the wall time is now the slowest batch, not the sum.
  # stdin is detached per worker: a backgrounded child that inherits the loop's
  # redirected stdin can eat the record the loop is still reading.
  _n=0
  _c=0
  while read -r _p; do
    [ -n "$_p" ] || continue
    _n=$((_n + 1))
    (
      bg_nice
      su 2000 -c "pm unstop --user 0 $_p" >/dev/null 2>&1 \
        || pm unstop --user 0 "$_p" >/dev/null 2>&1
    ) </dev/null &
    _c=$((_c + 1))
    [ "$_c" -ge 12 ] && { wait; _c=0; }
  done < "$STOPPED_BY_US"
  wait
  rm -f "$STOPPED_BY_US" 2>/dev/null
  [ "$_n" -gt 0 ] && log "released $_n force-stopped package(s) - stopped apps can start again"
  return 0
}

restore_block_other_apps() {
  [ -f "$BLOCKED_BY_US" ] || return 0
  # Every package in this record is one this mode suspended. ALL of them are
  # released, together, with no questions asked: the dumpsys check that used
  # to stand in front of each release did not match this phone's output, and
  # the v3.7.5 log shows what that cost - an exit that skipped every release
  # and left the apps suspended through a re-flash and a reboot. Our record
  # is the authorisation; the release is idempotent - and now batched: one
  # pm call per forty, instead of 186 forks on the way out.
  pm_batch unsuspend < "$BLOCKED_BY_US" >/dev/null 2>&1
  rm -f "$BLOCKED_BY_US"
  # And the half of it that `pm unsuspend` cannot undo.
  release_force_stopped
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
  # Who is holding the frequency down. There are no ceilings any more (v3.7.5
  # removed them at the owner's direction), so the honest answers are: governor
  # when every cluster this phone has took power-save, and mixed when one kept
  # its own governor - which is the phone's shape on one cluster, not a fault.
  _by=mixed
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
  echo "Connectivity|Mobile data off|Mobile data is switched off while the mode is on. Messages arrive once it is turned back on.|0|session|battery,breaks-features"
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
  echo "Battery|Account sync off|Email and contacts stop syncing until the mode is turned off.|0|session|breaks-features"
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
  echo "System|Three-button navigation|The system's own three-button bar is used on every screen while the mode is on: Back is Back, Home returns here, and Recents opens this mode's task list. Your own navigation returns on exit.|1|session|core"
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
  # A suspended app cannot start, so it cannot grab memory back: stopping the
  # frozen set once per session is enough, and redoing 264 force-stops on
  # every screen-off only kept the phone busy for nothing (15 s a sweep, in
  # the v3.7.7 log). Every sweep after the first therefore only reaps the
  # strays - processes of apps we never suspended - with the one-call
  # kill-all, and reports the memory honestly either way.
  if [ -f "$STATE/sweep_full" ]; then
    has am && am kill-all >/dev/null 2>&1
    _after=$(mem_available)
    log "background sweep ($_why): strays cleared, free memory $(mem_words "$_before") -> $(mem_words "$_after")"
    return 0
  fi
  _n=0
  if [ -n "$SPSM_ROOT" ]; then
    # A fake phone has no processes to stop; the test reads the calls instead.
    :
  fi
  if [ -f "$BLOCKED_BY_US" ]; then
    _c=0
    while read -r _p; do
      [ -n "$_p" ] || continue
      _n=$((_n + 1))
      (
        bg_nice
        am force-stop "$_p" >/dev/null 2>&1
        # The idle hand-to-ActivityManager happened in the block apply, for
        # this very set, seconds ago - repeating it here was a fork per app
        # for a fact already told. Stopping is what frees the memory; that
        # is this pass's whole job.
      ) &
      _c=$((_c + 1))
      [ "$_c" -ge 6 ] && { wait; _c=0; }
    done < "$BLOCKED_BY_US"
    wait
  fi
  # The full pass happened; the rest of this session only needs the light one.
  : > "$STATE/sweep_full" 2>/dev/null
  has am && am kill-all >/dev/null 2>&1
  _after=$(mem_available)
  log "background sweep ($_why): $_n frozen app(s) stopped, free memory $(mem_words "$_before") -> $(mem_words "$_after")"
}

meta_sweep_bg() {
  echo "Memory|Free background memory|Apps outside your six slots are stopped and the memory they hold is returned to the phone. Runs when the mode starts and whenever the screen goes off.|1|session|battery"
}
snapshot_sweep_bg() { :; }
apply_sweep_bg() { sweep_background "mode on"; }
restore_sweep_bg() { :; }
# The sweep is an action, not a setting: its snapshot is empty by design, so
# the engine's before-and-after comparison always agrees with itself and the
# generic note fired on every activation - "no visible change (optional node
# missing?)", which reads like a fault and is neither. Its own log line (what
# was stopped, what the memory did) is the report; the note now says so.
note_sweep_bg() {
  printf 'the sweep is an action, not a setting - its log line above is the report; there is no value to read back\n'
}

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
# What the owner has asked to keep alive, as one space-delimited string. Both
# lists are honoured - the six slots and the keep-awake list - because they mean
# the same thing to every caller; they differ only in how many apps they hold and
# who edits them.
keep_awake_string() {
  printf ' %s %s ' "$(cfg keep '')" "$(cat "$KEEP_AWAKE" 2>/dev/null | tr '\n' ' ')"
}

rom_bg_candidates() {
  _keep=" $(cfg keep '') $(cat "$KEEP_AWAKE" 2>/dev/null | tr '\n' ' ') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') $(protected_packages | tr '\n' ' ') $(rom_bg_core | tr '\n' ' ') "
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
  echo "Apps|Restrict the ROM's background services|The phone's own background services are restricted while the screen is off - the same control Settings offers, applied for you. Each is restored the moment you wake the phone.|1|deep|battery"
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
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  _pkgfile="$_d/rombg.pkgs.$$"
  _r="$_d/rombg.$$"
  : > "$_r"
  rom_bg_candidates > "$_pkgfile" 2>/dev/null
  _names=$(tr '\n' ' ' < "$_pkgfile" 2>/dev/null)
  _known=" $(cut -f1 "$_list" 2>/dev/null | tr '\n' ' ') "
  _n=0
  _c=0
  while read -r _pkg; do
    [ -n "$_pkg" ] || continue
    _n=$((_n + 1))
    case "$_known" in
      *" $_pkg "*)
        # Already recorded in this idle period: these are our values, so there is
        # nothing to read and nothing to write down - just hold them in place.
        (
          bg_nice
          am set-standby-bucket "$_pkg" "$_bucket" >/dev/null 2>&1
          cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND deny >/dev/null 2>&1
          am make-uid-idle "$_pkg" >/dev/null 2>&1 || am make-uid-idle --user 0 "$_pkg" >/dev/null 2>&1
        ) & ;;
      *)
        (
          bg_nice
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
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
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
  _c=0
  while IFS=$TAB read -r _pkg _ob _nb _oo _no || [ -n "$_pkg" ]; do
    [ -n "$_pkg" ] || continue
    (
      bg_nice
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
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
  done < "$_list"
  wait
  rm -f "$_list"
}

# ============================================================ Frame rate
#
# The owner asked for a lower frame rate while the mode is on, and then found the
# lever that actually works on this phone, verified by him on the device:
#
#   su -c 'service call SurfaceFlinger 1035 i32 0 i64 0 f 30 f 30'   -> 30 fps
#   su -c 'service call SurfaceFlinger 1035 i32 0 i64 0 f 60 f 60'   -> 60 fps (the phone's own default)
#
# Transaction 1035 is SurfaceFlinger's own frame-rate override. It sits BELOW
# everything else this knob tried before: not a panel mode, not a settings key,
# not the ROM's Game Mode setting (which answers nothing here) - the compositor
# itself is told the rate, and every app and every screen follows, this mode's
# home included. It is a setter with no getter: there is nothing to read back and
# nothing to snapshot, so what is journalled is the fact that WE set it, and the
# exit always puts the phone's own 60 back with the owner's own restore command.
#
# 40 is still not a rate a 60 Hz panel can show - a rate must divide the refresh
# for the frames to land evenly - and 30 is what the option has always said.
# Default off: half the frame rate is visible, so it is only on when asked.
FPS_VALUE=${FPS_VALUE:-30}
FPS_RESTORE_VALUE=${FPS_RESTORE_VALUE:-60}

sf_set_fps() { # sf_set_fps <rate>
  has service || return 1
  service call SurfaceFlinger 1035 i32 0 i64 0 f "$1" f "$1" >/dev/null 2>&1
}

meta_fps_cap() {
  echo "Display|Frame rate capped at 30 fps|The whole screen is held to 30 frames per second while the mode is on. It needs one reboot after installation to arm; until then the option reports it is not ready and changes nothing.|0|session|battery"
}
# Nothing on the phone reports this rate back, so the snapshot is the fact that
# the knob is ours to undo, nothing more.
snapshot_fps_cap() { printf 'sf-fps\tset\n'; }
# The override must be armed before the command is safe: with it off, the very
# command that sets the rate crashes SurfaceFlinger and soft-reboots the phone
# - the owner proved that on this device. The module's own system.prop arms it
# at boot (the module manager writes it before SurfaceFlinger starts), so a
# refused application here means "one more reboot", never a prop written by
# this script at runtime.
sf_override_armed() {
  case "$(gprop ro.surface_flinger.enable_frame_rate_override)" in
    true) return 0 ;;
  esac
  return 1
}

apply_fps_cap() {
  if ! sf_override_armed; then
    log "fps: the phone's frame-rate override is still off - one more reboot after installing arms it (the module's system.prop does that at boot); until then the command is left alone, because with the override off it would crash the screen's compositor"
    return 2
  fi
  if ! sf_set_fps "$FPS_VALUE"; then
    log "fps: this phone has no service command, so the frame rate cannot be set"
    return 2
  fi
  log "fps: the whole screen is held to ${FPS_VALUE} frames a second while this mode is on (SurfaceFlinger, verified on this phone)"
  return 0
}
restore_fps_cap() { # <orig> <applied>
  sf_set_fps "$FPS_RESTORE_VALUE" || return 1
  log "fps: the screen's frame rate is put back to ${FPS_RESTORE_VALUE} (the phone's own default)"
  return 0
}
probe_fps_cap() {
  printf 'frame_rate\t%s while the mode is on, %s on exit (set by SurfaceFlinger command; the phone cannot read it back)\n' "$FPS_VALUE" "$FPS_RESTORE_VALUE"
}
probe_fps_cap_verdict() {
  printf 'works\tset by the owner-verified SurfaceFlinger command (%s fps); the phone cannot read it back, and the exit always puts %s back\n' "$FPS_VALUE" "$FPS_RESTORE_VALUE"
}
note_refused_fps_cap() {
  if ! sf_override_armed; then
    printf "the phone's frame-rate override is still off; one reboot after installing arms it, and then the cap works\n"
    return
  fi
  printf 'this phone has no service command, so the frame rate was not touched\n'
}
note_fps_cap() {
  printf "the screen is held to %s fps; the phone's own %s comes back on exit\n" "$FPS_VALUE" "$FPS_RESTORE_VALUE"
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
block_system_apps
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
cores_sleep
app_restrict
rom_bg_off
freeze_google
deep_doze
data_saver_idle
sync_off
battery_saver
blur_off
fps_cap
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

# A subshell and an awk each, to take one field out of a six-field line that is
# already in memory. Every knob loop in the engine calls both for every knob -
# the status the app polls spent 31 awks on nothing else - so the field is cut
# with parameter expansion instead. Same metadata, same fields, no process.
#
# meta is category|label|description|default|scope|tags.
knob_field() { # knob_field <id> <1-based field number>
  _kf=$(knob_meta "$1")
  _kn=$2
  while [ "$_kn" -gt 1 ]; do
    case "$_kf" in
      *'|'*) _kf=${_kf#*"|"} ;;
      *) printf ''; return ;;      # fewer fields than asked for: nothing to give
    esac
    _kn=$((_kn - 1))
  done
  printf '%s' "${_kf%%"|"*}"
}
knob_scope()   { knob_field "$1" 5; }
knob_default() { knob_field "$1" 4; }

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
# Which packages are suspended right now, one per line.
#
# `dumpsys package <pkg> | grep suspended=true` is one process per package, and
# on this phone a process costs a fifth of a second: twenty apps meant eighteen
# seconds of the exit, measured. The state lives in the file the system itself
# keeps, and this runs as root - so it is read once instead.
#
# Nothing is guessed: if the file is not there or nothing in it matches, this
# prints nothing and the caller falls back to asking the system per package -
# the same shape as every other device reading in this module.
SPSM_USERS=${SPSM_USERS:-/data/system/users}

suspended_packages() {
  _found=0
  for _f in "$SPSM_USERS"/*/package-restrictions.xml; do
    [ -f "$_f" ] || continue
    _found=1
    awk '
      {
        n = split($0, part, "<pkg ")
        for (i = 2; i <= n; i++) {
          if (part[i] !~ /suspended="true"/) continue
          if (match(part[i], /name="[^"]+"/)) {
            print substr(part[i], RSTART + 6, RLENGTH - 7)
          }
        }
      }
    ' "$_f" 2>/dev/null
  done
  [ "$_found" = 1 ]
}

# The last four are Android's own plumbing: the intent resolver (share and
# "open with" dialogs - suspended, the phone answers every share with "intent
# resolver isn't available"), the permission controller, the documents UI
# (file picker) and the media provider. The owner's v3.7.7 report caught the
# first of these: with "Restrict system apps too" on, suspending any of these
# breaks EVERY app, not the junk. Never options, never suspendable here.
ESSENTIALS="com.android.dialer com.android.server.telecom com.android.mms com.android.messaging com.google.android.apps.messaging com.android.providers.telephony com.android.phone com.android.deskclock com.android.systemui com.android.settings com.android.intentresolver com.android.permissioncontroller com.android.documentsui com.android.providers.media.module dev.axion.spsm"
ROOT_APPS="com.topjohnwu.magisk me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra com.resukisu.resukisu me.resukisu.resukisu com.resukisu.manager com.dergoogler.mmrl com.franco.kernel eu.chainfire.supersu com.koushikdutta.superuser com.noshufou.android.su"

# The packages that must keep working whatever the mode does: the essentials
# above, whatever root managers this phone has installed, the keyboard (a phone
# with no keyboard cannot answer anyone) and the launcher.
# Cached for the life of THIS process. The list costs eight binder round trips
# (three role lookups, two settings reads, the home holder, the HOME role and a
# query-activities), and it is rebuilt from scratch by each of the three callers
# that need it - blockable_packages, managed_packages and the background
# restrictor - inside a single activation. Nothing it reads can change during
# one engine run: the roles, the keyboards and the installed launchers are the
# user's configuration, not the mode's, and the mode's OWN home swap is applied
# after these lists are taken. So the second and third builds were eight binder
# calls each to recompute a byte-identical answer.
#
# Deliberately per-process and not a file: a cache on disk would have to be
# invalidated when the user changes their launcher or keyboard between runs,
# and getting that wrong means suspending someone's dialer. A variable dies
# with the engine process, so the next run always asks the phone again.
# The cache is a FILE, not a variable. Every caller invokes this inside a
# command substitution - `$(protected_packages | tr ...)` - which runs in a
# forked subshell, so a variable set here dies with that subshell and the next
# caller would miss every time. Verified in dash, sh and bash: a shell variable
# assigned inside $(...) is never visible to the next $(...).
#
# $$ scopes the file to this engine process, and $$ is the PARENT's pid inside
# a subshell in all three shells (checked), so every subshell of one run shares
# one cache and two concurrent runs cannot share each other's.
# One value per engine run. SPSM_RUN_ID is exported by engine.sh; the fallback
# keeps this working for anything that sources knobs.sh on its own.
_PROT_GEN="${SPSM_RUN_ID:-boot}"
# A value that differs between the parallel subshells of one run, without a
# fork. $$ is identical in all of them, so it cannot be used. A counter in the
# subshell's own memory plus SECONDS-free arithmetic is enough: the only
# requirement is that two concurrent builders do not pick the same name.
_PROT_SEQ=0
_prot_uniq() {
  _PROT_SEQ=$((_PROT_SEQ + 1))
  # The subshell's REAL pid, read out of /proc with a redirection - no fork.
  # $$ is the parent's in every subshell and so cannot separate them, and $!
  # was tried and rejected: it is empty (and therefore identical) in any
  # subshell that has not started a background job, which is most of them.
  # /proc/self/stat gives a distinct value in dash and bash alike; the counter
  # separates repeat calls within one subshell, and $$ keeps two concurrent
  # engine runs apart if /proc is unreadable.
  _pu=""
  read -r _pu _ < /proc/self/stat 2>/dev/null || _pu=""
  printf '%s' "tmp${_pu:-$$}.$_PROT_SEQ"
}
protected_packages() {
  # Where the cache lives. TMPDIR first (the test rigs set one, and a desktop
  # /tmp is fine); otherwise the module's own scratch dir - because /tmp DOES
  # NOT EXIST on Android outside Termux, and a cache path nobody can write is
  # a cache that never warms: every caller then paid the eight binder round
  # trips again, three times in one activation, while the phone waited.
  _pdir="${TMPDIR:-$SPSM_DIR/.tmp}"
  [ -d "$_pdir" ] || mkdir -p "$_pdir" 2>/dev/null
  _pc="$_pdir/.spsm-protected.$$"
  # Staleness is handled by a generation stamp rather than a `find` on every
  # call: `find` is itself a fork, which is the cost this cache exists to
  # avoid. The stamp is written by the run that built the cache, so a file left
  # by an earlier engine that happened to hold this pid is not mistaken for
  # ours - it simply fails to match and is rebuilt.
  #
  # An EXIT trap would be the tidier cleanup, but engine.sh installs no trap
  # today and adding one risks replacing a handler another path sets later -
  # the daemon already had a bug of exactly that shape, where a second
  # `trap ... TERM` silently replaced the first.
  # The hit path must not fork, or the cache costs more than it saves. The
  # first version used `head -1` to check the stamp and `tail -n +2` to print
  # the body - two forks per call, against the eight binder calls avoided. That
  # is a win for the callers that would rebuild, but screen-on only ever builds
  # the list once, so there it was pure loss: measured +49 forks on screen-on.
  # The stamp is read with the `read` builtin and the body with a single
  # redirection, so a hit now costs no process at all.
  if [ -s "$_pc" ]; then
    _pstamp=""
    read -r _pstamp < "$_pc" 2>/dev/null || _pstamp=""
    if [ "$_pstamp" = "#$_PROT_GEN" ]; then
      # Strip the stamp line without a fork: read it, then stream the rest.
      #
      # The final `[ -n "$_pl" ]` is not belt-and-braces. `read` returns false
      # on a last line that has no trailing newline, so the loop exits with
      # that line already in $_pl and never prints it - and the build's last
      # producer is home_holder, which ends with `printf '%s'` and no newline.
      # Without this the cached answer silently dropped the launcher, which is
      # precisely the package that must never be suspended.
      { read -r _
        while IFS= read -r _pl; do printf '%s\n' "$_pl"; done
        [ -n "$_pl" ] && printf '%s\n' "$_pl"
      } < "$_pc"
      return 0
    fi
  fi
  # A PRIVATE temp, then an atomic rename.
  #
  # $$ is the same in every subshell of a run, which is what lets the cache be
  # shared - but screen-on reverts its deep knobs six at a time in `( ... ) &`
  # subshells, so six of them can reach this line together. With one shared
  # "$_pc.tmp" they truncate each other's file and five of the six `mv`s fail
  # on a temp that another has already renamed away. Exactly the lost-update
  # shape as radio_forget, and it made the cache miss every time: measured 6/6
  # misses and five mv errors in a six-way race.
  #
  # The temp is made unique with a value that differs per subshell. Losing the
  # race is harmless here - every builder computes the same answer, so the last
  # rename simply wins and the others' work is discarded.
  _ptmp="$_pc.$(_prot_uniq)"
  { printf '#%s\n' "$_PROT_GEN"; _protected_packages_build; } > "$_ptmp" 2>/dev/null
  # Only publish a build that produced real content - the stamp line alone
  # means the build found nothing, and a cached empty answer would mean
  # "nothing is protected" for the rest of the run: the dialer and the
  # launcher would be suspended.
  # "more than just the stamp line" without forking a wc: read past the stamp
  # and see whether anything follows.
  _phas=""
  { read -r _ ; read -r _phas; } < "$_ptmp" 2>/dev/null || _phas=""
  if [ -n "$_phas" ]; then
    mv -f "$_ptmp" "$_pc" 2>/dev/null
    { read -r _
      while IFS= read -r _pl; do printf '%s\n' "$_pl"; done
      [ -n "$_pl" ] && printf '%s\n' "$_pl"
    } < "$_pc"
  else
    rm -f "$_ptmp" 2>/dev/null
    _protected_packages_build
  fi
}

_protected_packages_build() {
  printf '%s\n' $ESSENTIALS $ROOT_APPS
  # The phone's own ROLES - dialer, SMS, emergency - by whoever holds them.
  # On an AOSP ROM that is com.android.dialer and com.android.mms (both in
  # ESSENTIALS already); on a stock-OEM phone it is the maker's own apps,
  # with names no static list can know. The role manager is asked instead,
  # which is the one answer that is right on every ROM.
  for _role in android.app.role.DIALER android.app.role.SMS android.app.role.EMERGENCY; do
    _h=$(cmd role get-role-holders "$_role" 2>/dev/null | head -1)
    [ -n "$_h" ] && printf '%s\n' "$_h"
  done
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
  # And EVERY launcher, not just the current holder: while this mode's own
  # home holds the role, the user's real launcher holds nothing - and it was
  # suspended exactly then, every session, drifting the exit into the safety
  # valves. The owner carries two launchers; anything that can answer the
  # HOME category is somebody's home, and is never touched.
  cmd role get-role-holders android.app.role.HOME 2>/dev/null
  cmd package query-activities --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME 2>/dev/null |
    sed -n 's|^\([a-zA-Z0-9._]\{2,\}\)/.*|\1|p'
}

# Third-party apps this mode is allowed to suspend: everything except the apps
# the user allowed, the protected packages above, and anything Android is already
# exempting from battery optimisation (those are exempt for a reason - alarms,
# accessibility, and the like).
#
# "Restrict system apps too" (block_system_apps, OFF by default) widens this to
# the phone's OWN packages - on a stock-OEM phone the preinstalled junk is
# system apps, and that is where the rest of the saving lives. The protected
# list (essentials, root managers, keyboard, launcher, and now the role
# holders: dialer, SMS, emergency) still stands in front of it.
blockable_packages() {
  # ONE list per engine run, however many callers ask. A single activation
  # builds this three times - the before-snapshot, the apply's candidate
  # pass and the after-snapshot - and each build costs two `pm list` calls,
  # the protected-list binder round trips and a sort: 6-8s a pop on the
  # owner's phone (field, 2026-09-25: the 8s gap in front of "snap
  # block_other_apps" and candidates=6s behind it). Nothing the list is
  # built from - the installed packages, the keep lists, the protected
  # roles, the block_system_apps switch - changes during one engine run,
  # so the second and third builds were paying for a byte-identical answer.
  # The cache is named by SPSM_RUN_ID (per invocation, shared by every
  # subshell of it) and swept by tmp_sweep like every other scratch file.
  # The per-PACKAGE STATES are still read fresh where honesty requires it;
  # this caches only the candidate SET.
  _lc_dir="${TMPDIR:-$SPSM_DIR/.tmp}"
  _lc="$_lc_dir/.spsm-blockable.${SPSM_RUN_ID:-boot}"
  if [ -s "$_lc" ]; then cat "$_lc"; return 0; fi
  [ -d "$_lc_dir" ] || mkdir -p "$_lc_dir" 2>/dev/null
  _lt="$_lc.$(_prot_uniq)"
  _blockable_build > "$_lt" 2>/dev/null
  if [ -s "$_lt" ]; then
    if mv -f "$_lt" "$_lc" 2>/dev/null; then
      cat "$_lc"
    else
      # Lost the rename race against a parallel builder of the same run -
      # identical contents, so serve this build and drop the temp.
      cat "$_lt"; rm -f "$_lt" 2>/dev/null
    fi
  else
    # An empty list is never published as a cached answer (same rule as the
    # protected cache): a phone with no third-party apps still asks every run.
    rm -f "$_lt" 2>/dev/null
    _blockable_build
  fi
}

_blockable_build() {
  _keep=" $(cfg keep '') $(cat "$KEEP_AWAKE" 2>/dev/null | tr '\n' ' ') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') $(protected_packages | tr '\n' ' ') "
  _all=$(pm list packages -3 2>/dev/null | sed 's/^package://')
  if knob_enabled block_system_apps "$(knob_default block_system_apps)"; then
    _all="$_all $(pm list packages -s 2>/dev/null | sed 's/^package://')"
  fi
  # One sort, once, so a package in both lists costs one pass, not two writes.
  for _p in $(printf '%s\n' $_all | sort -u); do
    [ -n "$_p" ] || continue
    case "$_keep" in *" $_p "*) continue ;; esac
    case "$_p" in *rro*|*[Oo]verlay*) continue ;; esac
    echo "$_p"
  done
}

# The same widening for the per-app background restriction. OFF together with
# the suspension widening - one switch, one story: the phone's own apps are
# left to their own work unless the owner asks otherwise.
meta_block_system_apps() {
  echo "Apps|Restrict system apps too|Extends blocking and background limits to the phone's preinstalled apps - on a stock phone that is where the real saving is. Android's own essential services are never touched. On a clean ROM, leave it off.|0|session|breaks-features,control"
}
snapshot_block_system_apps() { :; }
apply_block_system_apps() { :; }
restore_block_system_apps() { :; }

managed_packages() {
  # One list per engine run, for exactly the reason blockable_packages caches
  # its own: a screen-off applies app_restrict AND rom_bg_off (and the deep
  # phase's own bookkeeping), each of which used to rebuild this from scratch
  # - a `dumpsys deviceidle whitelist` parse, two `pm list` calls and the
  # protected round trips, per caller, while the phone is trying to fall
  # asleep. The v3.4.1 log's seven-minute screen-off started with exactly
  # this duplication.
  _lc_dir="${TMPDIR:-$SPSM_DIR/.tmp}"
  _lc="$_lc_dir/.spsm-managed.${SPSM_RUN_ID:-boot}"
  if [ -s "$_lc" ]; then cat "$_lc"; return 0; fi
  [ -d "$_lc_dir" ] || mkdir -p "$_lc_dir" 2>/dev/null
  _lt="$_lc.$(_prot_uniq)"
  _managed_build > "$_lt" 2>/dev/null
  if [ -s "$_lt" ]; then
    if mv -f "$_lt" "$_lc" 2>/dev/null; then
      cat "$_lc"
    else
      cat "$_lt"; rm -f "$_lt" 2>/dev/null
    fi
  else
    rm -f "$_lt" 2>/dev/null
    _managed_build
  fi
}

_managed_build() {
  _keep=" $(cfg keep '') $(cat "$KEEP_AWAKE" 2>/dev/null | tr '\n' ' ') $(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null | tr '\n' ' ') $(protected_packages | tr '\n' ' ') "
  _exempt=$(dumpsys deviceidle whitelist 2>/dev/null | sed -n 's/^ *[a-z-]*,\([a-zA-Z0-9_.]*\),.*/\1/p' | sort -u)
  _all=$(pm list packages -3 2>/dev/null | sed 's/^package://')
  if knob_enabled block_system_apps "$(knob_default block_system_apps)"; then
    _all="$_all $(pm list packages -s 2>/dev/null | sed 's/^package://')"
  fi
  # `echo "$_exempt" | grep -q "$_p"` inside this loop was a process per
  # installed app - about a hundred of them, twice per idle period - and it is
  # what made the app list the slowest single step of an activation on the
  # device (69 seconds, in the v3.6.1 log). The same test against a string costs
  # nothing and returns the same answer.
  _ex_s=" $(printf '%s\n' $_exempt | tr '\n' ' ') "
  for _p in $_all; do
    [ -n "$_p" ] || continue
    case "$_keep" in *" $_p "*) continue ;; esac
    case "$_ex_s" in *" $_p "*) continue ;; esac
    case "$_p" in *rro*|*[Oo]verlay*) continue ;; esac
    echo "$_p"
  done
}
