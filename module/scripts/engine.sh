#!/system/bin/sh
# Axion SPSM v3 - apply / revert engine.
#
#   engine.sh activate      apply every enabled session knob
#   engine.sh deactivate    revert everything we changed
#   engine.sh screen-off    apply the "deep" (screen-off only) knobs
#   engine.sh screen-on     revert the deep knobs
#   engine.sh set <knob> <0|1>   flip one knob live
#   engine.sh verify        re-read everything and report drift
#   engine.sh recents       the task list, read without starting the launcher
#   engine.sh gesture <how>  note in the log that the recents list was opened
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
# Identifies THIS engine run to the per-process caches (see
# protected_packages in knobs.sh). It must be set before the libraries are
# sourced so anything they cache at source time belongs to this run. $$ alone
# is not enough - pids are reused - so the start time goes in too.
SPSM_RUN_ID="$$-$(date +%s 2>/dev/null || echo 0)"
export SPSM_RUN_ID
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/knobs.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/recents.sh"

# ------------------------------------------------------------------ one knob

knob_apply() { # knob_apply id
  _id=$1
  # Published for the apply functions: it tells them which journal record holds
  # the original they must not stray from (see apply_kv).
  KNOB_ID=$_id
  _fn="apply_$_id"
  has_function "$_fn" || { log "no apply function for $_id"; return 1; }

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
    # A knob that can explain its own refusal should: "would not say" and
    # "applied and put back" are different facts, and the one generic sentence
    # said the wrong thing for the frame-rate knob - nothing had even been
    # attempted when this ROM's device log showed it.
    if has_function "note_refused_$_id"; then
      log "note $_id: $("note_refused_$_id")"
    else
      log "note $_id: applied, did not take, and was put back by the module"
    fi
    return 0
  fi

  # Otherwise a knob counts as applied even if the apply function reported
  # trouble: a partial change is precisely the case where the revert MUST run.
  j_record_state "$_id" applied

  # A control option has nothing of its own to change, so the note would be
  # noise on every single activation.
  case "$(knob_meta "$_id" | cut -d'|' -f6)" in
    *control*) ;;
    *)
      if [ "$(norm "$(j_orig "$_id")")" = "$(norm "$_now")" ]; then
        # A knob may explain what it found: "Bluetooth was already off" and "this
        # ROM has no policy_control" are different facts, and the old sentence
        # covered both by suggesting something was missing.
        _nf="note_$_id"
        if has_function "$_nf"; then
          log "note $_id: $("$_nf")"
        else
          log "note $_id: no visible change (optional node missing?)"
        fi
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
  has_function "$_fn" || { log "no restore function for $_id"; return 1; }

  # Both snapshots go to the restore function: it decides per value whether
  # that value is still ours to undo. The journal files are already one target
  # per line, so they are handed over as they are - two copies and two deletes
  # per knob used to sit here for no reason, and every one of those is a process
  # this phone has to fork.
  "$_fn" "$JOURNAL/$_id.orig" "$JOURNAL/$_id.applied"
  _rc=$?

  # Few-target knobs keep the one-round verification, and it outranks the
  # restore's own account: a knob with a handful of single targets (navigation,
  # brightness, the switches whose silent failure is felt the moment it happens)
  # gets the one-round read - the ROM that accepts a command and does nothing
  # with it reports no failure, and only a read can catch it. The verdict also
  # names both sides of a refused value, which the outcome file cannot know at
  # write time. The scratch account is consumed either way - a file left in
  # .tmp is a state diff for nothing.
  _nt=$(grep -c "" "$JOURNAL/$_id.applied" 2>/dev/null)
  if [ "${_nt:-0}" -gt 0 ] && [ "$_nt" -le 3 ]; then
    rm -f "$SPSM_DIR/.tmp/krv.${KRV_TAG:-main}" 2>/dev/null
    _after=$("snapshot_$_id" 2>/dev/null)
    case "$(revert_verdict "$_after" "$(j_orig "$_id")" "$(j_applied "$_id")")" in
      restored)
        j_record_state "$_id" restored ;;
      kept)
        j_record_state "$_id" left
        log "keep $_id: a value was changed externally since we applied it" ;;
      *)
        j_record_state "$_id" restored-drift
        log "WARN $_id did not return: $(drift_list "$_after" "$(j_orig "$_id")")" ;;
    esac
    return $_rc
  fi
  # The installer's method for big records - the restore read every target
  # once (it had to, to know what was still ours to undo) and wrote the
  # originals back. Re-reading everything AGAIN to prove the write was the
  # opposite of that was thirteen full snapshots at once on the exit, a
  # hundred seconds of it, the phone starving while its owner pressed home.
  # The restore says what happened as it happens (kept / failed / wrote),
  # and the verdict costs no fork. `engine.sh verify` remains the end-to-end
  # read for a human who wants it, and the safety valves still catch a
  # genuinely refused write.
  _ko="$SPSM_DIR/.tmp/krv.${KRV_TAG:-main}"
  if [ -s "$_ko" ] && grep -q "^kept" "$_ko" 2>/dev/null; then
    j_record_state "$_id" left
    log "keep $_id: a value was changed externally since we applied it"
    rm -f "$_ko" 2>/dev/null
    return $_rc
  fi
  if [ -s "$_ko" ] && grep -q "^failed" "$_ko" 2>/dev/null; then
    j_record_state "$_id" restored-drift
    log "WARN $_id did not return: $(grep "^failed" "$_ko" 2>/dev/null | cut -f2 | tr '\n' ' ')"
    rm -f "$_ko" 2>/dev/null
    return $_rc
  fi
  j_record_state "$_id" restored
  rm -f "$_ko" 2>/dev/null
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
  if [ "$_mode" = revert ]; then
    phase_session_revert "$_list"
    return 0
  fi
  # The apply, side by side - the owner waited a minute for what the phone can
  # answer in a fifth of the time when the questions go out together. Four knobs
  # keep an order, going in: the background sweep runs after the app blocking
  # (it hands back the memory of exactly the apps that pass just made - the
  # owner's phone showed the first sweep silently empty when the two ran
  # together), then the home role, then the navigation mode (the phone is put
  # on three buttons only once the mode's home is there to receive it).
  progress "Applying"
  # Bounded two at a time, and every worker reniced: the navigation bar is
  # SystemUI drawing, and it must win the CPU while the mode is setting up.
  _c=0
  for _k in $_list; do
    [ "$(knob_scope "$_k")" = "deep" ] && continue
    knob_enabled "$_k" "$(knob_default "$_k")" || continue
    case $_k in
      block_other_apps|sweep_bg|home_swap|nav_buttons|gov_powersave|gpu_cap) continue ;;
    esac
    ( KRV_TAG=$_k
      bg_nice
      _kt0=$(now_epoch)
      knob_apply "$_k"
      _d=$(( $(now_epoch) - _kt0 ))
      [ "$_d" -ge 2 ] && log "  slow: apply $_k took ${_d}s"
    ) &
    _c=$((_c + 1))
    [ "$_c" -ge 3 ] && { wait; _c=0; }
  done
  wait
  # The ordered tail, written out in full: blocking before the sweep (it hands
  # back the memory of exactly the apps just blocked), the home before the
  # navigation that needs it, and the two caps LAST - the owner's own tip, and
  # his v3.7.10 log proves it right: under the governor every package-manager
  # call costs most of a second (the 188-app block spent 52s capped), while at
  # the phone's own speed the same work is a fraction of that. The caps land
  # after the expensive asks are done and cost two sysfs writes.
  for _k in block_other_apps sweep_bg home_swap nav_buttons gov_powersave gpu_cap; do
    # Navigation is built into the power-saving home: both follow the home
    # switch alone - never a saved preference of their own. (The owner's
    # phone carried a stale knob.nav_buttons=0 from an older version, and
    # the built-in never fired.) No home up, no bar.
    case $_k in
      home_swap|nav_buttons)
        knob_enabled home_swap "$(knob_default home_swap)" || continue ;;
      *)
        knob_enabled "$_k" "$(knob_default "$_k")" || continue ;;
    esac
    _kt0=$(now_epoch)
    knob_apply "$_k"
    _d=$(( $(now_epoch) - _kt0 ))
    [ "$_d" -ge 2 ] && log "  slow: apply $_k took ${_d}s"
  done
}

