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
SCRIPT_VERSION_STAMP="$STATE/script_version"

# ------------------------------------------------------------------ version
# Which code is actually running.
#
# This exists because of a support problem that cost a whole round trip: a log
# arrived that could not be told apart from one written two versions earlier, and
# the honest answer to "did my flash take effect?" was "I cannot tell from this".
# Now every session header, every status line and every install records it, so a
# log identifies itself.
spsm_version() {
  if [ -f "$SPSM_DIR/moddir" ]; then
    _md=$(cat "$SPSM_DIR/moddir" 2>/dev/null)
    _v=$(sed -n 's/^version=//p' "$_md/module.prop" 2>/dev/null | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
  fi
  # The module directory is not known yet (first run after a flash): ask the
  # conventional location as well before giving up.
  for _md in /data/adb/modules/axion_spsm /data/adb/modules_update/axion_spsm; do
    _v=$(sed -n 's/^version=//p' "$_md/module.prop" 2>/dev/null | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return; }
  done
  printf '%s' 'unknown'
}

# What the scripts on this phone think they are. The stamp is written next to the
# scripts whenever they are published, so a mismatch between this and the module
# is exactly "this phone is running stale code".
scripts_stamp() { cat "$SCRIPT_VERSION_STAMP" 2>/dev/null; }

# The code's own version, baked in at build time by build.sh. Written from
# module.prop so there is one authority; falls back to the module directory.
SPSM_CODE_VERSION=$(scripts_stamp)
[ -n "$SPSM_CODE_VERSION" ] || SPSM_CODE_VERSION=$(spsm_version)

# A stale copy of the scripts is the one failure that makes every other fix
# invisible: the user flashes a new zip, /data/adb/spsm/scripts keeps the old
# files, and the new code is never executed. Publishing them is cheap (a dozen
# small files), so every entry point does it when the versions disagree and says
# so in the log.
sync_scripts() {
  _want=$(spsm_version)
  _have=$(scripts_stamp)
  [ "$_want" = "unknown" ] && return 0
  [ "$_want" = "$_have" ] && return 0
  _md=''
  [ -f "$SPSM_DIR/moddir" ] && _md=$(cat "$SPSM_DIR/moddir" 2>/dev/null)
  [ -d "$_md/scripts" ] || _md=/data/adb/modules/axion_spsm
  [ -d "$_md/scripts" ] || return 0
  # Never copy onto ourselves while a run is in flight: the files being replaced
  # are the ones currently executing. The next entry point picks them up.
  # One file at a time, through a temporary name and a rename: the scripts being
  # replaced are the ones currently executing, and a shell reading a script that
  # is rewritten underneath it is a real way to corrupt a run.
  for _f in "$_md/scripts/"*.sh; do
    [ -f "$_f" ] || continue
    _b=${_f##*/}
    cp -f "$_f" "$SPSM_DIR/scripts/$_b.new" 2>/dev/null && mv -f "$SPSM_DIR/scripts/$_b.new" "$SPSM_DIR/scripts/$_b" 2>/dev/null
  done
  chmod 755 "$SPSM_DIR/scripts/"*.sh 2>/dev/null
  printf '%s\n' "$_want" > "$SCRIPT_VERSION_STAMP" 2>/dev/null
  log "scripts updated: this phone was running ${_have:-nothing}, the module is $_want - the new code takes effect from the next switch"
}

# ------------------------------------------------------------------ native
# The native helpers, and which build of them this phone can run.
#
# The module ships arm64-v8a and armeabi-v7a (see native/build.sh) because it
# does not get to choose the phone it lands on. The ABI is asked of the device
# rather than guessed, and the answer is verified by RUNNING the binary: a
# helper that is the wrong ABI, or that a kernel refuses, must be found out
# here - at install and at boot - and not by the daemon at two in the morning.
#
# Nothing in the module requires these to exist. If none can run, the binary is
# simply not published and the daemon polls exactly as it always did.
SPSM_BIN="$SPSM_DIR/bin"

# Which ABI directory suits this phone, most specific first.
native_abi_list() {
  _a1=$(getprop ro.product.cpu.abi 2>/dev/null)
  _a2=$(getprop ro.product.cpu.abilist 2>/dev/null)
  case "$_a1$_a2" in
    *arm64*) printf 'arm64-v8a armeabi-v7a' ;;
    *armeabi*|*armv7*) printf 'armeabi-v7a' ;;
    *x86_64*) printf 'x86_64 host' ;;
    # An unknown or unreadable ABI is not a reason to give up: try both, and
    # let the exec test below decide. A wrong guess costs one failed exec.
    *) printf 'arm64-v8a armeabi-v7a' ;;
  esac
}

