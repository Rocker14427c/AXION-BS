#!/system/bin/sh
# Axion SPSM v3 - apply / revert engine.
#
#   engine.sh activate      apply every enabled session knob
#   engine.sh deactivate    revert everything we changed
#   engine.sh screen-off    apply the "deep" (screen-off only) knobs
#   engine.sh screen-on     revert the deep knobs
#   engine.sh set <knob> <0|1>   flip one knob live
#   engine.sh verify        re-read everything and report drift
#   engine.sh status        machine-readable state for the APK
#   engine.sh dump-knobs    write knobs.list for the APK options screen
#
# The revert guarantee: for every knob we save the value that was there BEFORE
# we touched it, and separately the value we wrote. On revert we re-read the
# live value and only write the old one back if the live value is still ours.
# If anything else changed it in the meantime, we leave it alone and log it.
# Nothing is ever restored from a guess, and no knob is restored that we did
# not actually apply.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/knobs.sh"

# ------------------------------------------------------------------ one knob

knob_apply() { # knob_apply id
  _id=$1
  # Published for the apply functions: it tells them which journal record holds
  # the original they must not stray from (see apply_kv).
  KNOB_ID=$_id
  _fn="apply_$_id"
  [ "$(type "$_fn" 2>/dev/null)" ] || { log "no apply function for $_id"; return 1; }

  # Remember what the knob looked like before we touch it. "Before" means before
  # THIS application, not before this session: when a value has already been
  # released (the deep phase let go on wake) applying it again must record the
  # value that is current then. Keeping the first snapshot of the session would
  # restore a value the phone has since moved past.
  _st=$(j_state "$_id")
  if ! j_has "$_id" || [ -z "$_st" ] || [ "$_st" = "restored" ] || [ "$_st" = "left" ]; then
    _snap=$("snapshot_$_id" 2>/dev/null)
    j_record_orig "$_id" "$_snap"
    log "snap $_id: $(unesc "$_snap" | tr '\n' ' ' | cut -c1-160)"
  fi

  "$_fn"
  _rc=$?

  # One snapshot, not two. The "before" reading only ever fed the note below, and
  # the original that is already on record answers the same question for the case
  # that matters (the first application of a session). On a phone that spends a
  # fifth of a second answering each settings read, a whole snapshot per knob is
  # seconds off every activation.
  _now=$("snapshot_$_id" 2>/dev/null)
  j_record_applied "$_id" "$_now"
  j_write_meta "$_id" knob "$_id"
  j_order_add "$_id"

  # An apply function may put its own change back and say so by returning 2.
  # The home swap does this when the new home does not come up: the change was
  # made, seen to fail, and undone. Recording it as applied would make a later
  # revert chase a value that is already right, and would make verify report the
  # change we deliberately undid as one we broke.
  if [ "$_rc" = "2" ]; then
    j_record_state "$_id" restored
    log "note $_id: applied, did not take, and was put back by the module"
    return 0
  fi

  # Otherwise a knob counts as applied even if the apply function reported
  # trouble: a partial change is precisely the case where the revert MUST run.
  j_record_state "$_id" applied

  # A control option has nothing of its own to change, so the note would be
  # noise on every single activation.
  case "$(knob_meta "$_id" | cut -d'|' -f7)" in
    *control*) ;;
    *)
      if [ "$(norm "$(j_orig "$_id")")" = "$(norm "$_now")" ]; then
        log "note $_id: no visible change (optional node missing?)"
      fi
      ;;
  esac
  return 0
}