# The exit, side by side.
#
# The owner measured the module's own installer revert against this mode's exit
# on the same phone and the same session: about 20s against about 60s - for the
# same work. The difference was not the work, it was the waiting: this phone
# spends most of a second on every settings/pm call while it is busy, the exit
# asked its questions one knob at a time, and the knobs do not touch each
# other's values. So the reverts now run together - each in its own subshell,
# each journalling only its own knob (the scratch files are tagged per knob, so
# side-by-side reverts cannot read each other's readings) - and the two knobs
# that DO have an order stay ordered: the navigation overlay goes back before
# the home role, or the phone spends the last seconds of the exit with no home.
# Wall time on the owner's phone: the slowest knob, plus the one ordered tail
# (navigation) - about what the installer's revert took, which is the point.
phase_session_revert() { # <knob list, deep already excluded>
  _list="$@"
  _tail=''
  # SIX at a time, like every other fan. This one ran wide open - a dozen
  # workers, each re-reading its own knob to prove the revert - and the
  # owner's exit spent 103s inside ONE knob's verify snapshot while they all
  # fought each other and the interface for the CPU. Bounded, it is seconds.
  _c=0
  for _k in $_list; do
    [ "$(knob_scope "$_k")" = "deep" ] && continue
    case $_k in
      nav_buttons) _tail="$_tail $_k" ; continue ;;
    esac
    ( KRV_TAG=$_k
      bg_nice
      _kt0=$(now_epoch)
      knob_revert "$_k"
      _d=$(( $(now_epoch) - _kt0 ))
      [ "$_d" -ge 2 ] && log "  slow: revert $_k took ${_d}s"
    ) &
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
  done
  wait
  for _k in $_tail; do
    _kt0=$(now_epoch)
    knob_revert "$_k"
    _d=$(( $(now_epoch) - _kt0 ))
    [ "$_d" -ge 2 ] && log "  slow: revert $_k took ${_d}s"
  done
}

