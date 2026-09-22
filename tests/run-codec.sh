#!/bin/sh
# The value codec, proved equivalent - not assumed.
#
# esc/unesc/cmp_val grew zero-fork fast paths for the values this module
# actually handles ("1", "powersave", a frequency, a component name). A fast
# path that is not EXACTLY the function it short-circuits is a corrupted
# journal, and a corrupted journal is the one failure this module cannot have:
# it is what "turning the mode off puts everything back" rests on.
#
# So this compares the two implementations directly. The reference versions are
# the pre-optimisation ones, pasted here verbatim; every value below goes
# through both, and the outputs must be byte-identical.
#
#   tests/run-codec.sh

REPO=$(cd "$(dirname "$0")/.." && pwd)
SPSM_DIR=${TMPDIR:-/tmp}/spsm-codec
rm -rf "$SPSM_DIR"; mkdir -p "$SPSM_DIR"
export SPSM_DIR

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }

# shellcheck source=/dev/null
. "$REPO/module/scripts/lib.sh"

# ------------------------------------------------- the reference implementations
ref_esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/$/\\n/' | tr -d '\n'
  printf '\n'
}
ref_unesc() {
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
ref_cmp_val() {
  printf '%s' "$(ref_unesc "$1")" | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

# ------------------------------------------------------------------ the corpus
# Ordinary values first (the ones the fast paths exist for), then every shape
# that has ever broken this codec in the field: a value that spans lines, a
# literal backslash-n, a Windows line ending, trailing space, the absence
# marker, and the empty reading.
CRLIT=$(printf '\r')
NL='
'
set -- \
  '1' '0' 'null' 'powersave' 'schedutil' '1800000' '4095' \
  'com.android.launcher3/.Launcher' \
  'dev.axion.spsm/.SpsmHomeActivity' \
  '(MISSING)' \
  'immersive.status=*' \
  'a b c' \
  'value with  two  spaces' \
  'trailing ' \
  'tab	inside' \
  "cr${CRLIT}inside" \
  "ends-with-cr${CRLIT}" \
  "two${NL}lines" \
  "three${NL}short${NL}lines" \
  'back\slash' \
  'literal\nbackslash-n' \
  'double\\backslash' \
  'ends-with-backslash\' \
  '\' \
  '\n' \
  '\\n' \
  'mixed\back'"${NL}"'and-newline' \
  ''

printf '\n\033[1;36m== the value codec is byte-identical to the implementation it replaced\033[0m\n'

_n=0
for v in "$@"; do
  _n=$((_n + 1))
  # 1. esc agrees
  a=$(esc "$v"); b=$(ref_esc "$v")
  if [ "$a" = "$b" ]; then ok; else bad "esc #$_n [$v]: fast [$a] ref [$b]"; fi

  # 2. unesc agrees, on the encoded form AND on the raw value
  for enc in "$a" "$v"; do
    a2=$(unesc "$enc"); b2=$(ref_unesc "$enc")
    if [ "$a2" = "$b2" ]; then ok; else bad "unesc #$_n [$enc]: fast [$a2] ref [$b2]"; fi
  done

  # 3. cmp_val agrees - this is the one a revert verdict is decided by
  for enc in "$a" "$v"; do
    a3=$(cmp_val "$enc"); b3=$(ref_cmp_val "$enc")
    if [ "$a3" = "$b3" ]; then ok; else bad "cmp_val #$_n [$enc]: fast [$a3] ref [$b3]"; fi
  done

  # 4. the round trip is the property the journal actually depends on:
  #    a value written out and read back must be the value.
  r=$(unesc "$(esc "$v")")
  if [ "$r" = "$v" ]; then ok; else bad "round trip #$_n: [$v] -> [$r]"; fi
done

# ------------------------------------------------- snap_get / snap_targets
# The same treatment for the two snapshot readers, which lost their awks for
# the same reason. A snapshot is "target<TAB>value" lines; the reference
# versions are the ones they replaced.
ref_snap_get() {
  printf '%s\n' "$1" | awk -F"$TAB" -v t="$2" '$1==t{print $2; exit}'
}
ref_snap_targets() {
  printf '%s\n%s\n' "$1" "$2" | awk -F"$TAB" 'NF>=2{print $1}' | awk '!seen[$0]++'
}

printf '\033[1;36m== the snapshot readers agree with the awks they replaced\033[0m\n'

mk() { printf '%s\t%s\n' "$1" "$2"; }

# Built with printf rather than by concatenating $( ) - command substitution
# strips trailing newlines, which silently glued every record onto one line and
# made the fixture a snapshot no phone would ever produce.
SNAP_A=$(printf '%s\t%s\n' \
  @global:wifi_on '1\n' \
  /sys/class/leds/lcd-backlight/brightness '900\n' \
  @secure:doze_always_on '(MISSING)' \
  %ro.some.prop 'a value with spaces\n')
SNAP_B=$(printf '%s\t%s\n' @global:wifi_on '0\n' @global:bluetooth_on '1\n')
# A record holding a second tab: the two implementations must agree even here.
SNAP_E=$(printf '%s\t%s\t%s\n' @global:odd 'first' 'second')
# Shapes that have to be handled rather than crashed on: an empty text, a line
# with no tab at all, a value that is itself empty, and a target that appears
# in one snapshot only.
SNAP_C=''
SNAP_D=$(printf 'a line with no tab\n%s\t%s\n%s\t%s\n' @global:x '' @global:y 'z\n')

for t in @global:wifi_on /sys/class/leds/lcd-backlight/brightness \
         @secure:doze_always_on %ro.some.prop @global:bluetooth_on \
         @global:x @global:y @global:odd 'not-a-target' ''; do
  for s in "$SNAP_A" "$SNAP_B" "$SNAP_C" "$SNAP_D" "$SNAP_E"; do
    a=$(snap_get "$s" "$t"); b=$(ref_snap_get "$s" "$t")
    if [ "$a" = "$b" ]; then ok; else bad "snap_get [$t]: fast [$a] ref [$b]"; fi
  done
done

for pair in "A B" "A C" "C A" "D A" "C C" "A A" "B D" "E A" "A E"; do
  eval "x=\$SNAP_$(echo "$pair" | cut -d' ' -f1)"
  eval "y=\$SNAP_$(echo "$pair" | cut -d' ' -f2)"
  a=$(snap_targets "$x" "$y"); b=$(ref_snap_targets "$x" "$y")
  if [ "$a" = "$b" ]; then ok; else bad "snap_targets ($pair): fast [$a] ref [$b]"; fi
done

# ------------------------------------------------------------------ cfg
# cfg() stopped shelling out to sed|tail and answers from a copy of the file
# taken on first use. Two properties have to hold or every knob default in the
# module is wrong: it must return what the old implementation returned for the
# same file, and a write must be visible after cfg_invalidate.
ref_cfg() { # the implementation this replaced
  _v=$(sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | tail -1)
  [ -n "$_v" ] && { printf '%s' "$_v"; return; }
  printf '%s' "$2"
}

printf '\033[1;36m== cfg answers exactly what the sed|tail it replaced answered\033[0m\n'

CONFIG="$SPSM_DIR/config"
cat > "$CONFIG" <<'CFGEOF'
knob.deep_doze=1
knob.wifi_off=0
timeout_ms=15000
knob.deep_doze=0
empty_value=
spaces=a b c
equals_in_value=a=b=c
# a comment line
knob.trailing=1
CFGEOF
# A key that is set twice must answer with the LAST one (tail -1), a key that is
# absent with the default, and a key whose value is empty with the default -
# which is what `[ -n "$_v" ]` made it do.
cfg_invalidate
for k in knob.deep_doze knob.wifi_off timeout_ms empty_value spaces \
         equals_in_value knob.trailing knob.missing '#' ''; do
  a=$(cfg "$k" DEFAULT); b=$(ref_cfg "$k" DEFAULT)
  if [ "$a" = "$b" ]; then ok; else bad "cfg [$k]: fast [$a] ref [$b]"; fi
done

# No config file at all: every key is its default.
CONFIG="$SPSM_DIR/does-not-exist"
cfg_invalidate
a=$(cfg knob.deep_doze D); b=$(ref_cfg knob.deep_doze D)
if [ "$a" = "$b" ] && [ "$a" = D ]; then ok; else bad "cfg with no file: [$a] vs [$b]"; fi

# A write during a run must be visible. Note WHERE the cache lives: almost every
# caller writes `$(cfg ...)`, which is a subshell, so the copy is taken and
# thrown away inside that subshell and a later call re-reads the file anyway.
# That is why this change is safe by construction - it removes the sed and the
# tail from each lookup without making any value outlive the process that read
# it. The two assertions below pin both halves: a fresh read sees a write, and
# an in-shell read sees it after cfg_invalidate.
CONFIG="$SPSM_DIR/config"
cfg_invalidate
[ "$(cfg knob.wifi_off X)" = 0 ] && ok || bad "cfg pre-write"
echo 'knob.wifi_off=1' >> "$CONFIG"
if [ "$(cfg knob.wifi_off X)" = 1 ]; then ok; else bad "a \$(cfg) after a write must see it"; fi
# In THIS shell the copy is still the old one until it is dropped, and dropping
# it is what do_set does.
cfg_load
echo 'knob.deep_doze=7' >> "$CONFIG"
# Tested through cfg() in THIS shell (no $( ), which would be a fresh subshell
# with a fresh copy): the cached answer must still be the pre-write one.
_seen=$(cfg knob.deep_doze X; printf '')
case "$_CFG_CACHE" in
  *'knob.deep_doze=7'*) bad "the cache should predate the write" ;;
  *) ok ;;
