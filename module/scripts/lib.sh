#!/system/bin/sh
# Axion SPSM v3 - shared library.
#
# Design rule, learned the hard way: EVERY change is journalled before it is
# made, and a change is only undone when the value on disk is still the one we
# put there. If something else (the user, a ROM update, another module) has
# changed it in the meantime, we leave it alone and say so in the log. That is
# what makes "revert everything" safe instead of destructive.
#
# POSIX sh only: this runs under Android's mksh and under KernelSU's busybox ash.

# SPSM_ROOT prefixes every device path the scripts touch. It is empty on a real
# device and points at a fake tree during tests, which is how the revert
# guarantee is verified without a phone.
SPSM_ROOT=${SPSM_ROOT:-}
rp() { printf '%s%s' "$SPSM_ROOT" "$1"; }

SPSM_DIR=${SPSM_DIR:-/data/adb/spsm}
JOURNAL="$SPSM_DIR/journal"
ORIG_DIR="$SPSM_DIR/journal/orig"
STATE="$SPSM_DIR/state"
LOG="$SPSM_DIR/spsm.log"
CONFIG="$SPSM_DIR/config"
LOCK="$SPSM_DIR/lock"
ACTIVE="$STATE/active"
SCREEN_MARK="$STATE/screen"
PROGRESS="$STATE/progress"
APPLIED_ORDER="$SPSM_DIR/journal/order"
KNOBS_LIST="$SPSM_DIR/knobs.list"

# /data/adb/spsm must exist before anything else references it.
mkdir -p "$SPSM_DIR" "$ORIG_DIR" "$STATE" 2>/dev/null

# ------------------------------------------------------------------ logging
LOG_MAX=400000
log() {
  _line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$_line" >> "$LOG" 2>/dev/null
  echo "SPSM: $*" > /dev/kmsg 2>/dev/null
  if [ -f "$LOG" ]; then
    _sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if [ "$_sz" -gt "$LOG_MAX" ] 2>/dev/null; then
      tail -c 200000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
  fi
}

progress() { echo "$1" > "$PROGRESS" 2>/dev/null; }

# ------------------------------------------------------------------ locking
# Serialise apply/revert so a watchdog tick cannot race a user toggle.
lock_acquire() {
  _i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    _p=$(cat "$LOCK/pid" 2>/dev/null)
    # A lock whose owner is gone (crash, kill, power cut) is taken straight
    # away. Waiting out a timer instead means a real user's next action fails
    # for no reason: the old code spent 20s here and then gave up with "busy".
    if [ -n "$_p" ] && [ ! -d "/proc/$_p" ]; then
      log "stale lock: pid $_p is gone - taking it"
      rm -rf "$LOCK"
      continue
    fi
    # Holder still alive: only a genuinely wedged one is overridden, and the
    # bar is high because a revert with a large app list is legitimately slow.
    #
    # The age is only meaningful if the directory is still there. When another
    # process released the lock between the mkdir and the stat, there is nothing
    # to age - and dating it from the epoch produced a "stale lock (1789238021s)"
    # warning that looked alarming and meant nothing.
    if [ -d "$LOCK" ]; then
      _mt=$(stat -c %Y "$LOCK" 2>/dev/null) || _mt=''
      case "$_mt" in
        ''|*[!0-9]*) ;;
        *)
          _age=$(($(date +%s) - _mt))
          if [ "$_age" -gt 600 ] 2>/dev/null; then
            log "WARN stale lock (${_age}s, pid ${_p:-unknown}) - taking it"
            rm -rf "$LOCK"
          fi
          ;;
      esac
    fi
    _i=$((_i + 1))
    [ "$_i" -gt 100 ] && { log "WARN lock timeout (held by pid ${_p:-unknown})"; return 1; }
    sleep 0.2 2>/dev/null || sleep 1
  done
  echo $$ > "$LOCK/pid" 2>/dev/null
  return 0
}
lock_release() { rm -rf "$LOCK" 2>/dev/null; }