# Copy the helpers this phone can actually run into $SPSM_BIN. Called by the
# installer and by service.sh on every boot, so a module update replaces them.
publish_native() { # publish_native <module dir>
  _md=$1
  [ -d "$_md/bin" ] || return 0
  mkdir -p "$SPSM_BIN" 2>/dev/null
  for _abi in $(native_abi_list); do
    [ -d "$_md/bin/$_abi" ] || continue
    _ok=1
    for _f in "$_md/bin/$_abi/"*; do
      [ -f "$_f" ] || continue
      _b=${_f##*/}
      cp -f "$_f" "$SPSM_BIN/$_b.new" 2>/dev/null || { _ok=''; break; }
      chmod 755 "$SPSM_BIN/$_b.new" 2>/dev/null
      mv -f "$SPSM_BIN/$_b.new" "$SPSM_BIN/$_b" 2>/dev/null || { _ok=''; break; }
    done
    [ -n "$_ok" ] || continue
    # Proof, not faith: a binary that cannot be executed on this phone is worse
    # than none, because the daemon would start it and get nothing back. It is
    # asked to run with no arguments, which it answers with a usage line and
    # status 2 - enough to prove the kernel loaded it and ran its main().
    #
    # The status is captured straight off the call. Reading `$?` after an
    # intervening `if` reads the `if`'s status, not the program's - which would
    # have made this test say yes to a binary that never ran at all.
    "$SPSM_BIN/spsm-screenmon" >/dev/null 2>&1
    _rc=$?
    # 126/127 are the shell's "cannot execute" and "not found"; anything else
    # means the image loaded.
    if [ "$_rc" != 126 ] && [ "$_rc" != 127 ] && [ -x "$SPSM_BIN/spsm-screenmon" ]; then
      log "native helpers: $_abi"
      printf '%s\n' "$_abi" > "$STATE/native_abi" 2>/dev/null
      return 0
    fi
  done
  rm -f "$SPSM_BIN/spsm-screenmon" 2>/dev/null
  log "native helpers: none of the shipped builds run here - the daemon will poll"
  return 0
}

# /data/adb/spsm must exist before anything else references it.
#
# Guarded, because this line runs on every single sourcing of lib.sh and the
# engine sources it from every subshell it fans out - so a directory that has
# existed since installation was costing a fork per worker. `mkdir -p` on an
# existing tree is a no-op that still pays for a process; the test is free.
[ -d "$STATE" ] && [ -d "$ORIG_DIR" ] ||
  mkdir -p "$SPSM_DIR" "$ORIG_DIR" "$STATE" 2>/dev/null

# ------------------------------------------------------------------ logging
LOG_MAX=400000
# Is there a way to get the time without forking?
#
# `date` is a fork per log line, measured at ~1.4ms, and an activation writes
# dozens of lines while the user is waiting for the mode to come on. Android's
# /system/bin/sh is mksh, whose printf understands the %(...)T time format, as
# does bash; dash does not. Probed once at load, not once per line.
if printf '%(%Y)T' -1 >/dev/null 2>&1; then
  _STAMP_FMT='%(%Y-%m-%d %H:%M:%S)T'
  now_stamp() { printf "$_STAMP_FMT" -1; }
  # The same trick for the epoch seconds the engine uses for every duration,
  # timeout and age check. `date +%s` was 112 execs in one activation.
  #
  # With one exception, and it matters: the test suite injects a FAKE clock by
  # putting a `date` stub on PATH, so that an hourly drain rate can be asserted
  # without the test sleeping for an hour. A printf builtin reads the kernel
  # directly and would sail straight past that stub - the module would keep
  # working while every time-travel test quietly measured real time instead.
  #
  # So the builtin is used only when no such stub is present. On a phone there
  # is none and this is a pure saving; under the suite the fork comes back and
  # the injected clock still works. A faster implementation that defeats the
  # tests which prove it correct is not a good trade.
  if command -v date >/dev/null 2>&1 &&
     case $(command -v date) in /system/bin/date|/bin/date|/usr/bin/date|/xbin/date) false ;; *) true ;; esac
  then
    now_epoch() { date +%s; }
  else
    now_epoch() { printf '%(%s)T' -1; }
  fi
else
  now_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
  now_epoch() { date +%s; }
fi