esac
cfg_invalidate
cfg_load
case "$_CFG_CACHE" in
  *'knob.deep_doze=7'*) ok ;;
  *) bad "cfg_invalidate did not pick the write up" ;;
esac

printf '\n\033[1;36m== %s\033[0m\n' "log writes the same line it always did, whichever shell is running it"

# The timestamp is produced by a printf builtin where the shell has one (mksh on
# Android, bash) and by forking `date` where it does not (dash). Those two paths
# must be indistinguishable in the log, or a support log stops being comparable
# with an older one.
_lt="${TMPDIR:-/tmp}/spsm-codec-log"; rm -rf "$_lt"; mkdir -p "$_lt/state" "$_lt/journal/orig"
( export SPSM_DIR="$_lt"
  . "$REPO/module/scripts/lib.sh" 2>/dev/null
  log "a routine line"
  log "WARN something went wrong" ) >/dev/null 2>&1

# 2026-09-21 20:54:09 a routine line
_first=$(head -1 "$_lt/spsm.log" 2>/dev/null)
case "$_first" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\ a\ routine\ line) _rc=0 ;;
  *) _rc=1 ;;
esac
[ "$_rc" = 0 ] && ok || bad "the stamp is not YYYY-MM-DD HH:MM:SS: [$_first]"
[ "$(wc -l < "$_lt/spsm.log" 2>/dev/null)" = 2 ] && ok || bad "not every line reached the log"