knob_revert() { # knob_revert id
  _id=$1
  _fn="restore_$_id"
  _st=$(j_state "$_id")

  # Only undo what we actually applied. A knob that was disabled at apply time,
  # or already reverted, must not be touched.
  #
  # "restored-drift" is included on purpose: it means a previous revert ran and
  # could not put something back, so our value may still be in place. Retrying is
  # safe - every restore function writes only what is still ours to write - and
  # without the retry those records are skipped forever while still being counted
  # as drift, which is how this phone reported "3 value(s) could not be restored"
  # while naming only one.
  case "$_st" in
    applied|restored-drift) ;;
    *) return 0 ;;
  esac
  [ "$(type "$_fn" 2>/dev/null)" ] || { log "no restore function for $_id"; return 1; }

  # Both snapshots go to the restore function: it decides per value whether
  # that value is still ours to undo.
  # The journal files are already one target per line, so they are handed over
  # as they are; restore_kv decodes each value on the way out to the device.
  cp -f "$JOURNAL/$_id.orig" "$JOURNAL/$_id.orig.txt" 2>/dev/null
  cp -f "$JOURNAL/$_id.applied" "$JOURNAL/$_id.applied.txt" 2>/dev/null
  "$_fn" "$JOURNAL/$_id.orig.txt" "$JOURNAL/$_id.applied.txt"
  _rc=$?
  rm -f "$JOURNAL/$_id.orig.txt" "$JOURNAL/$_id.applied.txt"

  _after=$("snapshot_$_id" 2>/dev/null)
  case "$(revert_verdict "$_after" "$(j_orig "$_id")" "$(j_applied "$_id")")" in
    restored)
      j_record_state "$_id" restored ;;
    kept)
      j_record_state "$_id" left
      log "keep $_id: a value was changed externally since we applied it" ;;
    *)
      j_record_state "$_id" restored-drift
      # The values, not just the verdict. "did not return to its original value"
      # from the device log was impossible to act on: which value, and to what?
      log "WARN $_id did not return: want [$(unesc "$(j_orig "$_id")" | tr '\n' ' ' | cut -c1-200)] got [$(unesc "$_after" | tr '\n' ' ' | cut -c1-200)]" ;;
  esac
  return $_rc
}

# ------------------------------------------------------------------ phases

# Undo in the reverse of the order things were applied.
knobs_reversed() {
  _rev=""
  for _k in $(knobs_all); do _rev="$_k $_rev"; done
  printf '%s' "$_rev"
}

phase_session() { # apply|revert
  _mode=$1
  [ "$_mode" = revert ] && _list=$(knobs_reversed) || _list=$(knobs_all)
  for _k in $_list; do
    [ "$(knob_scope "$_k")" = "deep" ] && continue
    if [ "$_mode" = apply ]; then
      knob_enabled "$_k" "$(knob_default "$_k")" || continue
      progress "Applying: $(knob_meta "$_k" | cut -d'|' -f2)"
      knob_apply "$_k"
    else
      knob_revert "$_k"
    fi
  done
}

phase_deep() { # apply|revert
  _mode=$1
  [ "$_mode" = revert ] && _list=$(knobs_reversed) || _list=$(knobs_all)
  for _k in $_list; do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    if [ "$_mode" = apply ]; then
      knob_enabled "$_k" "$(knob_default "$_k")" || continue
      progress "Idle: $(knob_meta "$_k" | cut -d'|' -f2)"
      knob_apply "$_k"
    else
      knob_revert "$_k"
    fi
  done
}

# Reverting a deep phase must also undo knobs that are still applied, so it
# walks the reverse of the order they were applied in.
phase_deep_revert() {
  for _k in $(knobs_reversed); do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    knob_revert "$_k"
  done
}

# ------------------------------------------------------------------ commands

do_activate() {
  lock_acquire || { log "activate: busy"; return 1; }
  progress "Starting"
  rm -f "$STATE/doze_forced"

  if [ -f "$ACTIVE" ]; then
    # Already on. Re-applying every knob here costs the phone a whole pass - 25
    # seconds, measured on the device - for no benefit: the values are in place,
    # and the daemon re-asserts the deep phase on every screen-off anyway. What
    # this case actually has to guarantee is the daemon and the deep phase.
    log "activate: already on - ensuring the daemon and the deep phase"
    if [ "$(screen_state)" = "off" ]; then
      phase_deep apply
    fi
    start_daemon
    progress "On"
    lock_release
    return 0
  fi

  _t0=$(date +%s)
  sync_scripts
  j_reset
  log "===== SPSM v3 ON (scripts $(scripts_stamp), module $(spsm_version)) ====="

  # The visible switch first: the user should see the black home in about a
  # second, and the expensive parts (package lists, doze) run after it.
  knob_enabled home_swap "$(knob_default home_swap)" && knob_apply home_swap

  phase_session apply
  touch "$ACTIVE"
  rm -f "$STATE/request_deactivate"

  # Only pre-apply the deep phase if the screen is already off.
  if [ "$(screen_state)" = "off" ]; then
    phase_deep apply
  fi

  # The performance limits, kept from the start when the user asked for them.
  if cap_always_on; then
    for _k in $PERF_KNOBS; do
      knob_enabled "$_k" "$(knob_default "$_k")" || continue
      progress "Applying: $(knob_meta "$_k" | cut -d'|' -f2)"
      knob_apply "$_k"
    done
    log "cap_always: performance limits applied now, with the screen on"
  fi

  start_daemon
  tmp_sweep
  progress "On"
  log "SPSM ON: $(applied_count) knobs applied in $(( $(date +%s) - _t0 ))s"
  lock_release
  return 0
}