# ------------------------------------------------------------------ escaping
# A snapshot record is "target<TAB>value", one record per line. That only holds
# if the VALUE can never contain a newline - a Settings row can - so values are
# escaped on the way in (enc_val) and decoded when they are written back out.
#
# Escaping is applied to values, never to whole snapshot texts: doing it to the
# text collapsed every record onto one line, and the reader then saw one target
# with the rest of the file as its value.
#
# The escaped form keeps a trailing "\n" escape AND a real newline, because a
# file whose last line has no terminator loses that last line to `while read` -
# which silently skipped the final value of every restore.
esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/$/\\n/' | tr -d '\n'
  printf '\n'
}
unesc() {
  # One left-to-right pass. A backslash is only special together with the
  # character after it, so \\ is a real backslash and \n is a newline - which
  # is what esc wrote. Two chained seds looked equivalent but were not: the
  # newline rule ran first, so a value that genuinely contained a backslash
  # followed by an "n" was rewritten into a newline on the way back out.
  printf '%s' "$1" | awk '{
    out = ""
    n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c != "\\") { out = out c; continue }
      i++
      d = substr($0, i, 1)
      if (d == "n") out = out "\n"
      else if (d == "\\") out = out "\\"
      else if (d == "") { out = out "\\"; i-- }
      else out = out "\\" d
    }
    print out
  }'
}
# A real tab, named. IFS must be given an actual tab character: writing
# IFS='\t' looks the same in a diff but makes the shell split records on a
# backslash and a letter t, which quietly corrupts every line it parses.
TAB=$(printf '\t')

# Canonical encoding for a value inside snapshot text.
#
# Snapshot text is ONE LINE PER TARGET, whatever the value contains, because
# that is the only way a value that itself spans lines (a Settings row holding
# newlines, for instance) can be told apart from the next record. Without this,
# restore_kv read the second line of such a value as a new target, and the value
# went back to the device truncated at its first line.
#
# The absence marker is left as-is so the existing "(MISSING)" checks keep
# working; every other value goes through esc(), and comes back out through
# unesc() at the moment it is written to the device.
enc_val() {
  case "$1" in
    '(MISSING)') printf '%s' '(MISSING)' ;;
    *) esc "$1" ;;
  esac
}

# Value of one target inside a snapshot text ("target<TAB>value" lines).
snap_get() {
  printf '%s\n' "$1" | awk -F"	" -v t="$2" '$1==t{print $2; exit}'
}
# One target's value straight out of a snapshot FILE, still encoded; snap_file_val
# decodes it. Restore functions that look up a single row must use these rather
# than their own sed/awk, so that a value's encoding is handled in one place.
snap_file_get() { # snap_file_get <file> <target>
  [ -f "$1" ] || return 0
  awk -F"\t" -v t="$2" '$1==t{print $2; exit}' "$1" 2>/dev/null
}
snap_file_val() { # snap_file_val <file> <target> -> decoded value
  unesc "$(snap_file_get "$1" "$2")"
}

# Every target mentioned in a snapshot text.
snap_targets() {
  printf '%s\n' "$1" | awk -F"	" 'NF>=2{print $1}'
}

# Classify a finished revert for one knob:
#   restored - every value is back to what it was before SPSM touched it
#   kept     - the only differences are values somebody else changed later
#   drift    - a value of ours is still in place that we should have undone
revert_verdict() { # revert_verdict now-text orig-text applied-text
  _now=$1; _orig=$2; _applied=$3
  _drift=0; _kept=0
  for _t in $(snap_targets "$_orig"); do
    _o=$(snap_get "$_orig" "$_t")
    _n=$(snap_get "$_now" "$_t")
    [ "$_n" = "$_o" ] && continue
    _a=$(snap_get "$_applied" "$_t")
    if [ -n "$_a" ] && [ "$_n" != "$_a" ]; then
      _kept=$((_kept + 1))
    else
      _drift=$((_drift + 1))
    fi
  done
  if [ "$_drift" -gt 0 ]; then echo drift
  elif [ "$_kept" -gt 0 ]; then echo kept
  else echo restored; fi
}