log() {
  _line="$(now_stamp) $*"
  echo "$_line" >> "$LOG" 2>/dev/null
  # The kernel log, for the lines that matter when a phone will not boot and
  # the module's own log is on a partition nobody can reach yet.
  #
  # This used to be written for EVERY line. /dev/kmsg is a real device write -
  # it is not free, it is serialised against every other kernel log writer on
  # the system, and the module's chatter is not what anyone is reading dmesg
  # for. It is also usually not writable at all outside early boot, so most of
  # those writes were a failed open per line. It is kept for the session
  # headers and the failures, which is what it was for, and skipped for the
  # routine narration.
  case "$*" in
    *WARN*|*FAIL*|*fail*|*error*|*ERROR*|*panic*|*recover*|*"daemon start"*|*"=== "*)
      echo "SPSM: $*" > /dev/kmsg 2>/dev/null ;;
  esac
  # The size check is a fork (`wc`), and it ran on every single line: an
  # activation writes dozens of lines, so dozens of forks went into answering a
  # question whose answer moves by a few hundred bytes. It is asked every
  # twentieth line now - the log is trimmed at 400 kB and twenty lines is far
  # less than that.
  LOG_N=$(( ${LOG_N:-0} + 1 ))
  [ "$LOG_N" -lt 20 ] && return 0
  LOG_N=0
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
# lock_acquire [priority]
#
# "high" is for the exit. Everything else in this module exists to serve the
# exit's promise - put everything back - and an exit that waits twenty seconds
# behind an in-flight screen transition, only to undo the same work, is both slow
# and a source of false drift: on the device the exit and the screen-on revert
# were writing the same CPU nodes at the same time, and each then reported the
# other's value as "did not return to its original value".
#
# So a high-priority caller waits a moment, and then ends the other worker if it
# is one of ours (engine.sh or daemon.sh - never anything else) and takes the
# lock. Killing it is safe precisely because the exit does a full revert anyway;
# the worker's half-finished work is exactly what the exit is about to redo.
# Drop this worker's priority to the floor. Every fan worker calls it first:
# on cores the governor holds at minimum, the phone's own interface must win
# the race for the CPU - the navigation bar is SystemUI drawing, and the owner
# watched it vanish for whole seconds while fans ran at normal priority. The
# pid comes from /proc/self/stat, whose first field is the reading process's
# own pid: $$ here would name the parent shell, and renicing that would drag
# the daemon down with the worker.
bg_nice() {
  _bp=''
  read -r _bp _ < /proc/self/stat 2>/dev/null
  [ -n "$_bp" ] && renice 19 -p "$_bp" >/dev/null 2>&1
  return 0
}

lock_acquire() {
  _prio=$1
  _i=0
  _limit=100
  [ "$_prio" = high ] && _limit=10
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
          _age=$(($(now_epoch) - _mt))
          if [ "$_age" -gt 600 ] 2>/dev/null; then
            log "WARN stale lock (${_age}s, pid ${_p:-unknown}) - taking it"
            rm -rf "$LOCK"
          fi
          ;;
      esac
    fi
    # High priority: the exit takes the lock from its own worker rather than
    # waiting for it. Only a process whose command line says engine.sh or
    # daemon.sh is ever ended; anything else keeps the lock until it lets go.
    if [ "$_prio" = high ] && [ -n "$_p" ] && [ -d "/proc/$_p" ] && [ "$_i" -ge 10 ]; then
      case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
        *engine.sh*|*daemon.sh*)
          log "exit preempted an in-flight transition (pid $_p) - it was about to be undone anyway"
          kill "$_p" 2>/dev/null
          sleep 0.3 2>/dev/null || sleep 1
          [ -d "/proc/$_p" ] && kill -9 "$_p" 2>/dev/null
          rm -rf "$LOCK"
          continue
          ;;
      esac
    fi
    _i=$((_i + 1))
    [ "$_i" -gt "$_limit" ] && { log "WARN lock timeout (held by pid ${_p:-unknown})"; return 1; }
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
#
# The common case is answered without a process. Almost every value this module
# handles is a short, ordinary one - "1", "0", "schedutil", "1800000",
# "com.android.launcher3/.Launcher" - with no backslash and no newline in it, and
# for those the escaped form is just the value with a "\n" on the end. Deciding
# that costs one `case`; the sed|tr pipeline that used to answer it costs two
# processes, and it ran once per target, on every snapshot, of every knob.
#
# Anything with a backslash or a newline in it still goes down the original
# pipeline, unchanged - correctness is not what is being traded here, only the
# forks for the values that never needed them.
esc() {
  case "$1" in
    # The empty value is NOT the fast path: sed reads no lines from empty input
    # and so emits nothing at all, where the obvious shortcut would write "\n".
    # The equivalence suite (tests/run-codec.sh) caught exactly this, which is
    # why that suite exists - an empty reading is a real thing here (a Settings
    # row that is unset), and encoding it differently from the implementation
    # this replaced would put a value into the journal that was never there.
    '') printf '\n'; return ;;
    *\\*|*'