do_deactivate() {
  # High priority: the exit is the promise. It ends an in-flight screen
  # transition rather than queueing behind it.
  lock_acquire high || { log "deactivate: busy"; return 1; }
  _t0=$(date +%s)
  sync_scripts
  log "===== SPSM v3 OFF (scripts $(scripts_stamp), module $(spsm_version)) ====="
  progress "Restoring"

  # The mode is off from this point, before anything is put back. A screen-off
  # that was already in flight (or one the daemon starts in the next few
  # milliseconds) must not re-apply deep knobs behind the revert - that is the
  # one race that could leave a change behind on exit.
  rm -f "$ACTIVE"

  # Deep phase first (it holds the system-wide switches), then the session.
  phase_deep_revert
  phase_session revert

  # Which safety net is right depends on whether anything was actually left
  # behind - not on whether a journal exists. A session where every knob was
  # switched off records nothing, and forcing cores, governor and backlight on
  # the way out would then overwrite choices the user made for themselves.
  #
  # The answer comes from the journal, which the revert has just written, rather
  # than from re-reading every value on the device: that second full pass was ten
  # seconds of a phone's time on the way out, to re-ask a question the revert had
  # answered milliseconds earlier. `engine.sh verify` is still the honest
  # end-to-end read, and it is what a human runs when they want the truth.
  DRIFT=$(drift_from_journal)
  _took=$(( $(date +%s) - _t0 ))
  if [ "$(pending_knobs)" = "0" ]; then
    log "exit: nothing of ours is left in place, so nothing needs forcing"
  elif [ "${DRIFT:-0}" != "0" ]; then
    # A value of ours is still in place after a full revert pass. This is the
    # case forcing exists for: better a phone that is obviously usable than one
    # that is quietly capped.
    log "exit: ${DRIFT} value(s) could not be restored - forcing the safety valves"
    safety_force
  else
    safety_unlock
  fi

  if [ "${DRIFT:-0}" = "0" ]; then
    log "revert clean in ${_took}s: every change returned to its original value"
    progress "Off"
  else
    log "revert finished in ${_took}s with $DRIFT drifted knob(s) - see journal"
    progress "Off ($DRIFT kept)"
  fi

  stop_daemon
  touch "$STATE/last_exit_ok"
  lock_release
  return 0
}

do_screen_off() {
  still_on || return 0
  lock_acquire || return 0
  # Re-checked under the lock: the exit may have started while we waited.
  [ -f "$ACTIVE" ] || { lock_release; return 0; }
  log "screen off -> deep phase"
  phase_deep apply
  # Written down here, while the caps are in place: by the time anyone looks at
  # the phone the screen is on again and everything is deliberately back to
  # normal, so this line is the only honest record of what the idle state was.
  deep_report
  lock_release
}

# Fast knobs first on wake: CPU/GPU state is what you feel in the first
# second. The slow ones (per-package appops) can finish after the phone is
# already responsive.
DEEP_FAST="cpu_offline_big cpu_cap gpu_cap ged_boost_off deep_doze"

# The deep knobs that are about speed and heat rather than about sleeping: the
# CPU and GPU ceilings, the offline big cores, the boost switches. These are the
# ones someone may want held while the phone is in use (cap_always), and the ones
# a kernel manager looks at - so when cap_always is on they are applied as soon
# as the mode is switched on, instead of only when the screen goes off.
PERF_KNOBS="cpu_cap gpu_cap cpu_offline_big ged_boost_off"
cap_always_on() { knob_enabled cap_always "$(knob_default cap_always)"; }