phase_deep() { # apply|revert
  _mode=$1
  [ "$_mode" = revert ] && { phase_deep_revert; return 0; }
  # The apply, side by side - for the same reason the session is. On the
  # owner's phone ONE sequential screen-off spent 149s in app_restrict, then
  # 889s in deep_doze, then 450s in rom_bg_off, all in a row: the deep phase
  # held the engine for the better part of an hour, and the core sleep - the
  # whole point of which is ONE MINUTE - queued behind all of it (the v3.7.5
  # log: cores down 63 minutes after the screen went dark). The knobs are
  # independent values, each journalling only itself (KRV_TAG keeps the
  # scratch files apart), so they run together; the wall time is the slowest
  # knob, not the sum. The core sleep is NOT applied here at all: its delay
  # is the feature, and the daemon's timer fires it (engine.sh core-sleep).
  progress "Idle: applying the asleep options"
  _c=0
  for _k in $(knobs_all); do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    knob_enabled "$_k" "$(knob_default "$_k")" || continue
    [ "$_k" = cores_sleep ] && continue
    if [ -f "$STATE/deep_report" ]; then
      case " $DEEP_ONCE " in
        *" $_k "*)
          log "idle: $_k is already in place from this idle period - not redoing it"
          continue ;;
      esac
    fi
    # SIX at a time, reniced: two at a time was the v3.7.8 answer to the load
    # spike, and the owner's v3.7.10 log shows what it cost - app_restrict
    # 175s, rom_bg_off 243s, a screen-off that held the engine for seven
    # minutes and starved the core timer of its minute. Wide enough to be
    # quick, reniced so the phone never feels it. The daemon runs this
    # detached now (see daemon.sh), so the timer and pokes are answered
    # while it works.
    ( KRV_TAG=$_k
      bg_nice
      _kt0=$(now_epoch)
      knob_apply "$_k"
      _d=$(( $(now_epoch) - _kt0 ))
      [ "$_d" -ge 2 ] && log "  slow: apply $_k took ${_d}s"
    ) &
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
  done
  wait
}

# Reverting a deep phase must also undo knobs that are still applied, so it
# walks the reverse of the order they were applied in.
phase_deep_revert() {
  # Side by side, for the same reason the session is: the owner's phone showed
  # the installer's revert of a live session at 10s while the door took 40 - the
  # difference was this phase, which holds the two slowest reverts on the phone
  # (the per-app background work) and used to run them one after another. The
  # knobs are independent values; each reverts in its own subshell with its own
  # journal slice, and nothing here has an order (the CPU power mode, the one
  # knob the governor's revert depends on, went back before this was called).
  _c=0
  for _k in $(knobs_reversed); do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    ( KRV_TAG=$_k
      bg_nice
      _kt0=$(now_epoch)
      knob_revert "$_k"
      _d=$(( $(now_epoch) - _kt0 ))
      [ "$_d" -ge 2 ] && log "  slow: revert $_k took ${_d}s"
    ) &
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
  done
  wait
}

# ------------------------------------------------------------------ commands