'*) ;;
    *) printf '%s\\n\n' "$1"; return ;;
  esac
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/$/\\n/' | tr -d '\n'
  printf '\n'
}
unesc() {
  # The exact inverse of esc's fast path, and just as forkless: a value that
  # esc could encode without a process is one whose encoding is the value plus
  # a trailing "\n" and no other backslash. Stripping that suffix is a
  # parameter expansion. The awk below is the general case and is still what
  # decides anything with a backslash left in it.
  case "$1" in
    *\\n)
      _ue=${1%'\n'}
      case "$_ue" in
        *\\*) ;;                      # a real backslash: the general case owns it
        *) printf '%s\n' "$_ue"; return ;;
      esac
      ;;
  esac
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
# A carriage return, as a value a `case` pattern can test against. The comparison
# helpers below use it to recognise - without forking `tr` - the values that
# genuinely need the slow, general cleanup.
CR=$(printf '\r')

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
# Two processes per lookup, and the verdict loops ask for a value once per
# target per pass - so this was the most-forked helper in a revert. A snapshot
# is a handful of short lines held in a variable, and walking it in the shell
# costs no process at all.
#
# The split is done by setting IFS to a newline and reusing the positional
# parameters, which keeps the work in THIS shell: a `while read` fed by a pipe
# would run in a subshell (another fork, and in some shells the result would be
# lost with it).
snap_get() {
  _sg_want=$2
  _sg_old=$IFS
  IFS='
'
  # shellcheck disable=SC2086
  set -- $1
  IFS=$_sg_old
  for _sg_line in "$@"; do
    case "$_sg_line" in
      "$_sg_want$TAB"*)
        _sg_v=${_sg_line#*$TAB}
        # awk's $2 ends at the NEXT separator, so a record that somehow holds a
        # second tab yields only the field between them. Matching that exactly
        # matters: the equivalence suite compares the two implementations
        # byte-for-byte, and "everything after the first tab" is a different
        # function. (Values are encoded to be tab-free, so this is about being
        # provably identical rather than about a case that should occur.)
        printf '%s' "${_sg_v%%$TAB*}"
        return ;;
    esac
  done
  return 0
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


# Classify a finished revert for one knob:
#   restored - every value is back to what it was before SPSM touched it
#   kept     - the only differences are values somebody else changed later
#   drift    - a value of ours is still in place that we should have undone
# A value as a person would read it: a carriage return or a trailing space from
# a shell command is not a value that failed to come back. The device log once
# reported a knob as unrestored while printing the same value on both sides of
# the sentence, which is a thing nobody can act on.
# Three processes per call, and the revert verdict asks it up to five times per
# target - so a knob with six values spent thirty processes deciding whether
# anything had moved. The overwhelmingly common value ("1", "0", "powersave",
# a frequency) has no backslash, no carriage return and no trailing space, and
# for that value this function is the identity: one `case` answers it.
#
# The general path is kept verbatim underneath and still handles every value the
# fast path declines, so what a comparison MEANS is unchanged.
cmp_val() { # cmp_val <encoded>
  case "$1" in
    *\\n)
      _cv=${1%'\n'}
      case "$_cv" in
        *\\*|*"$CR"*|*' '|*"$TAB") ;;   # needs the real thing
        *) printf '%s' "$_cv"; return ;;
      esac
      ;;
    '')  printf ''; return ;;
    *\\*|*"$CR"*|*' '|*"$TAB") ;;
    *) printf '%s' "$1"; return ;;
  esac
  printf '%s' "$(unesc "$1")" | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

# Which values came back different, named, with both sides spelled out. The log
# used to print a truncated blob of every value in the knob, so a difference
# beyond the 200th character was invisible.
drift_list() { # drift_list now-text orig-text
  for _t in $(snap_targets "$2"); do
    _o=$(snap_get "$2" "$_t")
    [ "$(cmp_val "$_o")" = "(MISSING)" ] && continue
    _n=$(snap_get "$1" "$_t")
    _ov=$(cmp_val "$_o")
    _nv=$(cmp_val "$_n")
    [ "$_nv" = "$_ov" ] && continue
    # Same rule as revert_verdict: a target the current reading does not mention
    # has left the knob's scope (an app moved into the six slots), and naming it
    # as a value that "did not return" is a false alarm about a deliberate act.
    [ -z "$_n" ] && continue
    printf '%s: want [%s] got [%s]; ' "$_t" "$_ov" "$_nv"
  done
  return 0
}