do_screen_on() {
  still_on || return 0
  lock_acquire || return 0
  # Same re-check as the screen-off path: a daemon that was killed on exit can
  # still have this child in flight, and it must not start waking the phone up
  # after the mode is already off.
  [ -f "$ACTIVE" ] || { lock_release; return 0; }
  log "screen on -> release deep phase"
  for _k in $DEEP_FAST; do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    # With cap_always the speed limits stay: that is the point of the option.
    # Doze and the background restriction never stay - those are about sleeping,
    # and holding them while the phone is in use would break the apps the user
    # allowed.
    if cap_always_on; then
      case " $PERF_KNOBS " in *" $_k "*) continue ;; esac
    fi
    knob_revert "$_k"
  done
  for _k in $(knobs_all); do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    case " $DEEP_FAST " in *" $_k "*) continue ;; esac
    if cap_always_on; then
      case " $PERF_KNOBS " in *" $_k "*) continue ;; esac
    fi
    knob_revert "$_k"
  done
  # Only after every comparison is done, in case a knob did not come back.
  safety_unlock
  # The idle state is over; the report file is cleared so that `status` never
  # shows caps that are no longer in place.
  rm -f "$STATE/deep_report"
  lock_release
}

do_set() { # do_set knob 0|1
  _k=$1; _v=$2
  knob_exists "$_k" || { echo "unknown knob: $_k"; return 2; }
  case "$_v" in
    0|1) ;;
    *) echo "bad value for $_k: $_v (expected 0 or 1)"; return 2 ;;
  esac
  _cur=$(cfg "knob.$_k" "$(knob_default "$_k")")
  # Persist, then make it true right now if the mode is running.
  if grep -q "^knob\.$_k=" "$CONFIG" 2>/dev/null; then
    sed -i "s/^knob\.$_k=.*/knob.$_k=$_v/" "$CONFIG"
  else
    echo "knob.$_k=$_v" >> "$CONFIG"
  fi
  if [ -f "$ACTIVE" ]; then
    lock_acquire || return 0
    if [ "$_v" = "1" ]; then
      # Enabling mid-session. A session knob takes effect now. A deep knob only
      # means anything while the screen is off, so apply it now if we are
      # asleep and otherwise let the next screen-off cycle pick it up.
      _sc=$(knob_scope "$_k")
      if [ "$_sc" = "session" ] || [ "$(screen_state)" = "off" ]; then
        knob_apply "$_k"
      fi
      log "live enable $_k ($_sc)"
    else
      knob_revert "$_k"
      log "live disable $_k"
    fi
    lock_release
  fi
  echo "$_k=$_v (was $_cur)"
}

do_verify() { # do_verify [quiet]
  DRIFT=0
  _checked=0
  _ran=0
  for _k in $(knobs_all); do
    _st=$(j_state "$_k")
    case "$_st" in
      applied)
        # Still meant to be applied right now.
        ;;
      restored)
        _checked=$((_checked + 1))
        _now=$("snapshot_$_k" 2>/dev/null)
        case "$(revert_verdict "$_now" "$(j_orig "$_k")" "$(j_applied "$_k")")" in
          restored) ;;
          kept) _ran=$((_ran + 1)) ;;
          *)
            DRIFT=$((DRIFT + 1))
            log "DRIFT $_k: want [$(unesc "$(j_orig "$_k")" | tr '\n' ' ')] got [$(unesc "$_now" | tr '\n' ' ')]"
            ;;
        esac
        ;;
      restored-drift) DRIFT=$((DRIFT + 1)) ;;
      left) _ran=$((_ran + 1)) ;;
    esac
  done
  [ "$1" = quiet ] || echo "checked=$_checked drift=$DRIFT left-alone=$_ran"
  return 0
}

applied_count() {
  _n=0
  for _k in $(knobs_all); do [ "$(j_state "$_k")" = applied ] && _n=$((_n + 1)); done
  echo "$_n"
}