# The daemon's one-minute timer fired: put cores 2-7 to sleep.
#
# This deliberately does NOT take the engine lock. The v3.7.5 log is why: the
# deep phase (which holds the lock through its whole apply) took the better
# part of an hour on this phone, and the core sleep - which the owner asked
# to happen after ONE minute - queued behind it and ran 63 minutes late. The
# per-knob journal discipline (KRV_TAG scratch, one knob per journal slice)
# is exactly what the session phase's parallel applies already rely on, so a
# concurrent core-sleep is as safe as those. The world is re-checked before a
# single core is touched: the mode on, the screen off, the timer still armed,
# the knob not already applied. And because there is no lock to serialise a
# wake against, the wake race is answered the honest way: after the cores are
# down, the screen and the marker are looked at AGAIN - and if a wake landed
# in between, this very call puts the cores straight back.
do_core_sleep() {
  knob_enabled cores_sleep "$(knob_default cores_sleep)" || return 0
  [ -f "$ACTIVE" ] || return 0
  # Whoever fires this arms it - the daemon writes the marker before calling,
  # and a direct call (recovery, the tests) arms it here. The wake disarms by
  # removing the file, which is what the post-apply check below reads.
  [ -f "$STATE/cores_asleep" ] || : > "$STATE/cores_asleep" 2>/dev/null
  [ "$(screen_state)" = "off" ] || return 0
  case "$(j_state cores_sleep)" in
    applied) return 0 ;;
  esac
  KRV_TAG=cores_sleep knob_apply cores_sleep
  # The wake may have landed while the cores were going down. Then undo it
  # here, now - do not leave six sleeping cores under somebody's finger.
  if [ ! -f "$STATE/cores_asleep" ] || [ "$(screen_state)" != "off" ]; then
    KRV_TAG=cores_sleep knob_revert cores_sleep
  fi
  return 0
}

do_activate() {
  lock_acquire || { log "activate: busy"; return 1; }
  progress "Starting"
  rm -f "$STATE/doze_forced"
  rm -f "$STATE/cores_asleep"

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
  rm -f "$PROGRESS"
    lock_release
    return 0
  fi

  _on_t0=$(now_epoch)
  sync_scripts
  j_reset
  rm -f "$STATE/sweep_full"
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

  # The limits the owner asked to be held are session knobs now (the governor
  # and the GPU floor): phase_session applied them above, with the screen on,
  # because that is what "always" means. There is no separate switch for it
  # any more - v3.7.5 removed cap_always together with the frequency ceiling.

  start_daemon
  tmp_sweep
  # The owner's launcher does not re-read suspension states on its own, so
  # with this mode's home OFF the blocked apps kept full-colour icons in the
  # drawer. One refresh - only when something was actually blocked, and never
  # while the mode's own home is up (the launcher is left alone then).
  if ! knob_enabled home_swap "$(knob_default home_swap)" && [ -s "$STATE/blocked_by_us.tsv" ]; then
    refresh_launcher "$(home_package)"
  fi
  progress "On"
  rm -f "$PROGRESS"
  log "SPSM ON: $(applied_count) knobs applied in $(( $(now_epoch) - _on_t0 ))s"
  lock_release
  return 0
}