revert_verdict() { # revert_verdict now-text orig-text applied-text
  _now=$1; _orig=$2; _applied=$3
  _drift=0; _kept=0
  for _t in $(snap_targets "$_orig"); do
    _o=$(snap_get "$_orig" "$_t")
    # A target whose original could not be read is one we never changed: the
    # apply side refuses to write a value it could not read the original of (see
    # apply_kv). Comparing that unreadable marker against a real reading later
    # therefore proves nothing, and calling the difference drift is a false
    # alarm - the two keys this phone refuses to read were doing exactly that on
    # every exit, naming a value as unrestored that was never touched.
    [ "$(cmp_val "$_o")" = "(MISSING)" ] && continue
    _n=$(snap_get "$_now" "$_t")
    [ "$(cmp_val "$_n")" = "$(cmp_val "$_o")" ] && continue
    # A target the CURRENT snapshot does not mention at all is not a value that
    # failed to come back - it is a target that has left this knob's scope, and
    # there is nothing on the device to compare.
    #
    # The case that proved it: an app moved into one of the six slots. The slots
    # are the keep-working list, so `allow` frees the app and it stops being a
    # blockable package - the next snapshot simply has no row for it. Comparing
    # that absence against its recorded "0" read as "want [0] got []", and every
    # exit after a slot change reported a phantom unrestored value, naming an app
    # the module had deliberately and correctly released.
    #
    # An absent row is skipped. The knob's own restore still handles anything it
    # really did change, and a value that is genuinely still ours is still in the
    # snapshot to be caught.
    [ -z "$_n" ] && continue
    _a=$(snap_get "$_applied" "$_t")
    if [ -n "$_a" ] && [ "$(cmp_val "$_n")" != "$(cmp_val "$_a")" ]; then
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
# A compact "what changed" list between two snapshots: "target: before -> after",
# one per line, or "no change". Used by the probe to say what an option actually
# did on this phone rather than only that it ran.
snap_diff() { # snap_diff <before> <after>
  _any=0
  for _t in $(snap_targets "$1" "$2"); do
    _b=$(snap_get "$1" "$_t")
    _a=$(snap_get "$2" "$_t")
    [ "$_a" = "$_b" ] && continue
    _any=$((_any + 1))
    printf '%s: %s -> %s; ' "$_t" "$(unesc "$_b")" "$(unesc "$_a")"
  done
  [ "$_any" = "0" ] && printf 'no change'
  return 0
}

# Every target mentioned by either snapshot - the diff above must not miss a
# target that only exists on one side.
# Same reasoning: three processes to list the names in two short texts. The
# de-duplication is a substring test against what has already been emitted,
# which is exact because every name is bounded by newlines on both sides.
snap_targets() {
  _st_old=$IFS
  IFS='
'
  # shellcheck disable=SC2086
  set -- $1 $2
  IFS=$_st_old
  _st_seen='
'
  for _st_line in "$@"; do
    case "$_st_line" in
      *"$TAB"*) ;;
      *) continue ;;
    esac
    _st_t=${_st_line%%$TAB*}
    [ -n "$_st_t" ] || continue
    case "$_st_seen" in
      *"
$_st_t
"*) continue ;;
    esac
    _st_seen="$_st_seen$_st_t
"
    printf '%s\n' "$_st_t"
  done
  return 0
}