do_status() {
  if [ -f "$ACTIVE" ]; then echo "active=1"; else echo "active=0"; fi
  # Called directly, not through $(screen_state): a command substitution runs in
  # a subshell, and SCREEN_SRC/PANEL_RAW are set by the decision - asking through
  # $( ) throws away exactly the evidence this line exists to print.
  screen_decide "$(rd "$BL_PATH")" ''
  echo "screen=$SCREEN_STATE"
  # Which source answered, and whether the daemon that acts on it is alive. The
  # second one is the difference between "the mode is doing nothing" and "the
  # mode is not running".
  echo "screen_source=$SCREEN_SRC"
  echo "panel=${PANEL_RAW:--}"
  echo "scripts=$(scripts_stamp)"
  echo "module=$(spsm_version)"
  if [ -f "$STATE/probe.tsv" ]; then
    _w=0; _i=0; _p=0; _u=0
    while IFS=$TAB read -r _k _v _d; do
      case "$_v" in
        works) _w=$((_w + 1)) ;;
        inert) _i=$((_i + 1)) ;;
        partial) _p=$((_p + 1)) ;;
        *) _u=$((_u + 1)) ;;
      esac
    done < "$STATE/probe.tsv"
    echo "probe=works:$_w inert:$_i partial:$_p unknown:$_u (engine.sh probe for details)"
  else
    echo "probe=not run yet (engine.sh probe)"
  fi
  if daemon_running; then
    echo "daemon=$(cat "$DAEMON_PID" 2>/dev/null)"
  else
    echo "daemon=none"
  fi
  echo "applied=$(applied_count)"
  echo "progress=$(cat "$PROGRESS" 2>/dev/null)"
  echo "last_exit_ok=$([ -f "$STATE/last_exit_ok" ] && echo 1 || echo 0)"
  echo "home=$(home_holder)"
  if [ -f "$STATE/deep_report" ]; then
    echo "deep=$(cat "$STATE/deep_report" 2>/dev/null)"
  else
    echo "deep=released"
  fi
  for _k in $(knobs_all); do
    _m=$(knob_meta "$_k")
    _en=0; knob_enabled "$_k" "$(knob_default "$_k")" && _en=1
    echo "knob=$_k|$_en|$(j_state "$_k" 2>/dev/null)"
  done
}

# The APK reads this file to build the options screen, so the labels the user
# sees can never drift from what the scripts actually do.
do_dump_knobs() {
  : > "$KNOBS_LIST"
  for _k in $(knobs_all); do
    echo "$_k|$(knob_meta "$_k")" >> "$KNOBS_LIST"
  done
  echo "wrote $KNOBS_LIST"
}

still_on() { [ -f "$ACTIVE" ] && [ ! -f "$STATE/request_deactivate" ]; }

# ------------------------------------------------------------------ daemon
DAEMON="$SCRIPT_DIR/daemon.sh"
DAEMON_PID="$SPSM_DIR/daemon.pid"

# A pid on its own is not proof: the file survives reboots and pids get reused,
# so trusting it would mean - at worst - killing a stranger on the next boot.
# The process is only ours if its command line still says daemon.sh.
daemon_running() {
  _p=$(cat "$DAEMON_PID" 2>/dev/null)
  [ -n "$_p" ] || return 1
  [ -d "/proc/$_p" ] || return 1
  case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
    *daemon.sh*) return 0 ;;
  esac
  return 1
}

start_daemon() {
  [ -f "$DAEMON" ] || return 0
  daemon_running && return 0
  # Its own session when the phone has setsid: the daemon is normally started
  # from a shell that belongs to the app, and a force-stop of that app must not
  # be able to end the loop whose whole job is watching the screen. The daemon
  # writes its own pid file - through setsid, $! is not the process that runs.
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$DAEMON" >>"$LOG" 2>&1 &
  else
    sh "$DAEMON" >>"$LOG" 2>&1 &
  fi
  _dp=''
  _w=0
  while [ $_w -lt 10 ]; do
    _dp=$(cat "$DAEMON_PID" 2>/dev/null)
    [ -n "$_dp" ] && break
    sleep 0.1
    _w=$((_w + 1))
  done
  log "daemon started (pid ${_dp:-starting})"
}

stop_daemon() {
  if daemon_running; then
    _p=$(cat "$DAEMON_PID" 2>/dev/null)
    kill "$_p" 2>/dev/null
    log "daemon stopped (pid $_p)"
  fi
  rm -f "$DAEMON_PID"
}