# Normalise before comparing: trailing spaces and blank lines are not changes.
norm() {
  printf '%s\n' "$1" | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

# ------------------------------------------------------------------ journal
j_paths() { echo "$JOURNAL/$1.orig" "$JOURNAL/$1.applied" "$JOURNAL/$1.meta"; }

j_write_meta() { # id kind target
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$JOURNAL/$1.meta"
}

# Values inside the text are already encoded (snap_kv/enc_val), so the text is
# stored as it is: one record per line, whatever the values contain.
j_record_orig() { # id snapshot-text
  printf '%s\n' "$2" > "$JOURNAL/$1.orig"
}

j_record_applied() { # id snapshot-text
  printf '%s\n' "$2" > "$JOURNAL/$1.applied"
}

j_record_state() { # id state-text
  printf '%s\n' "$2" > "$JOURNAL/$1.state"
}

j_state() { cat "$JOURNAL/$1.state" 2>/dev/null; }
# Handed back exactly as stored (canonical form). Callers that want to show a
# value to a human pass it through unesc(); callers that compare values must not,
# because every comparison in the engine happens between canonical texts.
j_orig() { cat "$JOURNAL/$1.orig" 2>/dev/null; }
j_applied() { cat "$JOURNAL/$1.applied" 2>/dev/null; }
j_has() { [ -f "$JOURNAL/$1.orig" ]; }

j_order_add() {
  grep -qxF "$1" "$APPLIED_ORDER" 2>/dev/null || echo "$1" >> "$APPLIED_ORDER"
}

# Start a new session. A finished session is cleared; an unfinished one is not.
#
# If the last session never exited (the engine was killed, the phone lost power,
# a revert failed part-way), its orig records are the only description of what
# the phone looked like before any of this, and applying over them must not
# destroy that: the exit after next still has to put the true values back.
j_reset() {
  _kept=0
  for _f in "$JOURNAL"/*.state; do
    [ -f "$_f" ] || continue
    _id=${_f##*/}
    _id=${_id%.state}
    case "$(cat "$_f" 2>/dev/null)" in
      applied|restored-drift)
        # Our value may still be in place: keep the record that predates it.
        _kept=$((_kept + 1)) ;;
      *)
        rm -f "$JOURNAL/$_id.orig" "$JOURNAL/$_id.applied" "$JOURNAL/$_id.meta" "$JOURNAL/$_id.state" ;;
    esac
  done
  mkdir -p "$ORIG_DIR" 2>/dev/null
  if [ "$_kept" = "0" ]; then
    # Nothing carried over, so the per-package sub-journals are finished too.
    rm -f "$ORIG_DIR"/*.tsv 2>/dev/null
    : > "$APPLIED_ORDER"
  else
    log "journal kept: $_kept unfinished knob(s) from a session that never exited"
  fi
}

# ------------------------------------------------------------------ config
# config is a flat key=value file the APK writes and the user can hand-edit.
cfg() { # cfg key default
  _v=$(sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | tail -1)
  [ -n "$_v" ] && { printf '%s' "$_v"; return; }
  printf '%s' "$2"
}

# Is a knob turned on? Default comes from the knob's own metadata.
knob_enabled() { # knob_enabled id default
  _v=$(cfg "knob.$1" "$2")
  case "$_v" in 1|true|on|yes) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ io
# Write a value to a device node.
#
# Deliberately always succeeds: most knobs write a list of candidate nodes and
# only some of them exist on any given ROM. If a missing node made this return
# non-zero, the last node in such a list would decide the whole knob's status -
# and a knob marked "failed" is a knob the revert does NOT undo. That is how a
# half-applied power tweak survives turning the mode off.
w() {
  _p=$(rp "$2")
  [ -n "$2" ] && [ -e "$_p" ] || return 0
  printf '%s\n' "$1" > "$_p" 2>/dev/null
  return 0
}

rd() { # rd path -> value or empty
  _p=$(rp "$1")
  [ -e "$_p" ] || { printf ''; return; }
  cat "$_p" 2>/dev/null | tr -d '\r'
}

exists() { [ -e "$(rp "$1")" ]; }

sget() { settings get "$1" "$2" 2>/dev/null; }
sput() { settings put "$1" "$2" "$3" >/dev/null 2>&1; }
sdel() { settings delete "$1" "$2" >/dev/null 2>&1; }

gprop() { getprop "$1" 2>/dev/null; }
sprop() {
  if command -v resetprop >/dev/null 2>&1; then
    # resetprop is needed for read-only props; setprop cannot change those.
    resetprop "$1" "$2" >/dev/null 2>&1 && return 0
  fi
  setprop "$1" "$2" >/dev/null 2>&1
}
dprop() {
  if command -v resetprop >/dev/null 2>&1; then
    resetprop --delete "$1" >/dev/null 2>&1
    resetprop -p --delete "$1" >/dev/null 2>&1
  fi
  setprop "$1" '' >/dev/null 2>&1
}
has() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ screen
BL_PATH=/sys/class/leds/lcd-backlight/brightness

# This phone's own ceiling for the backlight node. The node is not 0-255 like a
# lot of devices: on the RMX3430 it spans 0..4095, so a cap copied from another
# device's config would either be invisible (too low) or useless (too high).
# The device is asked for its own limits rather than being assumed.
screen_panel_ceiling() {
  _mx=$(rd /sys/class/leds/lcd-backlight/max_brightness)
  case "$_mx" in
    ''|*[!0-9]*) _mx=$(rd /sys/class/backlight/panel0-backlight/max_brightness) ;;
  esac
  case "$_mx" in
    ''|*[!0-9]*|0) _mx=4095 ;;
  esac
  echo "$_mx"
}

# Screen state, cheapest and most reliable first.
#
# The backlight node is the source this device has been verified to report
# correctly: 0 while the screen is off, 1..max while it is on. It is a single
# small read, and - unlike an app-written marker - it cannot go stale, because
# the kernel writes it. So it is asked first, and the answer "on" is accepted
# outright: a nonzero panel is proof the screen is on, whatever any other
# source believes.
#
# The app's marker is still used, but only its "off" side, and only when it
# agrees with a panel we cannot read. If the panel is readable and nonzero and
# the marker says "off", the marker is out of date (a receiver that missed, or a
# screen-on we did not hear about) and the panel wins. Believing a stale "off"
# is the expensive mistake: it drops the phone into the deep phase while
# somebody is using it.
#
# dumpsys is the last resort: it spawns a binder dump, which is real work on a
# phone we are trying to save, so it is never on the hot path.
# The panel value, read without forking anything: a redirection is a syscall,
# not a process. The daemon asks for this every second while the screen is on,
# and spawning `cat` a few thousand times a night to look at one number is the
# wrong way round for a module whose whole job is to stop the phone waking up.
panel_read() {
  PANEL=''
  # Through rp(), so a module running against an alternate root (which is how
  # the test suite drives it, and how it can be pointed at another tree) reads
  # the same node everything else does.
  IFS= read -r PANEL < "$(rp "$BL_PATH")" 2>/dev/null
}

# Decide the screen state from a panel reading, setting SCREEN_STATE rather than
# printing it, so the decision costs no forks either. Kept as one function so
# there is exactly one set of rules.
#
#   screen_decide <panel value> [state we believed a moment ago]
#
# The panel is the source this device has been verified to report correctly: 0
# with the screen off, 1..max while it is on. It is the kernel's own answer and
# it cannot go stale, so a nonzero panel is accepted outright - whatever any
# other source believes.
#
# A dark panel is weaker evidence: on some devices it is dark while a dream
# overlay or the always-on display is up, and then the phone is very much in
# use. So "0" is only accepted as "off" if nothing on the phone disagrees - the
# app, which is listening to the real power state, is not saying "on". The
# previous state is passed in as a hint to skip that check where it cannot
# change the answer: if we already knew the screen was off, a marker cannot turn
# a dark panel into a lit one.
# How long the app's "on" may outrank a dark panel, in seconds. The app
# publishes the state the moment the screen changes, and that write can reach the
# engine a fraction of a second before the backlight node actually lights, so a
# reading of 0 can be real and momentary. That is all this window is for.
#
# It used to be a whole day, and that was an expensive mistake: the app writes
# "on" every time it is opened or the screen wakes, and if the app's process is
# then killed - which is normal for a cached app, and more likely while a power
# saving mode is running - the marker stays at "on" with nobody left to write
# "off". The stale marker then outranked the panel for 24 hours, so the daemon
# was certain the screen was always on, never entered the deep phase, and the
# entire power-saving half of the mode silently did nothing. That is exactly the
# "no saving at all, cores normal" report this window is here to prevent.
#
# Bounded this way the failure is impossible: a marker that is more than a few
# seconds old can never contradict the panel.
SCREEN_MARK_GRACE=$(cfg screen_mark_grace 10)

screen_decide() {
  _bl=$1
  _prev=$2
  SCREEN_SRC=panel
  PANEL_RAW=$_bl
  if [ -n "$_bl" ]; then
    case "$_bl" in
      *[!0-9]*) SCREEN_SRC=unreadable ;;  # not a number: this reading says nothing, use the rest
      0)
        if [ "$_prev" != "off" ]; then
          _mk=''
          [ -f "$SCREEN_MARK" ] && IFS= read -r _mk < "$SCREEN_MARK" 2>/dev/null
          if [ "$_mk" = "on" ]; then
            _age=$(($(date +%s) - $(stat -c %Y "$SCREEN_MARK" 2>/dev/null || echo 0)))
            if [ "$_age" -le "$SCREEN_MARK_GRACE" ] 2>/dev/null; then
              SCREEN_STATE=on
              SCREEN_SRC="app-grace(${_age}s)"
              return
            fi
          fi
        fi
        SCREEN_STATE=off
        return
        ;;
      *)
        SCREEN_STATE=on
        return
        ;;
    esac
  fi

  # The panel was unreadable. The app's marker is the next cheapest answer; its
  # window is generous and continuous (the app refreshes it on every change), so
  # a slow boot or a long doze transition cannot make a live signal look stale.
  _mk=''
  [ -f "$SCREEN_MARK" ] && IFS= read -r _mk < "$SCREEN_MARK" 2>/dev/null
  case "$_mk" in
    on|off)
      _age=$(($(date +%s) - $(stat -c %Y "$SCREEN_MARK" 2>/dev/null || echo 0)))
      if [ "$_age" -lt 86400 ] 2>/dev/null; then
        SCREEN_STATE=$_mk
        SCREEN_SRC=app
        return
      fi
      ;;
  esac

  # Last resort, and never on the hot path: `dumpsys power` is a binder dump,
  # which is real work on a phone we are trying to save.
  if has dumpsys; then
    _st=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)
    case "$_st" in
      Awake|Dreaming) SCREEN_STATE=on ;;
      Asleep|Dozing) SCREEN_STATE=off ;;
      *) SCREEN_STATE=on ;;
    esac
    SCREEN_SRC=dumpsys
    return
  fi
  SCREEN_STATE=on
  SCREEN_SRC=assumed
}

# What the marker says and how old it is, for the log. Only asked for on a
# transition - it costs two processes, which is not a price a one-second poll can
# pay on every tick.
marker_word() {
  [ -f "$SCREEN_MARK" ] || { printf '%s' '-'; return; }
  _mk=''
  IFS= read -r _mk < "$SCREEN_MARK" 2>/dev/null
  _age=$(($(date +%s) - $(stat -c %Y "$SCREEN_MARK" 2>/dev/null || echo 0)))
  printf '%s@%ss' "${_mk:--}" "$_age"
}

screen_state() { # screen_state - prints on|off
  screen_decide "$(rd "$BL_PATH")" ''
  printf '%s' "$SCREEN_STATE"
}

# ------------------------------------------------------------------ home role
home_holder() {
  h=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | head -1)
  [ -n "$h" ] || h=$(cmd package resolve-activity -c android.intent.category.HOME 2>/dev/null \
    | sed -n 's/^ *packageName=//p' | head -1)
  [ -n "$h" ] || h=com.android.launcher3
  printf '%s' "$h"
}

set_home() { # set_home package
  cmd role add-role-holder android.app.role.HOME "$1" >/dev/null 2>&1
  if [ "$1" = "dev.axion.spsm" ]; then
    cmd package set-home-activity "dev.axion.spsm/.SpsmHomeActivity" >/dev/null 2>&1
  fi
}

launch_home() { am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1; }

# What is on screen right now? The reason to ask is the home swap: if the new
# home does not actually come up - it crashed, the ROM ignored the role change,
# the activity was disabled - the phone has no home screen at all, and that must
# be detected and undone rather than left for the user to discover.
#
#   ours    - our home activity is the resumed one
#   other   - something else is on screen (which includes a crashed home: a home
#             that dies is not the resumed activity)
#   unknown - the device did not tell us, so nothing is concluded from it
#
# Only SpsmHomeActivity counts as ours. SetupActivity being on screen is "the
# app the user just pressed Turn on in", not a working home.
home_resumed() {
  has dumpsys || { echo unknown; return; }
  _line=$(dumpsys activity activities 2>/dev/null \
            | grep -m1 -E 'topResumedActivity|ResumedActivity|mResumedActivity')
  if [ -z "$_line" ]; then
    echo unknown
    return
  fi
  case "$_line" in
    *SpsmHomeActivity*) echo ours ;;
    *) echo other ;;
  esac
}

# ------------------------------------------------------------------ safety
#
# Two different jobs, deliberately kept apart.
#
# safety_force() is the crash net: it runs at boot (post-fs-data) when we may
# have no journal at all and must guarantee the phone is usable - online cores,
# a sane governor, a visible panel. It overrides, because in that situation
# there is no recorded "before" to be faithful to.
#
# safety_unlock() runs after a normal, journalised revert. By then every value
# has already been put back (or deliberately left alone because someone else
# changed it), so this must NOT override anything - doing so would clobber a
# user's own choice, like cores they had offline on purpose.

safety_force() {
  for n in 0 1 2 3 4 5 6 7; do
    _f="/sys/devices/system/cpu/cpu$n/online"
    [ -e "$(rp "$_f")" ] && printf '%s\n' 1 > "$(rp "$_f")" 2>/dev/null
  done
  for p in "$SPSM_ROOT"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -w "$p/scaling_governor" ] && printf '%s\n' schedutil > "$p/scaling_governor" 2>/dev/null
  done
  _bl=$(rd "$BL_PATH")
  [ -n "$_bl" ] && printf '%s\n' 128 > "$(rp "$BL_PATH")" 2>/dev/null
  log "safety_force: cores online, governor schedutil"
}

safety_unlock() {
  # Runs at the end of a revert (and after the deep phase is released). It must
  # never override a value the user owns, so it acts only when all of these are
  # true:
  #   - the journal says brightness_cap is still holding a value of ours, i.e.
  #     the revert did not finish. If it did, the brightness on screen is the
  #     user's own, however dark they like it.
  #   - the mode is off, so a dark screen cannot be the mode doing its job.
  #   - the screen is on and unreadably dark.
  case "$(j_state brightness_cap)" in
    applied|restored-drift) ;;
    *) return 0 ;;
  esac
  [ -f "$ACTIVE" ] && return 0
  [ "$(screen_state)" = "on" ] || return 0
  _bl=$(rd "$BL_PATH")
  [ -n "$_bl" ] || return 0
  # "Unreadably dark" and "readable again" are fractions of the panel this
  # device actually has, not fixed numbers: the old 40/128 were calibrated for a
  # 0..255 node, and on this 0..4095 one 128 is barely brighter than the cap
  # that is being lifted - an emergency net that lifts nothing.
  _max=$(screen_panel_ceiling)
  _dark=$((_max / 10))
  _lift=$((_max * 40 / 100))
  [ "$_bl" -lt "$_dark" ] 2>/dev/null || return 0
  printf '%s\n' "$_lift" > "$(rp "$BL_PATH")" 2>/dev/null
  log "safety_unlock: backlight was still ours and unreadably dark (${_bl}/${_max}) - lifted to ${_lift}"
}

# How many knobs left a record behind? Zero means a revert has nothing to work
# from.
journal_entries() {
  ls "$JOURNAL"/*.orig 2>/dev/null | wc -l | tr -d ' '
}

# Tidy the scratch dir the parallel reads use. Each read removes its own file as
# it is consumed, so anything left here is from an engine that was killed
# mid-run; an hour is long past any legitimate use.
tmp_sweep() {
  [ -d "$SPSM_DIR/.tmp" ] || return 0
  find "$SPSM_DIR/.tmp" -type f -mmin +60 -exec rm -f {} + 2>/dev/null
  return 0
}

# Drift, from the journal rather than from fresh reads.
#
# The revert that just ran wrote each knob's verdict into its state file, and
# re-reading every value to ask the same question again cost a phone in this
# mode several seconds on the way out - per action, every time. The states are
# written by the revert itself, milliseconds earlier, so this is the same answer
# the full check would give unless something changed in between. The full,
# read-based check is still what `engine.sh verify` does, and what a human runs
# when they want to be told the truth about the device.
drift_from_journal() {
  _n=0
  for _f in "$JOURNAL"/*.state; do
    [ -f "$_f" ] || continue
    case "$(cat "$_f" 2>/dev/null)" in
      restored-drift) _n=$((_n + 1)) ;;
    esac
  done
  echo "$_n"
}

# How many knobs are still marked as applied (or as a revert that did not
# finish)? This - not the existence of a journal - is the question to ask before
# forcing values back onto a phone. A journal full of finished records is just
# paper.
pending_knobs() {
  _n=0
  for _f in "$JOURNAL"/*.state; do
    [ -f "$_f" ] || continue
    case "$(cat "$_f" 2>/dev/null)" in
      applied|restored-drift) _n=$((_n + 1)) ;;
    esac
  done
  echo "$_n"
}