do_deactivate() {
  # High priority: the exit is the promise. It ends an in-flight screen
  # transition rather than queueing behind it.
  lock_acquire high || { log "deactivate: busy"; return 1; }
  # A name of its own: `_t0` is also used inside the phase loops below, and a
  # shell has no local variables - so the exit's own stopwatch was being reset by
  # the last knob it reverted, and the log reported a few seconds for an exit
  # that had taken a minute and a half. The owner asked for a faster exit; the
  # first thing it needed was an honest number to measure it by.
  _exit_t0=$(now_epoch)
  sync_scripts
  log "===== SPSM v3 OFF (scripts $(scripts_stamp), module $(spsm_version)) ====="
  progress "Restoring"

  # Two facts about the session that is ending, taken before anything is put
  # back: was the mode actually on, and did it actually change anything. The
  # launcher refresh at the end of the exit is worth doing for a session that
  # changed something, and is an unnecessary restart of somebody's home screen
  # for one that changed nothing.
  _was_on=0
  _did_work=0
  if [ -f "$ACTIVE" ]; then
    _was_on=1
    _did_work=$(pending_knobs)
  fi

  # The mode is off from this point, before anything is put back. A screen-off
  # that was already in flight (or one the daemon starts in the next few
  # milliseconds) must not re-apply deep knobs behind the revert - that is the
  # one race that could leave a change behind on exit.
  rm -f "$ACTIVE"

  # The daemon stops here, at the top of the exit, rather than at the end.
  # Its whole job is the screen, and the screen is none of its business any more
  # - but while it was still running it held the transition lock against the
  # exit: the v3.6.0 log has the exit spending a second on "WARN lock timeout
  # (held by pid ...)" waiting for a loop that was about to be stopped anyway.
  stop_daemon

  # The owner's tip, and his v3.7.10 log proves it: with the governor still
  # holding the cores at minimum, everything after this point ran at the
  # phone's slowest - the 188-app release alone spent 100s. The two "always"
  # caps go back FIRST (two sysfs writes), so the whole exit runs at the
  # phone's own speed from its first moment. A knob that was never applied
  # is skipped by the revert itself.
  if [ "$_was_on" = 1 ]; then
    _cap_t0=$(now_epoch)
    KRV_TAG=gov_powersave knob_revert gov_powersave
    KRV_TAG=gpu_cap knob_revert gpu_cap
    # The v3.8.1 field log has four unaccounted seconds between "daemon
    # stopped" and this line. Everything in that window is stop_daemon plus
    # these two reverts, and nothing in it is logged - so the next log says
    # which. Only printed when it is slow enough to be worth knowing.
    _cap_d=$(( $(now_epoch) - _cap_t0 ))
    if [ "$_cap_d" -ge 2 ] 2>/dev/null; then
      log "exit: the caps are off first - the rest of the exit runs at full speed (caps took ${_cap_d}s)"
    else
      log "exit: the caps are off first - the rest of the exit runs at full speed"
    fi
  fi

  # The hard guarantee behind the six slots, and it comes FIRST - before any
  # journal verdict can answer "changed externally" about this record and
  # skip it, and before anything else can empty the file: every package this
  # mode ever recorded as suspended-by-us is released on the way out.
  # v3.7.5 shipped an exit that skipped exactly this: the owner's phone kept
  # ~20 apps suspended through an exit, a re-flash and a REBOOT (Android
  # persists suspensions; only an unsuspend clears them). Idempotent,
  # parallel, every single time.
  if [ -s "$STATE/blocked_by_us.tsv" ]; then
    # One pm call per forty, from the record straight to the phone: the exit
    # that spent 100s forking one release per app now answers in seconds.
    _freed=$(grep -c "" "$STATE/blocked_by_us.tsv" 2>/dev/null)
    [ -n "$_freed" ] || _freed=0
    pm_batch unsuspend < "$STATE/blocked_by_us.tsv" >/dev/null 2>&1
    rm -f "$STATE/blocked_by_us.tsv"
    log "exit: released every suspended app ($_freed package(s))"
  fi
  # ...and the half of it that `pm unsuspend` cannot undo. Outside the guard on
  # purpose: the two records are independent - the sweep stops packages the
  # suspend record never names - and a release that only ran when a suspension
  # was found would leave exactly those behind. This is the path the exit
  # actually takes (the deep phase's own restore only runs if the screen came
  # back on first), and it is the one that matters: a STOPPED app is not woken
  # by a push, so leaving these behind silences messaging with no visible cause.
  # Measured on the owner's phone: 173 packages, WhatsApp among them, still
  # stopped with the mode off.
  command -v release_force_stopped >/dev/null 2>&1 && release_force_stopped

  # The one-minute core timer is disarmed with the session, and the sweep
  # remembers nothing into the next one.
  rm -f "$STATE/cores_asleep"
  rm -f "$STATE/sweep_full"

  # The CPU power mode is NOT touched on the way out - and not on the way in
  # either. v3.7.5 removed the Low Power mode option at the owner's direction
  # (the governor is the only hand on CPU speed now), so this module never
  # writes /proc/cpufreq/cpufreq_power_mode at all: a power mode something else
  # set is somebody else's state, and leaving it exactly as found is the honest
  # behaviour. If a state we did write ever needs clearing, the version that
  # wrote it owns that.

  # The deep phase and the session phase run TOGETHER now. They are disjoint
  # sets of values, each knob journalling only itself, so nothing can collide -
  # and the owner's own log shows why this matters: his 33-second exit spent a
  # quarter of it waiting for the deep phase to finish before the session even
  # started, which is waiting the installer never does. The one knob with an
  # order keeps it: nav_buttons comes back strictly after home_swap has handed
  # the home role back, so it is the session's own tail.
  phase_deep_revert &
  _DPID=$!
  phase_session revert
  wait "$_DPID"


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
  _took=$(( $(now_epoch) - _exit_t0 ))
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
  rm -f "$PROGRESS"
  else
    log "revert finished in ${_took}s with $DRIFT drifted knob(s) - see journal"
    progress "Off ($DRIFT kept)"
  rm -f "$PROGRESS"
  fi

  # The owner's third report, and the last thing the exit does: the launcher's
  # app drawer was left full of grey icons by a session that changed the state
  # behind it, and a restart of the launcher is what rebuilds it. Once, here, in
  # the exit path - never while the mode is running.
  if [ "$_was_on" = 1 ] && [ "${_did_work:-0}" != "0" ]; then
    refresh_launcher "$(home_package)"
  fi

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
  # The deep knobs hold the phone down; this is the part that gives the memory
  # back, every time the screen goes off.
  if knob_enabled sweep_bg "$(knob_default sweep_bg)"; then
    sweep_background "screen off"
  fi
  # Written down here, while the caps are in place: by the time anyone looks at
  # the phone the screen is on again and everything is deliberately back to
  # normal, so this line is the only honest record of what the idle state was.
  deep_report
  lock_release
}