printf '\n\033[1;36m== %s\033[0m\n' "the radio record survives three radios reverting at once"
# wifi, bluetooth and nfc are all session knobs, so they revert together in the
# same bounded parallel fan - three processes doing a read-modify-write on one
# small file. radio_forget used a SHARED temp path, so they clobbered each
# other and the file could come back empty: a radio's remembered state vanished
# before its own restore had read it, and the radio was never switched back on.
#
# It showed up as an intermittent "the device still comes back byte for byte"
# failure, on whichever radio lost. Reproduced directly, the old
# read-modify-write lost an update in 40 of 40 trials; this pins it.
#
# knobs.sh is sourced here rather than at the top so the codec comparisons
# above keep running against lib.sh alone.
# shellcheck source=/dev/null
. "$REPO/module/scripts/knobs.sh" 2>/dev/null
ok_if() { [ "$1" = 0 ] && ok || bad "$2"; }
_rs="$SPSM_DIR/radio_race.tsv"
_lost=0
_i=0
while [ "$_i" -lt 15 ]; do
  printf 'wifi\ttrue\nbt\ttrue\nnfc\ttrue\n' > "$_rs"
  for _r in wifi bt nfc; do
    ( RADIO_STATE="$_rs" radio_forget "$_r" ) &
  done
  wait
  # All three forgot, so nothing may be left. A row still present means one
  # rewrite overwrote another's result.
  [ -s "$_rs" ] && _lost=$((_lost + 1))
  _i=$((_i + 1))
