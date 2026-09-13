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

  if [ "$(norm "$(j_orig "$_id")")" = "$(norm "$_now")" ]; then
    log "note $_id: no visible change (optional node missing?)"
  fi
  return 0
}

knob_revert() { # knob_revert id
  _id=$1
  _fn="restore_$_id"
  _st=$(j_state "$_id")

  # Only undo what we actually applied. A knob that was disabled at apply time,
  # or already reverted, must not be touched.
  case "$_st" in
    applied) ;;
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
      log "WARN $_id did not return to its original value" ;;
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
  j_reset
  log "===== SPSM v3 ON ====="

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

  start_daemon
  tmp_sweep
  progress "On"
  log "SPSM ON: $(applied_count) knobs applied in $(( $(date +%s) - _t0 ))s"
  lock_release
  return 0
}

do_deactivate() {
  lock_acquire || { log "deactivate: busy"; return 1; }
  _t0=$(date +%s)
  log "===== SPSM v3 OFF ====="
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

do_screen_on() {
  still_on || return 0
  lock_acquire || return 0
  # Same re-check as the screen-off path: a daemon that was killed on exit can
  # still have this child in flight, and it must not start waking the phone up
  # after the mode is already off.
  [ -f "$ACTIVE" ] || { lock_release; return 0; }
  log "screen on -> release deep phase"
  for _k in $DEEP_FAST; do
    [ "$(knob_scope "$_k")" = "deep" ] && knob_revert "$_k"
  done
  for _k in $(knobs_all); do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    case " $DEEP_FAST " in *" $_k "*) continue ;; esac
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
  echo "screen=$(screen_state)"
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
  sh "$DAEMON" >>"$LOG" 2>&1 &
  echo $! > "$DAEMON_PID"
  log "daemon started (pid $(cat "$DAEMON_PID" 2>/dev/null))"
}

stop_daemon() {
  if daemon_running; then
    _p=$(cat "$DAEMON_PID" 2>/dev/null)
    kill "$_p" 2>/dev/null
    log "daemon stopped (pid $_p)"
  fi
  rm -f "$DAEMON_PID"
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
  status)     do_status ;;
  dump-knobs) do_dump_knobs ;;
  start-daemon) start_daemon ;;
  stop-daemon)  stop_daemon ;;
  toggle)
    if [ -f "$ACTIVE" ]; then do_deactivate; else do_activate; fi ;;
  *)
    echo "usage: engine.sh activate|deactivate|screen-off|screen-on|toggle|set <knob> <0|1>|verify|status|dump-knobs|start-daemon|stop-daemon"
    exit 2 ;;
esac