# ------------------------------------------------------------------ probe
# Which options actually do something on THIS phone.
#
# The user's complaint was exact: options sat in the list that toggled but did
# nothing here, and there was no way to tell which was which without reading a
# log. Every knob is a device control, so the honest answer is to try it: record
# the value, apply, read the phone, undo, read again. That is what this does, and
# the verdict is written to state/probe.tsv for the app to show next to each
# option.
#
# It refuses to run while the mode is on (probe writes into its own scratch
# journal, and a live session's journal is not its to touch) and it never leaves
# anything behind: every knob it touches is reverted before the next one.
PROBE_DIR="$SPSM_DIR/probe"

probe_one() { # probe_one <knob> -> "verdict<TAB>detail"
  _k=$1
  # A control option changes how the others are applied rather than changing the
  # phone itself, so there is nothing on the device to try. Saying "could not
  # check" about it would be a false alarm.
  case "$(knob_meta "$_k" | cut -d'|' -f7)" in
    *control*) printf 'preference\tnot a device change: it decides how the other options are applied'; return 0 ;;
  esac
  # NOT "_snap": knob_apply assigns to a variable of that name (it holds the
  # snapshot text), and there are no locals in POSIX sh - so the name of the
  # function to call was being overwritten by the very call it was used for, and
  # every reading after the apply came back empty. That is how a probe reports
  # "changed ... did not come back" for an option that did nothing at all.
  _snapfn="snapshot_$_k"
  [ "$(type "$_snapfn" 2>/dev/null)" ] || { printf 'unknown\tno snapshot function'; return 0; }
  [ "$(type "apply_$_k" 2>/dev/null)" ] || { printf 'unknown\tno apply function'; return 0; }

  _before=$(probe_reading "$_k" "$_snapfn")
  if [ -z "$(norm "$_before")" ]; then
    printf 'unknown\tcould not read anything this option controls on this phone'
    return 0
  fi
  knob_apply "$_k" >/dev/null 2>&1
  _after=$(probe_reading "$_k" "$_snapfn")
  _did=$(snap_diff "$_before" "$_after")
  knob_revert "$_k" >/dev/null 2>&1
  _back=$(probe_reading "$_k" "$_snapfn")
  _undid=$(snap_diff "$_before" "$_back")

  if [ "$_did" = "no change" ]; then
    # Nothing moved, so there is nothing to undo either. Say why as best we can:
    # an option that is already in the state it wants is inert, not broken.
    printf 'inert\tnothing to change on this phone: %s' "$(short_detail "$_before")"
  elif [ "$_undid" = "no change" ]; then
    printf 'works\t%s' "$_did"
  else
    printf 'partial\tchanged (%s) but did not come back (still: %s)' "$_did" "$_undid"
  fi
}

# One reading of the knob: its snapshot, plus anything its probe_<id> hook adds.
# The hook exists because some options change something their snapshot cannot see
# - a radio is switched without the setting moving, Play Services is suspended
# rather than disabled - and a verdict based only on the snapshot would be wrong.
probe_reading() { # probe_reading <knob> <snapshot-function>
  "$2" 2>/dev/null
  printf '\n'
  _pf="probe_$1"
  [ "$(type "$_pf" 2>/dev/null)" ] && "$_pf" 2>/dev/null
  return 0
}

# One line of "what this phone had", for an inert verdict - enough for a person
# to see that the option was already satisfied.
short_detail() {
  printf '%s\n' "$1" | awk -F"\t" 'NF>=2 { printf "%s=%s ", $1, $2 }' | cut -c1-140
}

# Why a probe can decline, in words the app can show and a person can act on.
PROBE_NEEDS_OFF="SPSM is ON. The check writes and undoes every option, so it needs the mode switched off first: turn SPSM off, then run it again."
PROBE_NEEDS_IDLE="SPSM is busy (a screen change or an exit is in flight). Wait a few seconds and try again."

