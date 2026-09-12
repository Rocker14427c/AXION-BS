#!/bin/sh
# Axion SPSM v3 test harness.
#
# Runs the REAL engine scripts against a fake device tree with stubbed Android
# commands, and asserts the thing that matters most: that turning the mode on
# and off again leaves the device byte-for-byte as it was found.
#
#   ./tests/run.sh
#
# No phone, no root and no SDK required.

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPTS="$REPO/module/scripts"
WORK=${TMPDIR:-/tmp}/spsm-test
PASS=0
FAIL=0

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
check() { # check description condition-result
  if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi
}

# --------------------------------------------------------------- fake device
make_tree() {
  # A daemon from an earlier case is still holding a reference to the old work
  # directory. Left alive it would wake up and act on the new one mid-test.
  stop_daemons
  ROOT="$WORK/dev"
  rm -rf "$ROOT" "$WORK/spsm"
  mkdir -p "$WORK/spsm/scripts"
  cp "$SCRIPTS"/*.sh "$WORK/spsm/scripts/"

  # CPU clusters: the values here are the ones v2 got wrong, so the test would
  # catch a regression that pins the little cluster.
  for n in 0 1 2 3 4 5 6 7; do
    mkdir -p "$ROOT/sys/devices/system/cpu/cpu$n"
    echo 1 > "$ROOT/sys/devices/system/cpu/cpu$n/online"
  done
  for p in 0 6; do
    d="$ROOT/sys/devices/system/cpu/cpufreq/policy$p"
    mkdir -p "$d"
    echo schedutil > "$d/scaling_governor"
    if [ "$p" = 0 ]; then
      echo 500000  > "$d/scaling_min_freq"; echo 1800000 > "$d/scaling_max_freq"
      echo 1800000 > "$d/cpuinfo_max_freq"
    else
      echo 850000  > "$d/scaling_min_freq"; echo 2000000 > "$d/scaling_max_freq"
      echo 2000000 > "$d/cpuinfo_max_freq"
    fi
  done
  mkdir -p "$ROOT/proc/cpufreq";  echo 0 > "$ROOT/proc/cpufreq/cpufreq_power_mode"
  mkdir -p "$ROOT/proc/gpufreq";  echo 0 > "$ROOT/proc/gpufreq/gpufreq_opp_freq"
  mkdir -p "$ROOT/sys/module/ged/parameters"
  for f in enable_cpu_boost enable_gpu_boost ged_boost_enable is_GED_KPI_enabled gpu_dvfs_enable gpu_cust_upbound_freq gpu_bottom_freq; do
    echo 1 > "$ROOT/sys/module/ged/parameters/$f"
  done
  mkdir -p "$ROOT/sys/class/leds/lcd-backlight"
  echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
  # The range the node actually has on this device: 0 off, 1..4095 on. A test
  # that assumed 0..255 would pass here and be wrong on the phone.
  echo 4095 > "$ROOT/sys/class/leds/lcd-backlight/max_brightness"
  mkdir -p "$ROOT/proc/touchpanel"
  echo 1 > "$ROOT/proc/touchpanel/double_tap_enable"
  echo 1 > "$ROOT/proc/touchpanel/gesture_enable"
}

# ------------------------------------------------------------------- stubs
make_stubs() {
  BIN="$WORK/bin"
  rm -rf "$BIN"; mkdir -p "$BIN"
  for c in settings getprop setprop resetprop svc pm am cmd dumpsys; do
    printf '#!/bin/sh\nexec sh "%s/stub.sh" "$@"\n' "$REPO/tests" > "$BIN/$c"
    chmod +x "$BIN/$c"
  done
  # The dispatcher needs to know which name it was called as, which $0 gives
  # us only if we do not exec through another shell, so pass it explicitly.
  for c in settings getprop setprop resetprop svc pm am cmd dumpsys; do
    cat > "$BIN/$c" <<EOF
#!/bin/sh
CMD_OVERRIDE=$c
export CMD_OVERRIDE
exec sh "$REPO/tests/stub.sh" "\$@"
EOF
    chmod +x "$BIN/$c"
  done
  # An injectable clock. The engine's drain report is a rate per hour; with a
  # real clock the test would have to sleep for an hour to assert on it.
  cat > "$BIN/date" <<EOF
#!/bin/sh
# Test-only: shift the clock so elapsed time can be asserted exactly.
_off=\$(cat "$WORK/clock_offset" 2>/dev/null || echo 0)
if [ "\$1" = "+%s" ]; then
  echo \$(( \$(command -p date +%s) + _off ))
else
  command -p date "\$@"
fi
EOF
  chmod +x "$BIN/date"
  echo 0 > "$WORK/clock_offset"

  # stub.sh reads the command name from $CMD_OVERRIDE when present
  sed -i 's|^CMD=$(basename "$0")|CMD=${CMD_OVERRIDE:-$(basename "$0")}|' "$REPO/tests/stub.sh"
}

seed_stub_state() {
  S="$WORK/stub"
  rm -rf "$S"; mkdir -p "$S/props" "$S/settings" "$S/bucket" "$S/appop" "$S/pkg"
  : > "$S/calls"
  printf 'com.whatsapp\ncom.spotify.music\ncom.example.game\n' > "$S/pkgs3"
  echo 10 > "$S/bucket/com.whatsapp"
  echo 20 > "$S/bucket/com.spotify.music"
  echo 30 > "$S/bucket/com.example.game"
  echo "RUN_ANY_IN_BACKGROUND: allow" > "$S/appop/com.whatsapp"
  echo "RUN_ANY_IN_BACKGROUND: allow" > "$S/appop/com.spotify.music"
  echo "RUN_ANY_IN_BACKGROUND: allow" > "$S/appop/com.example.game"
  cat > "$S/deviceidle_whitelist" <<'EOF'
system-excidle,com.android.providers.calendar,10134
system,com.android.messaging,10183
user,com.whatsapp,10199
EOF
  printf 'secure.double_tap_to_wake' >/dev/null
  printf '%s' 1 > "$S/settings/secure.double_tap_to_wake"
  printf '%s' 1 > "$S/settings/system.double_tap_to_wake"
  printf '%s' 1 > "$S/settings/secure.tap_to_wake"
  printf '%s' 1 > "$S/settings/secure.doze_always_on"
  printf '%s' 1 > "$S/settings/system.screen_brightness_mode"
  printf '%s' 30000 > "$S/settings/system.screen_off_timeout"
  printf '%s' 1 > "$S/settings/global.animator_duration_scale"
  printf '%s' 1 > "$S/settings/global.transition_animation_scale"
  printf '%s' 1 > "$S/settings/global.window_animation_scale"
  printf '%s' 1 > "$S/settings/system.haptic_feedback_enabled"
  printf '%s' 1 > "$S/settings/system.accelerometer_rotation"
  printf '%s' 1 > "$S/settings/global.wifi_on"
  printf '%s' 1 > "$S/settings/global.wifi_scan_always_enabled"
  printf '%s' 1 > "$S/settings/global.bluetooth_on"
  printf '%s' 1 > "$S/settings/global.nfc_on"
  printf '%s' 1 > "$S/settings/global.ble_scan_always_enabled"
  printf '%s' 1 > "$S/settings/global.network_recommendations_enabled"
  printf '%s' 1 > "$S/settings/global:auto_sync" 2>/dev/null || printf '%s' 1 > "$S/settings/global.auto_sync"
  printf '%s' 1 > "$S/settings/global.low_power"
  printf '%s' 1 > "$S/settings/secure.location_mode"
  echo com.android.launcher3 > "$S/home_role"
  echo com.android.launcher3/.Launcher > "$S/home_activity"
  # The radio state the settings above describe, so a correct revert has to
  # put the interfaces back on rather than merely not turning them off.
  echo enable > "$S/svc.wifi"
  echo enable > "$S/svc.bluetooth"
  echo enable > "$S/svc.nfc"
  echo on > "$S/screen"
}

run_engine() { # run_engine args...
  SPSM_ROOT="$ROOT" \
  SPSM_DIR="$WORK/spsm" \
  SPSM_STUB="$WORK/stub" \
  PATH="$BIN:$PATH" \
  sh "$WORK/spsm/scripts/engine.sh" "$@"
}

run_shell() { # run_shell script args...
  SPSM_ROOT="$ROOT" \
  SPSM_DIR="$WORK/spsm" \
  SPSM_STUB="$WORK/stub" \
  PATH="$BIN:$PATH" \
  sh "$@"
}

# Dump of everything the engine could possibly have touched. This is the whole
# point of the suite: on/off must be a no-op on this dump.
journal_entries_states() {
  _n=0
  for _f in "$WORK/spsm/journal"/*.state; do
    [ -f "$_f" ] || continue
    case "$(cat "$_f" 2>/dev/null)" in
      applied|restored-drift) _n=$((_n + 1)) ;;
    esac
  done
  echo "$_n"
}

stop_daemons() {
  _p=$(cat "$WORK/spsm/daemon.pid" 2>/dev/null)
  [ -n "$_p" ] && kill "$_p" 2>/dev/null
  for _d in /proc/[0-9]*; do
    case "$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)" in
      *"$WORK/spsm/scripts/daemon.sh"*) kill "$(basename "$_d")" 2>/dev/null ;;
    esac
  done
  return 0
}

dump_state() {
  _out=$1
  : > "$_out"
  find "$ROOT" -type f | sort | while read -r f; do
    printf '%s=' "${f#$ROOT}"; cat "$f"; printf '\n'
  done >> "$_out"
  find "$WORK/stub" -type f -not -name calls | sort | while read -r f; do
    printf '%s=' "${f#$WORK/stub}"; cat "$f"; printf '\n'
  done >> "$_out"
}
fingerprint() { dump_state "$WORK/.fp" && sha256sum "$WORK/.fp" | awk '{print $1}'; }
show_diff() { # show_diff fileA fileB
  printf '\n    --- state differences ---\n'
  diff -u "$1" "$2" | sed 's/^/    /' | head -50
  printf '\n'
}

# Screen state on the fake device: the backlight node is what screen_state()
# reads once no marker exists, exactly like the real thing.
screen_off() { echo 0   > "$ROOT/sys/class/leds/lcd-backlight/brightness"; echo off > "$WORK/stub/screen"; }
screen_on()  { echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"; echo on  > "$WORK/stub/screen"; }

enable_knobs() { # enable_knobs id...
  for k in "$@"; do echo "knob.$k=1" >> "$WORK/spsm/config"; done
}

# ==========================================================================
say "1. on -> off returns the device to exactly its previous state"
make_tree; make_stubs; seed_stub_state
dump_state "$WORK/before"
run_engine activate >"$WORK/out.activate" 2>&1
check "activate exits 0" $?
dump_state "$WORK/mid"
[ "$(sha256sum "$WORK/before" | awk '{print $1}')" != "$(sha256sum "$WORK/mid" | awk '{print $1}')" ]
check "activate actually changed something" $?
run_engine deactivate >"$WORK/out.deactivate" 2>&1
check "deactivate exits 0" $?
dump_state "$WORK/after"
if diff -q "$WORK/before" "$WORK/after" >/dev/null; then
  ok "state after off is byte-identical to before on"
else
  bad "state after off is byte-identical to before on"
  show_diff "$WORK/before" "$WORK/after"
fi

say "2. every enabled knob reports itself as restored"
run_engine verify >"$WORK/out.verify" 2>&1
grep -q 'drift=0' "$WORK/out.verify"; check "no drift after revert" $?

say "3. screen off -> on is also a round trip"
dump_state "$WORK/seg_before"
run_engine activate >/dev/null 2>&1
dump_state "$WORK/seg_active"
screen_off
run_engine screen-off >"$WORK/out.off" 2>&1
dump_state "$WORK/seg_off"
[ "$(sha256sum "$WORK/seg_active" | awk '{print $1}')" != "$(sha256sum "$WORK/seg_off" | awk '{print $1}')" ]
check "screen-off changed something" $?
screen_on
run_engine screen-on >"$WORK/out.on" 2>&1
check "screen-on exits 0" $?
run_engine deactivate >/dev/null 2>&1
dump_state "$WORK/seg_after"
if diff -q "$WORK/seg_before" "$WORK/seg_after" >/dev/null; then
  ok "screen off/on + exit leaves no trace"
else
  bad "screen off/on + exit leaves no trace"
  show_diff "$WORK/seg_before" "$WORK/seg_after"
fi

say "4. deep knobs (CPU cap, app buckets) only apply while asleep"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap app_restrict
run_engine activate >/dev/null 2>&1
MAX0=$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")
[ "$MAX0" = "1800000" ]; check "screen on: CPU ceiling untouched" $?
screen_off
run_engine screen-off >/dev/null 2>&1
MAX1=$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")
[ "$MAX1" = "1100000" ]; check "screen off: CPU ceiling capped" $?
B=$(cat "$WORK/stub/bucket/com.spotify.music")
[ "$B" = "restricted" ]; check "screen off: unlisted app moved to restricted bucket" $?
W=$(cat "$WORK/stub/bucket/com.whatsapp")
[ "$W" = "10" ]; check "whitelisted app (doze-exempt) left alone" $?
screen_on
run_engine screen-on >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1800000" ]; check "wake: CPU ceiling restored" $?
[ "$(cat "$WORK/stub/bucket/com.spotify.music")" = "20" ]; check "wake: bucket restored to 20" $?
[ "$(cat "$WORK/stub/appop/com.spotify.music")" = "RUN_ANY_IN_BACKGROUND: allow" ]; check "wake: app-op restored" $?

say "5. a value changed by someone else is never clobbered"
make_tree; make_stubs; seed_stub_state
run_engine activate >/dev/null 2>&1
# Simulate the user (or the ROM) changing something we manage.
echo 1 > "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
echo 7 > "$ROOT/proc/touchpanel/double_tap_enable"
run_engine deactivate >"$WORK/out.keep" 2>&1
check "deactivate still exits 0" $?
[ "$(cat "$ROOT/proc/touchpanel/double_tap_enable")" = "7" ]; check "newer user value is preserved" $?
grep -q 'keep dt2w_off' "$WORK/spsm/spsm.log"; check "left-alone knob is logged" $?

say "6. disabled knobs are never touched"
make_tree; make_stubs; seed_stub_state
echo "knob.cpu_offline_big=0" >> "$WORK/spsm/config"
run_engine activate >/dev/null 2>&1
echo off > "$WORK/stub/screen"
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "1" ]; check "opt-out knob stays off (big cores online)" $?
run_engine deactivate >/dev/null 2>&1
run_engine verify >"$WORK/out.v6" 2>&1
grep -q 'drift=0' "$WORK/out.v6"; check "still no drift" $?

say "7. cpu_offline_big works and is reversible when opted in"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_offline_big
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "0" ]; check "screen off: big core powered down" $?
screen_on
run_engine screen-on >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "1" ]; check "wake: big core back online" $?

say "8. missing nodes are skipped, not invented"
make_tree; make_stubs; seed_stub_state
rm -f "$ROOT/proc/touchpanel/gesture_enable"
run_engine activate >/dev/null 2>&1
check "activate survives a missing node" $?
[ ! -e "$ROOT/proc/touchpanel/gesture_enable" ]; check "missing node was not created" $?
run_engine deactivate >/dev/null 2>&1
[ ! -e "$ROOT/proc/touchpanel/gesture_enable" ]; check "still absent after revert" $?

say "9. a crash/reboot cannot leave the phone crippled"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_offline_big
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "0" ]; check "big core is off before the crash" $?
# Simulate a power loss with SPSM on: journal present, marker present.
run_shell "$WORK/spsm/scripts/lib.sh" >/dev/null 2>&1
# Exactly what post-fs-data.sh does on the next boot.
SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" PATH="$BIN:$PATH" sh "$WORK/spsm/../spsm/scripts/engine.sh" >/dev/null 2>&1
SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" PATH="$BIN:$PATH" sh -c '
  . "$1/lib.sh"
  safety_force
' _ "$WORK/spsm/scripts" >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "1" ]; check "boot safety net brings the cores back" $?

say "10. engine is idempotent and serialised"
make_tree; make_stubs; seed_stub_state
run_engine activate >/dev/null 2>&1
run_engine activate >/dev/null 2>&1
check "double activate is safe" $?
run_engine deactivate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
check "double deactivate is safe" $?
run_engine verify >"$WORK/out.v10" 2>&1
grep -q 'drift=0' "$WORK/out.v10"; check "no drift after repeated toggles" $?
[ ! -d "$WORK/spsm/lock" ]; check "lock released" $?

say "11. knob list is generated for the APK"
run_engine dump-knobs >/dev/null 2>&1
KL="$WORK/spsm/knobs.list"
[ -s "$KL" ]; check "knobs.list written" $?
N=$(wc -l < "$KL")
[ "$N" -ge 15 ]; check "knobs.list has all knobs ($N entries)" $?

# The app parses each line with split("\\|", 7) and reads 0=id 1=category
# 2=label 3=description 4=default 5=scope 6=tags, so a stray "|" anywhere in a
# label or description would silently shift the fields.
BAD=$(awk -F'|' 'NF!=7 {n++} END {print n+0}' "$KL")
[ "$BAD" = "0" ]; check "every line has exactly 7 fields" $?
BAD=$(awk -F'|' '$1==""||$2==""||$3==""||$4==""||$5==""||$6=="" {n++} END {print n+0}' "$KL")
[ "$BAD" = "0" ]; check "no line has an empty metadata field" $?
BAD=$(awk -F'|' '$5!="0"&&$5!="1" {n++} END {print n+0}' "$KL")
[ "$BAD" = "0" ]; check "default is always 0 or 1" $?
BAD=$(awk -F'|' '$6!="session"&&$6!="deep" {n++} END {print n+0}' "$KL")
[ "$BAD" = "0" ]; check "scope is always session or deep" $?

# Duplicate ids would render two switches that fight each other.
DUP=$(awk -F'|' '{c[$1]++} END {n=0; for (k in c) if (c[k]>1) n++; print n}' "$KL")
[ "$DUP" = "0" ]; check "no duplicate knob ids" $?

# Anything the app shows as a switch must be settable through the engine, or
# tapping it fails on the phone. This is the app/script contract.
BAD=0
while IFS='|' read -r id cat label desc def scope tags; do
  out=$(run_engine set "$id" "$def" 2>&1)
  case "$out" in
    *"unknown knob"*) BAD=$((BAD+1)); echo "    (unknown: $id)" ;;
  esac
done < "$KL"
[ "$BAD" = "0" ]; check "every listed knob is settable via engine.sh" $?
run_engine deactivate >/dev/null 2>&1

say "12. the user can opt out of a change mid-session"
make_tree; make_stubs; seed_stub_state
enable_knobs home_swap brightness_cap
echo 1 > "$WORK/stub/screen"; screen_on
ORIG_BL=$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")
run_engine activate >"$WORK/out.act12" 2>&1
CAP_BL=$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")
[ "$CAP_BL" != "$ORIG_BL" ]; check "brightness was capped while on ($ORIG_BL -> $CAP_BL)" $?

# Turning a knob off while the mode runs must put that one thing back now,
# without disturbing the rest of the session.
run_engine set brightness_cap 0 >"$WORK/out.set12" 2>&1
NOW_BL=$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")
[ "$NOW_BL" = "$ORIG_BL" ]; check "opted-out knob reverted immediately ($NOW_BL)" $?
grep -q "brightness_cap=0" "$WORK/spsm/config"; check "opt-out persisted to config" $?
[ -f "$WORK/spsm/journal/home_swap.applied" ]; check "other knobs stayed applied" $?

# Bad input must be refused rather than written into the config.
run_engine set nope 1 >"$WORK/out.bad12" 2>&1
[ $? = 2 ]; check "unknown knob refused with exit 2" $?
grep -q "unknown knob" "$WORK/out.bad12"; check "unknown knob reported" $?
run_engine set cpu_cap 7 >"$WORK/out.bad12b" 2>&1
[ $? = 2 ]; check "bad value refused with exit 2" $?
grep -q "bad value" "$WORK/out.bad12b"; check "bad value reported" $?
run_engine set brightness_cap 0 >/dev/null 2>&1

# A deep knob enabled while the screen is already off applies straight away
# instead of waiting for the next screen-off cycle.
screen_off
run_engine screen-off >/dev/null 2>&1
BEFORE_HITS=$(grep -c "set-standby-bucket.*restricted" "$WORK/stub/calls" 2>/dev/null || true)
[ -n "$BEFORE_HITS" ] || BEFORE_HITS=0
run_engine set app_restrict 1 >"$WORK/out.d12" 2>&1
AFTER_HITS=$(grep -c "set-standby-bucket.*restricted" "$WORK/stub/calls" 2>/dev/null || true)
[ -n "$AFTER_HITS" ] || AFTER_HITS=0
[ "$AFTER_HITS" -gt "$BEFORE_HITS" ]
check "deep knob enabled asleep applies immediately ($BEFORE_HITS -> $AFTER_HITS)" $?

# ...and the whole session still reverts byte-for-byte.
screen_on
run_engine screen-on >/dev/null 2>&1
run_engine deactivate >"$WORK/out.dea12" 2>&1
run_engine verify >"$WORK/out.ver12" 2>&1
grep -q 'drift=0' "$WORK/out.ver12"; check "no drift after opt-out session" $?

say "13. a normal boot leaves the phone alone"
make_tree; make_stubs; seed_stub_state
dump_state "$WORK/boot_before"
# The journal directory exists on every install; that alone is not a reason to
# touch anything. This is a boot with nothing left over.
run_shell "$REPO/module/post-fs-data.sh" >"$WORK/out.pfd13" 2>&1
check "post-fs-data exits 0" $?
dump_state "$WORK/boot_after"
if diff -q "$WORK/boot_before" "$WORK/boot_after" >/dev/null; then
  ok "clean boot changed nothing"
else
  bad "clean boot changed nothing"
  show_diff "$WORK/boot_before" "$WORK/boot_after"
fi
[ ! -f "$WORK/spsm/state/needs_restore" ]; check "no restore marker on a clean boot" $?

# A journal left behind by a session that DID finish is just paper: every knob
# in it is marked restored. Booting must not force anything on account of it.
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap
screen_off
run_engine activate >/dev/null 2>&1
run_engine screen-off >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ "$(journal_entries_states)" = "0" ]
check "the finished session left no knob marked applied" $?
# The user now sets the phone up their own way and reboots.
screen_on
echo 0 > "$ROOT/sys/devices/system/cpu/cpu6/online"
echo powersave > "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
echo 25 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
dump_state "$WORK/paper_before"
run_shell "$REPO/module/post-fs-data.sh" >"$WORK/out.pfd13b" 2>&1
dump_state "$WORK/paper_after"
if diff -q "$WORK/paper_before" "$WORK/paper_after" >/dev/null; then
  ok "a finished journal does not force anything on the next boot"
else
  bad "a finished journal does not force anything on the next boot"
  show_diff "$WORK/paper_before" "$WORK/paper_after"
fi

say "14. a boot after a crash does put the phone back"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_offline_big cpu_cap
echo 6 > "$ROOT/sys/devices/system/cpu/cpu6/online"; echo 0 > "$ROOT/sys/devices/system/cpu/cpu6/online"
run_engine activate >/dev/null 2>&1
# Simulate the power being cut: the journal survives, the revert never ran.
run_shell "$REPO/module/post-fs-data.sh" >"$WORK/out.pfd14" 2>&1
check "post-fs-data exits 0" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "1" ]
check "offline core was brought back before the system came up" $?
grep -q schedutil "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
check "governor is sane" $?
[ -f "$WORK/spsm/state/needs_restore" ]; check "restore marker left for service.sh" $?

say "15. a stale daemon pid is never trusted or killed"
make_tree; make_stubs; seed_stub_state
sleep 60 &
STRANGER=$!
echo "$STRANGER" > "$WORK/spsm/daemon.pid"
run_engine start-daemon >"$WORK/out.d15" 2>&1
kill -0 "$STRANGER" 2>/dev/null; check "unrelated process still alive" $?
grep -q "daemon start" "$WORK/spsm/spsm.log"; check "a real daemon was started anyway" $?
run_engine stop-daemon >"$WORK/out.d15b" 2>&1
kill -0 "$STRANGER" 2>/dev/null; check "stop-daemon did not kill the stranger" $?

say "16. the daemon reacts to a screen change without waiting out its poll"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/state"
echo "knob.cpu_cap=1" >> "$WORK/spsm/config"
echo "knob.deep_doze=1" >> "$WORK/spsm/config"
screen_on
echo 1 > "$WORK/spsm/state/active"
# Start the daemon exactly the way the engine does.
SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" SPSM_STUB="$WORK/stub" PATH="$BIN:$PATH" \
  sh "$WORK/spsm/scripts/daemon.sh" >>"$WORK/spsm/spsm.log" 2>&1 &
DPID=$!
sleep 2
# Power button: the APK writes the marker and pokes the daemon.
screen_off
echo off > "$WORK/spsm/state/screen"
kill -USR1 "$DPID" 2>/dev/null
# Two separate facts: how fast the daemon REACTED (what the poke buys us, must
# beat the 8 second poll) and that the work then finished (which takes as long
# as it takes, and is not what this case is about).
i=0
while [ $i -lt 16 ] && ! grep -q "screen on -> off" "$WORK/spsm/spsm.log"; do sleep 0.25; i=$((i + 1)); done
grep -q "screen on -> off" "$WORK/spsm/spsm.log"
check "the poke started the screen-off work (${i}x250ms, a poll takes 8s)" $?
i=0
while [ $i -lt 80 ] && [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" != "1100000" ]; do sleep 0.25; i=$((i + 1)); done
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1100000" ]
check "and the cap landed" $?
[ -f "$WORK/spsm/journal/order" ]; check "the knobs were journalled as they applied" $?
# ...and waking up reverses it just as promptly.
screen_on
echo on > "$WORK/spsm/state/screen"
kill -USR1 "$DPID" 2>/dev/null
i=0
while [ $i -lt 16 ] && ! grep -qc "screen off -> on" "$WORK/spsm/spsm.log"; do sleep 0.25; i=$((i + 1)); done
[ "$(grep -c "screen off -> on" "$WORK/spsm/spsm.log")" -ge 1 ]
check "the poke started the wake-up work in ${i}x250ms" $?
i=0
while [ $i -lt 80 ] && [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" != "1800000" ]; do sleep 0.25; i=$((i + 1)); done
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1800000" ]
check "the cap came off (after ${i} more polls)" $?
rm -f "$WORK/spsm/state/active"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null

say "17. the shipped defaults are a valid, fully reversible session"
make_tree; make_stubs; seed_stub_state
# No config file at all: this is what the phone does the first time it is used.
dump_state "$WORK/def_before"
run_engine activate >"$WORK/out.act17" 2>&1
check "activate with no config exits 0" $?
dump_state "$WORK/def_mid"
[ "$(sha256sum "$WORK/def_before" | awk '{print $1}')" != "$(sha256sum "$WORK/def_mid" | awk '{print $1}')" ]
check "the defaults actually change the device" $?
# The deep knobs are the ones that only exist while the phone is asleep, and
# they are where the overnight saving comes from.
screen_off
run_engine screen-off >"$WORK/out.so17" 2>&1
grep -q "snap deep_doze" "$WORK/spsm/spsm.log"
check "deep doze is on by default once asleep" $?
grep -q "snap app_restrict" "$WORK/spsm/spsm.log"
check "background restriction is on by default once asleep" $?
grep -q "snap cpu_cap" "$WORK/spsm/spsm.log"
check "cpu cap is on by default once asleep" $?
grep -q "snap freeze_google" "$WORK/spsm/spsm.log" && bad "freeze_google must stay off by default" || ok "freeze_google stays off by default"
screen_on
run_engine screen-on >"$WORK/out.son17" 2>&1
run_engine deactivate >"$WORK/out.dea17" 2>&1
dump_state "$WORK/def_after"
if diff -q "$WORK/def_before" "$WORK/def_after" >/dev/null; then
  ok "the defaults revert byte-for-byte"
else
  bad "the defaults revert byte-for-byte"
  show_diff "$WORK/def_before" "$WORK/def_after"
fi
run_engine verify >"$WORK/out.ver17" 2>&1
grep -q 'drift=0' "$WORK/out.ver17"
DRIFT_OK=$?
check "no drift from a default session" $DRIFT_OK
[ "$DRIFT_OK" = "0" ] || {
  echo "    --- engine drift log ---"
  grep -E "DRIFT|left|keep " "$WORK/spsm/spsm.log" | tail -8 | sed 's/^/    /'
  echo "    --- verify output: $(cat "$WORK/out.ver17") ---"
}

say "18. the mode measures its own idle drain"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/state"
enable_knobs cpu_cap
echo 100 > "$WORK/stub/battery_level"
screen_on
echo 1 > "$WORK/spsm/state/active"
SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" SPSM_STUB="$WORK/stub" PATH="$BIN:$PATH" \
  sh "$WORK/spsm/scripts/daemon.sh" >>"$WORK/spsm/spsm.log" 2>&1 &
DPID=$!
sleep 3
# The level is set BEFORE the screen change: the daemon may notice the change
# on its own poll rather than on the poke, and it must read the level that
# belongs to that transition either way.
echo 80 > "$WORK/stub/battery_level"
screen_off
kill -USR1 "$DPID" 2>/dev/null
i=0
while [ $i -lt 80 ] && [ ! -f "$WORK/spsm/state/drain_mark" ]; do sleep 0.25; i=$((i + 1)); done
[ -f "$WORK/spsm/state/drain_mark" ]
check "the level is noted when the screen goes off" $?
[ "$(awk '{print $1}' "$WORK/spsm/state/drain_mark")" = "80" ]
check "it recorded the right level" $?
# Overnight: eight hours pass and one percent is lost, so the reported rate has
# to be 0.12%/h - the number the user actually cares about.
echo 28800 > "$WORK/clock_offset"
echo 79 > "$WORK/stub/battery_level"
screen_on
kill -USR1 "$DPID" 2>/dev/null
i=0
while [ $i -lt 80 ] && [ ! -f "$WORK/spsm/drain.log" ]; do sleep 0.25; i=$((i + 1)); done
[ -s "$WORK/spsm/drain.log" ]; check "a drain report was written" $?
grep -q "80% -> 79%" "$WORK/spsm/drain.log"; check "the report has the real levels" $?
DATE_RE='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} '
grep -qE "${DATE_RE}screen off 80% -> 79% in 480 min \(0\.12%/h\)" "$WORK/spsm/drain.log"
RATE_OK=$?
[ "$RATE_OK" = "0" ] || { echo "    --- daemon transitions ---"; grep -E "screen .* ->|drain" "$WORK/spsm/spsm.log" | tail -12 | sed 's/^/    /'; }
check "and a rate per hour computed from them" $RATE_OK
[ "$RATE_OK" = "0" ] || sed 's/^/    actual: /' "$WORK/spsm/drain.log"
grep -q "^[0-9][0-9][0-9][0-9]-" "$WORK/spsm/drain.log"
check "the report is timestamped like a log" $?
[ "$(wc -l < "$WORK/spsm/drain.log")" = "1" ]
check "exactly one report per sleep" $?
echo 0 > "$WORK/clock_offset"
rm -f "$WORK/spsm/state/active"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null

say "19. an exit cannot be undone by a screen-off already in flight"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap app_restrict deep_doze
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1100000" ]
check "the cap is on while asleep" $?
run_engine deactivate >"$WORK/out.dea19" 2>&1
check "exit exits 0" $?
dump_state "$WORK/after_exit19"
# This is the daemon's screen-off arriving late, after the mode is off. It must
# find nothing to do: the phone has already been put back.
run_engine screen-off >"$WORK/out.late19" 2>&1
check "a late screen-off does not fail" $?
dump_state "$WORK/after_late19"
if diff -q "$WORK/after_exit19" "$WORK/after_late19" >/dev/null; then
  ok "the late screen-off changed nothing"
else
  bad "the late screen-off changed nothing"
  show_diff "$WORK/after_exit19" "$WORK/after_late19"
fi
[ ! -f "$WORK/spsm/state/active" ]; check "the mode is flagged off before the revert ran" $?
# A child that was already in flight when the daemon was stopped gets to finish
# and release; give it a moment rather than racing it.
i=0
while [ $i -lt 16 ] && [ -d "$WORK/spsm/lock" ]; do sleep 0.25; i=$((i + 1)); done
[ ! -d "$WORK/spsm/lock" ]
LOCK_OK=$?
check "no lock left behind" $LOCK_OK
[ "$LOCK_OK" = "0" ] || {
  echo "    lock holder pid: $(cat "$WORK/spsm/lock/pid" 2>/dev/null)"
  echo "    daemon pid file: $(cat "$WORK/spsm/daemon.pid" 2>/dev/null)"
  echo "    --- engine log tail ---"
  tail -6 "$WORK/spsm/spsm.log" | sed 's/^/    /'
}
run_engine verify >"$WORK/out.ver19" 2>&1
grep -q 'drift=0' "$WORK/out.ver19"; check "nothing drifted" $?

say "20. a dim screen the user chose is not brightened, during or after"
make_tree; make_stubs; seed_stub_state
enable_knobs brightness_cap
screen_on
echo 10 > "$ROOT/sys/class/leds/lcd-backlight/brightness"   # darker than the cap
run_engine activate >"$WORK/out.act20" 2>&1
check "activate exits 0" $?
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "10" ]
check "the cap did not brighten a darker screen (it is a cap, not a level)" $?
run_engine deactivate >"$WORK/out.dea20" 2>&1
check "deactivate exits 0" $?
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "10" ]
check "the user's own brightness survived the exit" $?
run_engine verify >"$WORK/out.ver20" 2>&1
grep -q 'drift=0' "$WORK/out.ver20"; check "no drift" $?

say "21. exiting a session that changed nothing touches nothing"
make_tree; make_stubs; seed_stub_state
run_engine dump-knobs >/dev/null 2>&1
# The user has turned every knob off. Turning the mode on now does nothing at
# all, so turning it off must not quietly "fix" any of their own choices.
while IFS='|' read -r _id _rest; do echo "knob.$_id=0" >> "$WORK/spsm/config"; done < "$WORK/spsm/knobs.list"
screen_on
echo 0 > "$ROOT/sys/devices/system/cpu/cpu6/online"          # core parked on purpose
echo powersave > "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
echo 300 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
run_engine activate >"$WORK/out.act21" 2>&1
run_engine deactivate >"$WORK/out.dea21" 2>&1
check "the round trip exits 0" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu6/online")" = "0" ]
check "the core the user parked stayed parked" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" = "powersave" ]
check "the governor the user chose stayed" $?
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "300" ]
check "the brightness the user chose stayed" $?

say "22. re-applying the idle phase keeps the original app state"
make_tree; make_stubs; seed_stub_state
enable_knobs app_restrict
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
# The mode is on and idle. It is applied again without ever being released
# first - a second tap on Turn on, or resuming after a reboot.
run_engine activate >"$WORK/out.act22" 2>&1
run_engine deactivate >"$WORK/out.dea22" 2>&1
[ "$(cat "$WORK/stub/bucket/com.spotify.music")" = "20" ]
check "spotify bucket returned to its original 20 (got $(cat "$WORK/stub/bucket/com.spotify.music"))" $?
[ "$(grep -o 'allow' "$WORK/stub/appop/com.spotify.music" | head -1)" = "allow" ]
check "spotify background permission returned to allow" $?

say "23. a setting the mode never touched is not deleted on exit"
make_tree; make_stubs; seed_stub_state
echo "v=1,night" > "$WORK/stub/settings/global.battery_saver_constants"
screen_on
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ -f "$WORK/stub/settings/global.battery_saver_constants" ]
check "the ROM's battery saver constants are still there" $?
[ "$(cat "$WORK/stub/settings/global.battery_saver_constants")" = "v=1,night" ]
check "and still hold their value" $?

say "24. exiting does not wake a package the user had disabled"
make_tree; make_stubs; seed_stub_state
enable_knobs freeze_google
echo disabled-user > "$WORK/stub/pkg/com.android.vending.enabled"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
run_engine screen-on >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/pkg/com.android.vending.enabled")" = "disabled-user" ]
check "Play Store is still disabled by the user's choice (got $(cat "$WORK/stub/pkg/com.android.vending.enabled"))" $?
[ "$(cat "$WORK/stub/pkg/com.google.android.gms.enabled" 2>/dev/null || echo default)" != "disabled-user" ]
check "Play services is still usable" $?

say "25. a value containing a tab is not mistaken for an external change"
make_tree; make_stubs; seed_stub_state
enable_knobs wifi_off
# A settings row holding a literal tab: WiFi off is applied through svc/cmd, so
# this row is snapshotted but never written by us. It must survive, and it must
# not be misreported as "changed externally" just because it contains a tab.
printf 'always	scan' > "$WORK/stub/settings/global.wifi_scan_always_enabled"
screen_on
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
run_engine verify >"$WORK/out.ver25" 2>&1
[ "$(cat "$WORK/stub/settings/global.wifi_scan_always_enabled")" = "$(printf 'always	scan')" ]
check "the tab-bearing value is unchanged" $?
grep -q 'drift=0' "$WORK/out.ver25"; check "no drift" $?
grep -q 'left-alone=0' "$WORK/out.ver25"
check "nothing was misreported as externally changed ($(cat "$WORK/out.ver25"))" $?

say "26. a value containing a literal backslash-n survives the journal"
make_tree; make_stubs; seed_stub_state
enable_knobs wifi_off
# A value that merely LOOKS like our escape syntax. If the encoder and the
# decoder are not exact inverses, this is where it shows.
printf '%s' 'line\nnext' > "$WORK/stub/settings/global.wifi_scan_always_enabled"
screen_on
run_engine activate >"$WORK/out.act26" 2>&1
run_engine deactivate >"$WORK/out.dea26" 2>&1
printf '%s' 'line\nnext' > "$WORK/want26"
cp "$WORK/stub/settings/global.wifi_scan_always_enabled" "$WORK/got26"
if cmp -s "$WORK/want26" "$WORK/got26"; then
  ok "the escaped-looking value came back byte for byte"
else
  bad "the escaped-looking value came back byte for byte"
  od -c "$WORK/want26" | head -2 | sed 's/^/    want: /'
  od -c "$WORK/got26"  | head -2 | sed 's/^/    got : /'
fi

say "26b. a value that really spans lines survives the journal"
make_tree; make_stubs; seed_stub_state
enable_knobs wifi_off
# Some Settings rows hold embedded newlines. The journal is one record per line,
# so a value like this used to be put back truncated at its first line.
printf 'line1\nline2\nline3' > "$WORK/stub/settings/global.wifi_scan_always_enabled"
screen_on
run_engine activate >"$WORK/out.act26b" 2>&1
run_engine deactivate >"$WORK/out.dea26b" 2>&1
printf 'line1\nline2\nline3' > "$WORK/want26b"
cp "$WORK/stub/settings/global.wifi_scan_always_enabled" "$WORK/got26b"
if cmp -s "$WORK/want26b" "$WORK/got26b"; then
  ok "the multi-line value came back byte for byte"
else
  bad "the multi-line value came back byte for byte"
  od -c "$WORK/want26b" | head -2 | sed 's/^/    want: /'
  od -c "$WORK/got26b"  | head -2 | sed 's/^/    got : /'
fi

say "27. re-entering after an unfinished exit still restores the true original"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap
screen_off
run_engine activate >/dev/null 2>&1
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1100000" ]
check "the cap is applied" $?
# The exit was interrupted after it had already marked the mode off: the
# journal is the only record of what the phone looked like before.
rm -f "$WORK/spsm/state/active"
run_engine activate >"$WORK/out.act27" 2>&1
run_engine deactivate >"$WORK/out.dea27" 2>&1
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1800000" ]
check "the original ceiling came back, not the capped one (got $(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"))" $?
run_engine verify >"$WORK/out.ver27" 2>&1
grep -q 'drift=0' "$WORK/out.ver27"; check "no drift" $?

say "28. a lock left by a dead process is taken at once"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/lock"
# pid 4194303 will not exist: a process that died holding the lock. Its mtime is
# fresh, so only a liveness check can tell that it is safe to take.
echo 4194303 > "$WORK/spsm/lock/pid"
screen_on
START=$(date +%s)
run_engine activate >"$WORK/out.act28" 2>&1
ACT_RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "activate succeeds instead of waiting out the stale-lock timer" $ACT_RC
[ "$ELAPSED" -lt 10 ]
check "and it did so immediately (${ELAPSED}s)" $?
[ ! -d "$WORK/spsm/lock" ]; check "the lock was released" $?

say "29. releasing doze does not look like an unmet promise"
make_tree; make_stubs; seed_stub_state
enable_knobs deep_doze
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
screen_on
run_engine screen-on >"$WORK/out.son29" 2>&1
run_engine deactivate >/dev/null 2>&1
run_engine verify >"$WORK/out.ver29" 2>&1
grep -q 'drift=0' "$WORK/out.ver29"; check "no drift after releasing doze" $?
grep -q 'left-alone=0' "$WORK/out.ver29"
LEFT_OK=$?
check "doze was not misreported as an external change ($(cat "$WORK/out.ver29"))" $LEFT_OK
[ "$LEFT_OK" = "0" ] || grep -E "keep |DRIFT" "$WORK/spsm/spsm.log" | tail -4 | sed 's/^/    /' 

say "30. the emergency brightness lift still exists, and still fires"
make_tree; make_stubs; seed_stub_state
# A revert that never finished: our cap is on the panel, the journal still says
# it is ours, and the mode is no longer flagged on. This is the only situation
# the net is for - a phone that is quietly unreadable.
mkdir -p "$WORK/spsm/journal"
printf 'brightness_cap\t10\n' > "$WORK/spsm/journal/brightness_cap.applied"
printf 'applied\n' > "$WORK/spsm/journal/brightness_cap.state"
screen_on
echo 10 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; safety_unlock' >/dev/null 2>&1
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "1638" ]
check "the net lifted a stuck dark cap to something readable (got $(cat "$ROOT/sys/class/leds/lcd-backlight/brightness"))" $?

# A panel that is dim but still readable is not an emergency: 900/4095 is
# nobody's idea of a stuck-black screen, and lifting that would be the module
# overruling a brightness the user chose.
echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
mkdir -p "$WORK/spsm/journal"
printf 'brightness_cap\t10\n' > "$WORK/spsm/journal/brightness_cap.applied"
printf 'applied\n' > "$WORK/spsm/journal/brightness_cap.state"
run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; safety_unlock' >/dev/null 2>&1
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "900" ]
check "a merely dim panel is left alone" $?

# ...but while the mode is on, that same dark panel is deliberate and must be
# left alone. The net must not fight the mode it belongs to.
echo 10 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
touch "$WORK/spsm/state/active"
run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; safety_unlock' >/dev/null 2>&1
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "10" ]
check "the net stays out of the way while the mode is on" $?
rm -f "$WORK/spsm/state/active"

# And a value the user owns is not ours to lift, even when it is dark.
rm -f "$WORK/spsm/journal/brightness_cap.applied" "$WORK/spsm/journal/brightness_cap.state"
echo 10 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; safety_unlock' >/dev/null 2>&1
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "10" ]
check "the net does not touch a brightness it never set" $?


say "31. the panel decides, and a stale marker cannot override it"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/state"

# The verified method: 0 means off, 1..max means on, on the panel's own range.
echo 0 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "off" ]
check "a dark panel reads as the screen being off" $?
echo 1 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "the lowest lit value (1) already reads as on" $?
echo 4095 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "the top of the range reads as on" $?

# A marker left behind by the app is stale evidence, and the panel outranks it.
# Getting this backwards is the expensive mistake: the mode would drop the phone
# into its deep phase while somebody is using it.
echo on > "$WORK/spsm/state/screen"
echo 0 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "a dark panel with a live \"on\" from the app is not called asleep" $?
echo off > "$WORK/spsm/state/screen"
echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "a lit panel beats a stale \"off\" in the marker" $?

# With no readable panel, the app's marker is the next answer, in both
# directions.
rm -f "$ROOT/sys/class/leds/lcd-backlight/brightness"
echo off > "$WORK/spsm/state/screen"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "off" ]
check "with no panel at all it falls back to the app marker (off)" $?
echo on > "$WORK/spsm/state/screen"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "and to the marker when it says on" $?
# With neither, dumpsys is the last resort - and that is where it stays.
rm -f "$WORK/spsm/state/screen"
echo off > "$WORK/stub/screen"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "off" ]
check "with nothing else, dumpsys answers" $?
echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"

say "32. the daemon follows the panel with no app and no signal at all"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/state"
echo "knob.cpu_cap=1" >> "$WORK/spsm/config"
screen_on
echo 1 > "$WORK/spsm/state/active"
SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" SPSM_STUB="$WORK/stub" PATH="$BIN:$PATH" \
  sh "$WORK/spsm/scripts/daemon.sh" >>"$WORK/spsm/spsm.log" 2>&1 &
DPID=$!
sleep 2
# Power button, with no help at all: no marker file, no SIGUSR1, no app. This is
# the phone where the app's receiver never fires, so the poll has to be enough.
echo 0 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
i=0
while [ $i -lt 24 ] && [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" != "1100000" ]; do
  sleep 0.25; i=$((i + 1))
done
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1100000" ]
check "the cap landed with no app involved (${i}x250ms)" $?
# And the wake must be just as prompt, in the other direction.
echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
i=0
while [ $i -lt 24 ] && [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" != "1800000" ]; do
  sleep 0.25; i=$((i + 1))
done
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1800000" ]
check "waking released the cap just as promptly (${i}x250ms)" $?
rm -f "$WORK/spsm/state/active"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null

say "33. the dim cap is expressed in this phone's own units"
make_tree; make_stubs; seed_stub_state
cap=$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; . "$SPSM_DIR/scripts/knobs.sh"; cap_value')
[ "$cap" = "327" ]
check "the default is a fraction of the panel, not a 0..255 guess (got $cap of 4095)" $?
ref=$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_panel_ceiling')
[ "$ref" = "4095" ]
check "the panel's own ceiling is read from the device (got $ref)" $?
echo "brightness_cap=4095" > "$WORK/spsm/config"
cap=$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; . "$SPSM_DIR/scripts/knobs.sh"; cap_value')
[ "$cap" = "4095" ]
check "an explicit raw value is left alone (got $cap)" $?
echo "brightness_cap=4%" > "$WORK/spsm/config"
cap=$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; . "$SPSM_DIR/scripts/knobs.sh"; cap_value')
[ "$cap" = "163" ]
check "a percentage is honoured (got $cap)" $?
rm -f "$WORK/spsm/config"
# A config carried over from a 0..255 phone must not silently do nothing.
echo "brightness_cap=160" > "$WORK/spsm/config"
cap=$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; . "$SPSM_DIR/scripts/knobs.sh"; cap_value')
[ "$cap" = "160" ]
check "a value from another phone is treated as raw, not as a no-op (got $cap)" $?
rm -f "$WORK/spsm/config"
# And the whole knob: on a 4095 panel it must dim, never brighten.
enable_knobs brightness_cap
screen_on
echo 4090 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
run_engine activate >/dev/null 2>&1
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "327" ]
check "the cap dimmed a bright panel to the resolved value" $?
run_engine screen-on >/dev/null 2>&1
# While the mode is on, dim IS the mode - the cap is a session knob and stays
# put on wake. What must never happen is the dim outliving the mode.
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "327" ]
check "the dim stays while the mode is on" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$ROOT/sys/class/leds/lcd-backlight/brightness")" = "4090" ]
check "and the original brightness is back the moment the mode is off" $?


# ==========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