# The deep knobs that are expensive, cannot revert by themselves, and are already
# in place from an earlier screen-off in the same idle period: the per-app
# background restrictions and the request for deep sleep. Re-applying them cost
# 86-89s and then up to 619s in the v3.4.1 log, in every single screen-off, for a
# state the phone was already in. The lock and the screen-off path guarantee that
# nothing else is running when this is decided; releasing the deep phase clears
# the report that this list is judged by, so a real wake always re-applies them.
DEEP_ONCE="app_restrict rom_bg_off deep_doze"

do_screen_on() {
  still_on || return 0
  lock_acquire || return 0
  # Same re-check as the screen-off path: a daemon that was killed on exit can
  # still have this child in flight, and it must not start waking the phone up
  # after the mode is already off.
  [ -f "$ACTIVE" ] || { lock_release; return 0; }
  log "screen on -> release deep phase"
  # The cores come back FIRST, before anything else is even started - six
  # sleeping cores are the one change the user would feel - and the one-minute
  # timer is disarmed so the next sleep starts fresh. Everything else deep is
  # released side by side: the wake is when the phone is in somebody's hand,
  # and the v3.7.5 log shows the sequential wake spending minutes putting
  # per-package restrictions back while the owner watched a slow phone.
  # The governor and the GPU floor are session knobs: a wake does not lift
  # them - "all the time is good enough", as the owner put it.
  rm -f "$STATE/cores_asleep"
  knob_revert cores_sleep
  # The rest, SIX AT A TIME and reniced. Wide open, the wake once asked the
  # phone for every pm/appops call it owed at the same instant and the owner
  # watched the navigation bar disappear; two at a time made the wake itself
  # crawl (14s just to lift the per-app limits). Six workers at background
  # priority is both: brisk, and invisible to the phone in hand.
  _c=0
  for _k in $(knobs_all); do
    [ "$(knob_scope "$_k")" = "deep" ] || continue
    [ "$_k" = cores_sleep ] && continue
    ( KRV_TAG=$_k
      bg_nice
      _kt0=$(now_epoch)
      knob_revert "$_k"
      _d=$(( $(now_epoch) - _kt0 ))
      [ "$_d" -ge 2 ] && log "  slow: revert $_k took ${_d}s"
    ) &
    _c=$((_c + 1))
    [ "$_c" -ge 6 ] && { wait; _c=0; }
  done
  wait
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
  # cfg() answers from a copy of the file taken the first time it was asked, so
  # the write above is invisible to this very run until the copy is dropped.
  # This is the only place inside a run that changes the config, and everything
  # after it here - the apply, the revert, the knob's own default - reads it.
  cfg_invalidate
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
    # Not every knob is a choice. The status bar is kept visible because the
    # mode is on, not because anyone asked for it this time, and three-button
    # navigation is built into the power-saving home (the owner asked for one
    # switch, not two) - neither is offered, and no switch exists here for
    # them. Both still apply, and both still revert, exactly as before.
    case $_k in statusbar_on|nav_buttons) continue ;; esac
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