norm() {
  printf '%s\n' "$1" | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

# ------------------------------------------------------------------ journal

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
  [ -d "$ORIG_DIR" ] || mkdir -p "$ORIG_DIR" 2>/dev/null
  if [ "$_kept" = "0" ]; then
    # Nothing carried over, so the per-package sub-journals are finished too -
    # and the records of what we suspended and which radios we found on belong to
    # the session that wrote them, so they go with it. Leaving them behind would
    # make a later session believe it had switched radios it never touched.
    rm -f "$ORIG_DIR"/*.tsv "$STATE/blocked_by_us.tsv" 2>/dev/null
    : > "$APPLIED_ORDER"
  else
    log "journal kept: $_kept unfinished knob(s) from a session that never exited"
  fi
}

# ------------------------------------------------------------------ config
# config is a flat key=value file the APK writes and the user can hand-edit.
# Three processes per lookup - a subshell, a sed and a tail - against a file of
# a few dozen short lines, and the engine asks it once per knob per loop. The
# status the app polls spent 36 seds and 32 tails here and nowhere else.
#
# The file is read ONCE into a variable instead, and every later lookup walks
# that variable. "Once" is per shell: each engine invocation, and each subshell
# of a parallel fan, loads it the first time it asks. The config is written by
# the app between runs rather than during one, and the one writer inside a run
# (do_set) calls cfg_invalidate after it writes, so a live change is still seen.
#
# The last assignment for a key wins, exactly as `tail -1` made it.
_CFG_CACHE=''
_CFG_LOADED=''

cfg_load() {
  _CFG_CACHE=''
  if [ -f "$CONFIG" ]; then
    while IFS= read -r _cfg_line || [ -n "$_cfg_line" ]; do
      case "$_cfg_line" in
        *=*) _CFG_CACHE="$_CFG_CACHE$_cfg_line
" ;;
      esac
    done < "$CONFIG"
  fi
  _CFG_LOADED=1
}

# Anything that writes the config calls this, so the next read sees the write.
cfg_invalidate() { _CFG_LOADED=''; }

cfg() { # cfg key default
  [ -n "$_CFG_LOADED" ] || cfg_load
  _cfg_key=$1
  _cfg_def=$2
  _cfg_hit=''
  _cfg_rest=$_CFG_CACHE
  # Walked as a string rather than with `set --`: the positional parameters are
  # how the key and the default arrived, and overwriting them here is how the
  # first version of this function lost track of what it was looking for.
  while [ -n "$_cfg_rest" ]; do
    _cfg_line=${_cfg_rest%%
*}
    case "$_cfg_rest" in
      *"
"*) _cfg_rest=${_cfg_rest#*"
"} ;;
      *) _cfg_rest='' ;;
    esac
    case "$_cfg_line" in
      "$_cfg_key="*) _cfg_hit=${_cfg_line#*=} ;;   # keep the last one
    esac
  done
  [ -n "$_cfg_hit" ] && { printf '%s' "$_cfg_hit"; return; }
  printf '%s' "$_cfg_def"
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
  # Returns what the write did. A caller that counts successes - the power-save
  # governor counts clusters that took it - must not be told a read-only file was
  # written. A path that does not exist is still "nothing to do", not a failure:
  # an optional node that this phone simply does not have is not an error.
  _p=$(rp "$2")
  [ -n "$2" ] && [ -e "$_p" ] || return 0
  printf '%s\n' "$1" > "$_p" 2>/dev/null
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

# Is this a function this shell has actually loaded?
#
#   [ "$(type foo 2>/dev/null)" ]     <- this is NOT the test it looks like.
#
# Android's sh prints "foo: inaccessible or not found" on STDOUT when the name
# does not exist, so that test is true for every function that is missing - and
# the engine then called it. The v3.6.1 log has the result on every knob without
# a note: a shell error next to a log line reading "note rom_bg_off:" with
# nothing after it.
has_function() { # has_function <name>
  command -v "$1" >/dev/null 2>&1 && return 0
  case "$(type "$1" 2>&1)" in
    ''|*'not found'*) return 1 ;;
  esac
  return 0
}

# ------------------------------------------------------------------ memory
# Free memory, in kilobytes, straight from the kernel: the number the background
# sweep reports before and after it stops the frozen apps. One redirection and a
# read - no process is spawned to look at one number, which matters because this
# runs on a power-saving path.
mem_available() {
  while read -r _k _v _u; do
    case "$_k" in MemAvailable:) printf '%s' "$_v"; return ;; esac
  done < /proc/meminfo
  printf '0'
}

# Kilobytes as something a log line can carry.
mem_words() { # mem_words <kb>
  _kb=${1:-0}
  case "$_kb" in ''|*[!0-9]*) printf '?'; return ;; esac
  if [ "$_kb" -ge 1048576 ]; then
    awk -v k="$_kb" 'BEGIN { printf "%.1fG", k / 1048576 }'
  else
    awk -v k="$_kb" 'BEGIN { printf "%.0fM", k / 1024 }'
  fi
}

# The packages with a process running right now, taken from the kernel's own
# process list. An app's process is named after its package, sometimes with a
# ":suffix" for a private service.
#
# This is the device data the ROM-background option works from: nothing is
# restricted because it appears on a list written somewhere else - only what is
# actually running on THIS phone is looked at.
running_packages() {
  has ps || return 0
  ps -A -o NAME 2>/dev/null | sed 's/:.*//' | grep '[a-z]' | sort -u
}

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
            _age=$(($(now_epoch) - $(stat -c %Y "$SCREEN_MARK" 2>/dev/null || echo 0)))
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

  # The panel was unreadable this tick, so something else has to answer.
  _mk=''
  [ -f "$SCREEN_MARK" ] && IFS= read -r _mk < "$SCREEN_MARK" 2>/dev/null

  # A marker that is only seconds old is a real event - the app saw the screen
  # change - so it is the best answer available, even ahead of dumpsys.
  if [ "$_mk" = "on" ] || [ "$_mk" = "off" ]; then
    _age=$(($(now_epoch) - $(stat -c %Y "$SCREEN_MARK" 2>/dev/null || echo 0)))
    if [ "$_age" -le "$SCREEN_MARK_GRACE" ] 2>/dev/null; then
      SCREEN_STATE=$_mk
      SCREEN_SRC="app-grace(${_age}s)"
      return
    fi
  fi

  # Then the system's own answer. It cannot be stale the way a file can - it is
  # the power manager being asked right now - so it outranks an old marker. This
  # phone has a readable panel, so this path is for the phone where it is not:
  # an unreadable panel with a marker left at "on" would otherwise be frozen into
  # believing the screen is on forever, which is the same silent no-saving
  # failure from the other direction.
  if has dumpsys; then
    _r=$(screen_dumpsys)
    case "$_r" in
      on|off)
        SCREEN_STATE=$_r
        SCREEN_SRC=dumpsys
        return
        ;;
    esac
  fi

  # An old marker, then plain "on" - a screen we cannot read is never allowed to
  # be called asleep on the strength of a guess: wrongly believing "off" while
  # somebody is using the phone is the expensive direction.
  case "$_mk" in
    on|off) SCREEN_STATE=$_mk; SCREEN_SRC=app; return ;;
  esac
  SCREEN_STATE=on
  SCREEN_SRC=assumed
}