done
[ "$_lost" = 0 ] && ok || bad "radio_forget lost an update in $_lost of 15 concurrent trials"
rm -f "$_rs" "$_rs".* 2>/dev/null

printf '\n\033[1;36m== %s\033[0m\n' "the protected-package list is built once per run, not three times"
# protected_packages costs eight binder round trips (three role lookups, two
# settings reads, the home holder, the HOME role, query-activities) and three
# callers rebuild it inside one activation. It is cached per engine run.
#
# The cache MUST be a file: every caller invokes this inside $(...), which runs
# in a forked subshell, so a shell variable assigned there dies with it. That
# is the bug this test would have caught.
SPSM_RUN_ID="codec-test-$$"
export SPSM_RUN_ID
rm -f "${TMPDIR:-/tmp}/.spsm-protected.$$" 2>/dev/null
_a=$(_protected_packages_build)
_b=$(protected_packages)
_c=$(protected_packages)
[ "$_a" = "$_b" ]
ok_if $? "the cached answer equals a fresh build"
[ "$_b" = "$_c" ]
ok_if $? "and repeated calls stay identical"
# The cache must actually be warm after the first call - otherwise it is doing
# the work three times and merely agreeing with itself.
[ -s "${TMPDIR:-/tmp}/.spsm-protected.$$" ]
ok_if $? "the cache survives the subshell each caller runs it in"
# A build that yields nothing must never be published: a cached empty list
# means "nothing is protected", and the dialer and launcher get suspended.
printf '#%s\n' "$SPSM_RUN_ID" > "${TMPDIR:-/tmp}/.spsm-protected.$$"
_d=$(protected_packages)
[ -n "$_d" ]
ok_if $? "a stamp-only cache file is rebuilt rather than read as empty"
# A file left by an earlier run with the same pid must not be trusted.
printf '#stale-other-run\nbogus.package\n' > "${TMPDIR:-/tmp}/.spsm-protected.$$"
_e=$(protected_packages)
case "$_e" in *bogus.package*) false ;; *) true ;; esac
ok_if $? "and a cache from a different run is not reused"
# Six parallel builders, the way screen-on reverts its deep knobs: `( ... ) &`
# six at a time. They all share $$, which is what lets them share the cache -
# but it also means a single shared temp name. The first version used
# "$cache.tmp" for all of them: they truncated each other's file and five of
# six `mv`s failed on a temp another had already renamed away. Measured 6/6
# misses in a six-way race, and the cache that was meant to SAVE eight binder
# calls per caller instead added forty-five to screen-on.
rm -f "${TMPDIR:-/tmp}/.spsm-protected.$$" 2>/dev/null
_perr=$( { for _n in 1 2 3 4 5 6; do ( protected_packages >/dev/null ) & done; wait; } 2>&1 )
[ -z "$_perr" ]
ok_if $? "six parallel builders produce no errors (got: $_perr)"
# Whoever won, the published cache must be a complete, usable list - not a
# half-written file from a builder that was truncated mid-write.
_pw=$(protected_packages)
case "$_pw" in *com.android.dialer*) true ;; *) false ;; esac
ok_if $? "and the surviving cache is a complete list"
rm -f "${TMPDIR:-/tmp}"/.spsm-protected.* 2>/dev/null

printf '\n  %d checks, %d failed\n\n' "$((PASS + FAIL))" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