do_probe() { # do_probe [knob-id]
  _only=$1
  # The lock wait is short here on purpose: this is a diagnostic, not the exit,
  # and it must not push anything else around. If the engine is mid-transition it
  # says so instead of waiting it out - the device report was a check that
  # "finished" in three seconds and changed nothing, because it gave up quietly.
  if ! lock_acquire; then
    echo "$PROBE_NEEDS_IDLE"
    log "probe: declined - $PROBE_NEEDS_IDLE"
    return 1
  fi
  if [ -f "$ACTIVE" ]; then
    lock_release
    echo "$PROBE_NEEDS_OFF"
    log "probe: declined - $PROBE_NEEDS_OFF"
    return 1
  fi
  sync_scripts
  # The report belongs to the phone, not to the scratch area that gets deleted
  # at the end of this run.
  _PROBE_REPORT="$STATE/probe.tsv"
  rm -rf "$PROBE_DIR"
  mkdir -p "$PROBE_DIR/journal/orig" "$PROBE_DIR/state" 2>/dev/null
  : > "$_PROBE_REPORT"

  # Point the journalling machinery at the scratch area for the duration: the
  # probe must not touch the real journal, and its reverts must not be confused
  # with a session's.
  # Only the journal paths move into the scratch area. The LOG stays where it is:
  # the first version pointed it at the scratch dir as well and then deleted that
  # dir, so the probe's own findings - the one thing the user asked for - were
  # destroyed by the run that produced them.
  _J=$JOURNAL; _O=$ORIG_DIR; _S=$STATE
  JOURNAL="$PROBE_DIR/journal"; ORIG_DIR="$PROBE_DIR/journal/orig"; STATE="$PROBE_DIR/state"

  _list=$(knobs_all)
  [ -n "$_only" ] && _list=$_only
  log "probe: starting (module $(spsm_version), $(echo "$_list" | wc -w) option(s))"
  _n=0; _works=0; _inert=0; _partial=0; _pref=0; _unknown=0
  for _k in $_list; do
    knob_exists "$_k" || { echo "$_k: no such option"; _n=$((_n + 1)); _unknown=$((_unknown + 1)); continue; }
    _v=$(probe_one "$_k")
    _verdict=${_v%%	*}
    _detail=${_v#*	}
    printf '%s\t%s\t%s\n' "$_k" "$_verdict" "$_detail" >> "$_PROBE_REPORT"
    case "$_verdict" in
      works)      _works=$((_works + 1)) ;;
      inert)      _inert=$((_inert + 1)) ;;
      partial)    _partial=$((_partial + 1)) ;;
      preference) _pref=$((_pref + 1)) ;;
      *)          _unknown=$((_unknown + 1)) ;;
    esac
    _n=$((_n + 1))
    log "probe $_k: $_verdict - $_detail"
    echo "$_k: $_verdict - $_detail"
  done
  log "probe: done - $_works work, $_inert inert, $_partial partial, $_pref preferences, $_unknown unknown, of $_n"
  echo "works=$_works inert=$_inert partial=$_partial preference=$_pref unknown=$_unknown total=$_n"
  echo "report: $_PROBE_REPORT"

  # The scratch journal is ours alone and is finished with; nothing of it may
  # survive into a real session.
  JOURNAL="$_J"; ORIG_DIR="$_O"; STATE="$_S"
  rm -rf "$PROBE_DIR"
  lock_release
  return 0
}

# ------------------------------------------------------------------ dispatch
CMD=$1
case "$CMD" in
  activate)   do_activate ;;
  deactivate) do_deactivate ;;
  screen-off) do_screen_off ;;
  screen-on)  do_screen_on ;;
  set)        do_set "$2" "$3" ;;
  verify)     do_verify ;;
  probe)      do_probe ;;
  version)    echo "scripts=$(scripts_stamp) module=$(spsm_version) code=$SPSM_CODE_VERSION" ;;
  status)     do_status ;;
  dump-knobs) do_dump_knobs ;;
  start-daemon) start_daemon ;;
  stop-daemon)  stop_daemon ;;
  toggle)
    if [ -f "$ACTIVE" ]; then do_deactivate; else do_activate; fi ;;
  *)
    echo "usage: engine.sh activate|deactivate|screen-off|screen-on|toggle|set <knob> <0|1>|verify|probe|status|version|dump-knobs|start-daemon|stop-daemon"
    exit 2 ;;
esac