# `dumpsys power` is a binder dump, so it is cached for a few seconds and only
# the degraded path above ever pays for it. The cache file's mtime is the clock:
# one stat is a fraction of the dump it replaces.
SCREEN_DUMP_CACHE=$(cfg screen_dump_cache 15)
screen_dumpsys() { # prints on|off, from the cache when it is fresh
  if [ -f "$STATE/screen_dump" ]; then
    _age=$(($(now_epoch) - $(stat -c %Y "$STATE/screen_dump" 2>/dev/null || echo 0)))
    if [ "$_age" -le "$SCREEN_DUMP_CACHE" ] 2>/dev/null; then
      cat "$STATE/screen_dump" 2>/dev/null
      return
    fi
  fi
  _st=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)
  case "$_st" in
    Awake|Dreaming) _r=on ;;
    Asleep|Dozing) _r=off ;;
    *) return ;;
  esac
  printf '%s\n' "$_r" > "$STATE/screen_dump" 2>/dev/null
  printf '%s' "$_r"
}

# What the marker says and how old it is, for the log. Only asked for on a
# transition - it costs two processes, which is not a price a one-second poll can
# pay on every tick.
marker_word() {
  [ -f "$SCREEN_MARK" ] || { printf '%s' '-'; return; }
  _mk=''
  IFS= read -r _mk < "$SCREEN_MARK" 2>/dev/null
  _age=$(($(now_epoch) - $(stat -c %Y "$SCREEN_MARK" 2>/dev/null || echo 0)))
  printf '%s@%ss' "${_mk:--}" "$_age"
}

screen_state() { # screen_state - prints on|off
  screen_decide "$(rd "$BL_PATH")" ''
  printf '%s' "$SCREEN_STATE"
}

# One pm call for a whole batch of packages. The phone answers
# `pm suspend --user 0 p1 p2 ... p40` exactly as it answers forty single
# calls - so 186 packages cost five binder round-trips instead of 186 forks,
# and the exit that spent 100s releasing the record drops to seconds. A
# chunk the phone refuses falls back to the proven per-app path, which
# reports only the packages that actually took. Packages that succeeded are
# printed, one per line.
pm_batch() { # pm_batch <suspend|unsuspend>  (package list on stdin)
  _act=$1
  _pb_acc=''
  _pb_n=0
  _pb_chunk() {
    if su 2000 -c "pm $_act --user 0$_pb_acc" >/dev/null 2>&1 \
       || pm "$_act" --user 0$_pb_acc >/dev/null 2>&1; then
      printf '%s\n' $_pb_acc
    else
      for _p in $_pb_acc; do
        if [ "$_act" = suspend ]; then
          suspend_app "$_p" && printf '%s\n' "$_p"
        else
          unsuspend_app "$_p" && printf '%s\n' "$_p"
        fi
      done
    fi
    _pb_acc=''
    _pb_n=0
  }
  while read -r _bp; do
    [ -n "$_bp" ] || continue
    _pb_acc="$_pb_acc $_bp"
    _pb_n=$((_pb_n + 1))
    [ "$_pb_n" -ge 40 ] && _pb_chunk
  done
  [ -n "$_pb_acc" ] && _pb_chunk
  return 0
}