# ------------------------------------------------------------------ allow
# Called when the user changes which apps are in the six slots.
#
# The slots are the "keep working" list: an app in a slot must be usable while
# the mode is on, and an app taken out of a slot must be subject to the mode again.
# The list itself is written by the app to whitelist.txt (which the restrict
# options already read); this frees anything the module had blocked and then let
# go of the record, so the exit does not try to undo it twice.
do_allow() {
  _wl="$SPSM_DIR/whitelist.txt"
  _freed=0
  _blocked=0
  _list=$(cat "$_wl" 2>/dev/null)
  [ -n "$_list" ] || _list=''
  # Free what we suspended and the owner has now put in a slot.
  #
  # v3.7.5 gated the release twice - "is it in our record" AND "does the
  # system say the app is still suspended" - and this phone's dumpsys does
  # not answer in the words the second gate expected: the v3.7.5 log shows
  # allow lines with no release behind them, so the app the owner had just
  # added STAYED suspended, and the exit then answered "changed externally"
  # and skipped every release it still held. The record gate stays (an app
  # the USER suspended on their own is their decision, not ours to undo);
  # the system-state gate is gone - our record is the authorisation, pm
  # unsuspend is idempotent, and unsuspend_app goes through the same
  # identity that did the suspending.
  for _p in $_list; do
    if [ -f "$STATE/blocked_by_us.tsv" ] && grep -qxF "$_p" "$STATE/blocked_by_us.tsv"; then
      _freed=$((_freed + 1))
      grep -vxF "$_p" "$STATE/blocked_by_us.tsv" > "$STATE/blocked_by_us.tsv.tmp" 2>/dev/null \
        && mv -f "$STATE/blocked_by_us.tsv.tmp" "$STATE/blocked_by_us.tsv" 2>/dev/null
      if unsuspend_app "$_p"; then
        log "allow $_p: it is in the six slots, so it is free"
      else
        log "allow $_p: the system refused the unsuspend - it will be released at the exit"
      fi
    fi
  done
  # Block what was taken out of the slots, right now - screen on or off. The
  # old gate waited for the screen to go dark, and the owner caught the gap
  # live: swapping an app while using the phone left the removed one usable
  # next to the added one, which is exactly backwards for a mode that is on.
  # An app outside the six slots is subject to the mode the moment it leaves
  # them; blocking what is outside the slots is what the mode IS.
  if [ -f "$ACTIVE" ]; then
    apply_block_other_apps
    _blocked=1
    # The journal records what apply_block_other_apps suspended AT APPLY TIME,
    # but the two passes above have changed that since. Re-record what is true
    # NOW - or the exit compares against a world that no longer exists and,
    # exactly as in the v3.7.5 log, answers "changed externally" and releases
    # nothing. The ORIG file is untouched: the exit still restores the phone
    # to what it was before the mode came on.
    case "$(j_state block_other_apps)" in
      applied) j_record_applied block_other_apps "$(snapshot_block_other_apps 2>/dev/null)" ;;
    esac
  fi
  echo "allowed=$_freed idle_recheck=$_blocked"
  return 0
}