# ------------------------------------------------------- suspend, without root
# Suspends an app through the shell uid (2000), not as root.
#
# PackageManager records WHICH package suspended an app, and for a root caller
# that name is literally "root" - which is not a package. Android's own
# suspended-app dialog reports the interaction against that name the moment any
# of its buttons is pressed, and system_server dies with
# "IllegalArgumentException: Package root does not exist!" - the crash the
# owner's Logfox shows as "Android:ui" every time he taps through the dialog.
# The shell uid may suspend (com.android.shell holds android.permission.
# SUSPEND_APPS) and is a real package, so the dialog has something real to
# point at and no crash.
#
# `su 2000 -c` is probed once, and the answer is kept in a state file: the
# callers run one subshell per app, and the probe costs a su round trip. If
# the demotion ever fails, the plain root suspend still runs - the mode must
# never lose the suspension itself over the nicer name.
suspend_app() { # suspend_app <package>
  _d="$SPSM_DIR/.tmp"
  # Per package, so the fork is worth avoiding: these run in a loop over every
  # app on the phone.
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  _sf="$_d/su2000"
  [ -f "$_sf" ] || {
    if su 2000 -c true >/dev/null 2>&1; then printf '1\n' > "$_sf"; else printf '0\n' > "$_sf"; fi
  }
  if [ "$(cat "$_sf" 2>/dev/null)" = 1 ] \
     && su 2000 -c "pm suspend --user 0 $1" >/dev/null 2>&1; then
    return 0
  fi
  pm suspend --user 0 "$1" >/dev/null 2>&1 || pm suspend "$1" >/dev/null 2>&1
}

# The reverse, built the same way and with the same rule: pm unsuspend is
# idempotent, so it is called WITHOUT asking anything first. Every gate that
# used to sit in front of an unsuspend - "is it in our record", "does dumpsys
# say suspended=true" - was a way to not free an app the user had just put in
# a slot, and on this phone dumpsys does not answer in the words those gates
# expected (the v3.7.5 log shows allow lines with no unsuspend behind them,
# and an exit that skipped every release). An app in the six slots is usable.
unsuspend_app() { # unsuspend_app <package>
  _d="$SPSM_DIR/.tmp"
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  _sf="$_d/su2000"
  [ -f "$_sf" ] || {
    if su 2000 -c true >/dev/null 2>&1; then printf '1\n' > "$_sf"; else printf '0\n' > "$_sf"; fi
  }
  # First through the same identity that suspended it: whatever permitted the
  # suspension permits its undo.
  if [ "$(cat "$_sf" 2>/dev/null)" = 1 ] \
     && su 2000 -c "pm unsuspend --user 0 $1" >/dev/null 2>&1; then
    return 0
  fi
  pm unsuspend --user 0 "$1" >/dev/null 2>&1 || pm unsuspend "$1" >/dev/null 2>&1
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
# What Android currently answers for the home activity, as one line the log can
# carry. Read-only, and never a reason to fail: a phone that will not answer says
# so in the line.
home_activity_now() {
  if has cmd; then
    _r=$(cmd package resolve-activity --brief -a android.intent.action.MAIN \
            -c android.intent.category.HOME 2>/dev/null | tail -n 1)
    [ -n "$_r" ] && { printf '%s\n' "$_r"; return; }
  fi
  printf 'unknown\n'
}

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
  [ -d "$JOURNAL" ] || { echo 0; return; }
  _n=$(grep -l -E '^restored-drift$' "$JOURNAL"/*.state 2>/dev/null | wc -l)
  _n=${_n##* }
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  echo "$_n"
}

# How many knobs are still marked as applied (or as a revert that did not
# finish)? This - not the existence of a journal - is the question to ask before
# forcing values back onto a phone. A journal full of finished records is just
# paper.
pending_knobs() {
  # One `grep -l` over the journal rather than a `cat` per file: this is asked
  # twice in every exit (once for the launcher refresh, once for the safety
  # net), and a fork per knob for a question grep can answer in one pass is a
  # second of a slow phone's time on the way out.
  [ -d "$JOURNAL" ] || { echo 0; return; }
  _n=$(grep -l -E '^(applied|restored-drift)$' "$JOURNAL"/*.state 2>/dev/null | wc -l)
  _n=${_n##* }
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  echo "$_n"
}