# The owner's recovery command, safe to run at any time - Termux:
#   su -c sh /data/adb/spsm/scripts/engine.sh six-restore
# Releases everything in the six slots and everything our record still names,
# however the session that suspended them ended.
do_six_restore() {
  # Under the lock: recovery mutates the same suspensions a transition may be
  # writing at this moment. If a transition is in flight, say so instead of
  # fighting it - twenty seconds of waiting is built in, and a recovery that
  # lost the race would report freedom the session is about to take back.
  if ! lock_acquire; then
    echo "busy"
    log "six-restore: a transition is running - try again once it settles"
    return 1
  fi
  # Six at a time, like every other per-package fan: the owner's record held
  # 264 packages, and one-by-one that was minutes of pm calls in the exact
  # moment recovery is needed - the boot heal in service.sh waited on it too.
  _r="$SPSM_DIR/.tmp/restore.$$"
  [ -d "$SPSM_DIR/.tmp" ] || mkdir -p "$SPSM_DIR/.tmp" 2>/dev/null
  _n=$(cat "$SPSM_DIR/whitelist.txt" 2>/dev/null "$STATE/blocked_by_us.tsv" 2>/dev/null | grep -c "")
  [ -n "$_n" ] || _n=0
  cat "$SPSM_DIR/whitelist.txt" 2>/dev/null "$STATE/blocked_by_us.tsv" 2>/dev/null \
    | pm_batch unsuspend >/dev/null 2>&1
  rm -f "$STATE/blocked_by_us.tsv" 2>/dev/null
  # Recovery has to free the force-stops too: a stopped app cannot be woken by
  # a push, so a crash that left them behind would leave the phone silently
  # unable to receive messages until each app was opened by hand.
  command -v release_force_stopped >/dev/null 2>&1 && release_force_stopped
  # The one honest caveat: with the mode still on, its next transition will
  # re-apply its own choices. Recovery still works - it must - but the log
  # says what comes next instead of leaving a mystery.
  if [ -f "$ACTIVE" ]; then
    log "six-restore: the mode is on - its next transition will re-apply its choices; switch the mode off to keep them freed"
  fi
  echo "released=$_n"
  log "six-restore: $_n package(s) unsuspended (the six slots + our record)"
  lock_release
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

# A function call with a lid on it. The check once spent 889 seconds inside
# ONE option's apply on this phone (deep_doze, the v3.7.5 log), which reads
# to the person waiting as "the button does nothing". Every probe apply and
# revert runs under this: when the lid comes down the option is reported as
# unanswerable and the check moves on.
with_timeout() { # with_timeout <seconds> <function> [args...]
  _to_secs=$1; shift
  ( "$@" ) &
  _to_pid=$!
  ( sleep "$_to_secs"; kill "$_to_pid" 2>/dev/null ) &
  _to_watch=$!
  wait "$_to_pid"
  _to_rc=$?
  kill "$_to_watch" 2>/dev/null
  wait "$_to_watch" 2>/dev/null
  return $_to_rc
}

probe_one() { # probe_one <knob> -> "verdict<TAB>detail"
  _k=$1
  # A control option changes how the others are applied rather than changing the
  # phone itself, so there is nothing on the device to try. Saying "could not
  # check" about it would be a false alarm.
  # knob_meta is category|label|description|default|scope|tags - six fields, so
  # the tags are the sixth. (Reading the seventh is how a plain preference was
  # once reported as "could not check".)
  case "$(knob_meta "$_k" | cut -d'|' -f6)" in
    *control*) printf 'preference\tthis is a setting, not a change to the phone'; return 0 ;;
  esac
  # An option whose change cannot be read back answers for itself: the snapshot
  # diff below would call it "inert" (nothing moved) when the truth is "applied,
  # and the phone cannot show it". The frame-rate cap is that case - Surface-
  # Flinger's override is a setter with no getter - and its own verdict hook
  # says so instead of leaving the sentence to a machinery that cannot see it.
  _pfv="probe_${_k}_verdict"
  if has_function "$_pfv"; then "$_pfv"; return 0; fi
  # NOT "_snap": knob_apply assigns to a variable of that name (it holds the
  # snapshot text), and there are no locals in POSIX sh - so the name of the
  # function to call was being overwritten by the very call it was used for, and
  # every reading after the apply came back empty. That is how a probe reports
  # "changed ... did not come back" for an option that did nothing at all.
  _snapfn="snapshot_$_k"
  has_function "$_snapfn" || { printf 'unknown\tno snapshot function'; return 0; }
  has_function "apply_$_k" || { printf 'unknown\tno apply function'; return 0; }

  _before=$(probe_reading "$_k" "$_snapfn")
  if [ -z "$(norm "$_before")" ]; then
    printf 'unknown\tcould not read anything this option controls on this phone'
    return 0
  fi
  with_timeout 90 knob_apply "$_k" >/dev/null 2>&1
  _after=$(probe_reading "$_k" "$_snapfn")
  _did=$(snap_diff "$_before" "$_after")
  with_timeout 90 knob_revert "$_k" >/dev/null 2>&1
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
  has_function "$_pf" && "$_pf" 2>/dev/null
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
    progress "Checking: $(knob_meta "$_k" | cut -d'|' -f2)"
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
  progress "Check finished"
  rm -f "$PROGRESS"
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
  # The daemon's one-minute timer (see daemon.sh): cores 2-7 go to sleep.
  core-sleep) do_core_sleep ;;
  # The recovery command: release everything in the six slots and the record.
  six-restore) do_six_restore ;;
  set)        do_set "$2" "$3" ;;
  verify)     do_verify ;;
  probe)      do_probe "$2" ;;
  allow)      do_allow ;;
  recents)        do_recents ;;
  clear-all)      do_clear_all ;;
  # Written by the app whenever something opens the recents list: the button on
  # the home screen, the phone's own Recents key, or a MAIN/HOME intent. The
  # list itself logs what it found, so a press that opens nothing leaves a line
  # that says the press arrived and a list that never answered.
  recents-opened) log "recents: the list was opened by ${2:-unknown}" ;;
  recents-switch) recents_switch "$2" "$3" ;;
  recents-remove) recents_remove "$2" "$3" ;;
  version)    echo "scripts=$(scripts_stamp) module=$(spsm_version) code=$SPSM_CODE_VERSION" ;;
  status)     do_status ;;
  # Read-only power measurement. Nothing here changes a setting; it exists
  # because "why is the phone still drawing current with the screen off" can
  # only be answered by counters read twice across a known interval, not by
  # the battery percentage.
  power)      shift; sh "$SCRIPT_DIR/power-profile.sh" "$@" ;;
  dump-knobs) do_dump_knobs ;;
  start-daemon) start_daemon ;;
  stop-daemon)  stop_daemon ;;
  toggle)
    if [ -f "$ACTIVE" ]; then do_deactivate; else do_activate; fi ;;
  *)
    echo "usage: engine.sh activate|deactivate|screen-off|screen-on|toggle|set <knob> <0|1>|verify|probe|allow|recents|recents-switch <id> [comp]|recents-remove <id> [pkg]|clear-all|recents-opened <how>|status|power [snapshot|window <s> <tag>|compare A B]|version|dump-knobs|start-daemon|stop-daemon"
    exit 2 ;;
esac
