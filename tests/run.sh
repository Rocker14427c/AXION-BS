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
  # The per-cpu governor nodes the phone really has: the owner's own command
  # writes /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor, and the module
  # uses that path now. cpu0-3 and cpu6-7 point at their cluster's node, so a
  # write through either path is the same value; the middle group (cpu4-5) has no
  # governor node at all, which is this phone's shape - one cluster that simply
  # cannot be told, and the reason the v3.5.0 log read "1 of 2 cluster(s)".
  mkdir -p "$ROOT/sys/devices/system/cpu/cpufreq/policy4"
  for n in 0 1 2 3 4 5 6 7; do
    d="$ROOT/sys/devices/system/cpu/cpu$n/cpufreq"
    mkdir -p "$d"
    case "$n" in
      0|1|2|3)
        echo 0-3 > "$d/related_cpus"
        ln -sf ../../cpufreq/policy0/scaling_governor "$d/scaling_governor" ;;
      4|5)
        echo 4-5 > "$d/related_cpus" ;;
      6|7)
        echo 6-7 > "$d/related_cpus"
        ln -sf ../../cpufreq/policy6/scaling_governor "$d/scaling_governor" ;;
    esac
  done
  # A plain file cannot translate a write the way this kernel node does (the real
  # one answers "Low Power mode" after being written 1), so the shared tree holds
  # the number. Case 59 sets the sentence form explicitly, which is the shape the
  # phone reports and the shape that broke the exit.
  mkdir -p "$ROOT/proc/cpufreq"
  echo 0 > "$ROOT/proc/cpufreq/cpufreq_power_mode"
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
# Somebody other than the mode suspends an app - the user in Settings, or one of
# their own tools. It is the same system call the mode makes (the stub persists it
# in the system's own record, as the real one does), made by somebody else, so the
# module has to be able to tell their decision from its own.
user_suspends() {
  SPSM_STUB="$WORK/stub" PATH="$BIN:$PATH" "$BIN/pm" suspend --user 0 "$1" >/dev/null 2>&1
  : > "$WORK/stub/calls"   # it happened before the mode was turned on
}

make_stubs() {
  BIN="$WORK/bin"
  rm -rf "$BIN"; mkdir -p "$BIN"
  for c in settings getprop setprop resetprop svc pm am cmd dumpsys ps logcat wm service device_config; do
    printf '#!/bin/sh\nexec sh "%s/stub.sh" "$@"\n' "$REPO/tests" > "$BIN/$c"
    chmod +x "$BIN/$c"
  done
  # The dispatcher needs to know which name it was called as, which $0 gives
  # us only if we do not exec through another shell, so pass it explicitly.
  for c in settings getprop setprop resetprop svc pm am cmd dumpsys ps logcat wm service device_config; do
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
  # Navigation: the value the owner's phone reported before the mode touched
  # anything ("navigation_mode=2 (0=3-button 1=2-button 2=gestures)"). The
  # navigation-bar overlay and this setting are the same thing in the stub, the
  # way they are on the phone.
  printf '%s' 2 > "$S/settings/secure.navigation_mode"
  # The navigation bar's own place on the screen (its inset frame), the phone's
  # screen size and density, and the platform's frame-rate setting.
  echo 1516 > "$S/navbar_top"
  # The system's own record of which packages are suspended, in the shape the
  # phone writes it. Read by the module instead of asking about each app.
  mkdir -p "$S/users/0"
  cat > "$S/users/0/package-restrictions.xml" <<'XML'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<package-restrictions>
<pkg name="com.example.suspended.by.user" ceDataInode="123" enabled="1" installed="1" stopped="0" hidden="false" suspended="true" />
<pkg name="com.whatsapp" ceDataInode="124" enabled="1" installed="1" stopped="0" hidden="false" suspended="false" />
</package-restrictions>
XML
  echo 280 > "$S/wm_density"
  # The frame-rate override, armed by the module's system.prop at boot - the
  # state this phone is in after the reboot that installed the module.
  printf '%s' true > "$S/props/ro.surface_flinger.enable_frame_rate_override"
  printf '%s' 1 > "$S/settings/secure.location_mode"
  echo com.android.launcher3 > "$S/home_role"
  echo com.android.launcher3/.Launcher > "$S/home_activity"
  # What is on screen before anything runs: the launcher is the resumed
  # activity, which is how the module asks whether the home swap worked.
  echo com.android.launcher3/.Launcher > "$S/resumed"
  # The radio state the settings above describe, so a correct revert has to
  # put the interfaces back on rather than merely not turning them off.
  echo enable > "$S/svc.wifi"
  echo enable > "$S/svc.bluetooth"
  echo enable > "$S/svc.nfc"
  echo on > "$S/screen"
  # The system's location switch, which the module has to record for itself.
  echo true > "$S/location_enabled"
  # The mobile data switch, which the new knob records for itself.
  echo enable > "$S/svc.data"
  printf '%s' 1 > "$S/settings/global.mobile_data"
}

run_engine() { # run_engine args...
  SPSM_ROOT="$ROOT" \
  SPSM_DIR="$WORK/spsm" \
  SPSM_STUB="$WORK/stub" \
  SPSM_USERS="$WORK/stub/users" \
  PATH="$BIN:$PATH" \
  sh "$WORK/spsm/scripts/engine.sh" "$@"
}
run_shell_env() { # the same environment, for a piece of the module run by hand
  SPSM_ROOT="$ROOT" \
  SPSM_DIR="$WORK/spsm" \
  SPSM_STUB="$WORK/stub" \
  SPSM_USERS="$WORK/stub/users" \
  PATH="$BIN:$PATH" \
  "$@"
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

# Daemons from earlier cases keep watching the work directory, and there is more
# than one way for one of them to survive: its pid file is deleted with the old
# tree, so the module's own stop-daemon cannot recognise it afterwards. The
# harness kills by command line instead, asks again, and then insists - a live
# daemon mid-test acts on this case's files, and a test that measures work while
# a second process is doing the same work is measuring noise.
stop_daemons() {
  _p=$(cat "$WORK/spsm/daemon.pid" 2>/dev/null)
  [ -n "$_p" ] && kill "$_p" 2>/dev/null
  for _try in 1 2 3; do
    for _d in /proc/[0-9]*; do
      case "$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)" in
        *"$WORK/spsm/scripts/daemon.sh"*)
          [ "$_try" = 3 ] && kill -9 "$(basename "$_d")" 2>/dev/null || kill "$(basename "$_d")" 2>/dev/null ;;
      esac
    done
    sleep 0.3 2>/dev/null || sleep 1
  done
  return 0
}

# How many of this workflow's daemons are still running, asked of the process
# table rather than of the module's own bookkeeping.
daemons_alive() {
  _n=0
  for _d in /proc/[0-9]*; do
    case "$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)" in
      *"$WORK/spsm/scripts/daemon.sh"*) _n=$((_n + 1)) ;;
    esac
  done
  echo "$_n"
}

dump_state() {
  _out=$1
  : > "$_out"
  find "$ROOT" -type f | sort | while read -r f; do
    printf '%s=' "${f#$ROOT}"; cat "$f"; printf '\n'
  done >> "$_out"
  # Everything the fake device holds, except the harness's own notes about what
  # it was asked to do - calls, the tasks it was told to remove or bring to the
  # front, the apps it was asked to stop. Those are the stub's bookkeeping, not
  # the phone's state, and each has its own assertions where it matters.
  find "$WORK/stub" -type f \
       -not -name calls -not -name force_stopped -not -name task_in_front \
       -not -name task_started -not -name tasks_removed \
       -not -name uid_idle -not -name kill_all | sort | while read -r f; do
    case "${f#$WORK/stub/}" in
      # The module's own home screen is disabled again on the way out: that IS
      # its shipping state (the manifest ships it disabled), so a comparison
      # that counted it would demand the module leave a component of its own
      # enabled that it must not.
      component/dev.axion.spsm/*) continue ;;
      # The phone's own record of which packages are suspended is compared by what
      # it says, not by its bytes. The system rewrites that file whenever a
      # restriction changes - including when the mode suspends or releases an app,
      # which is the phone doing its job, not the mode leaving something behind -
      # and it keeps a line saying suspended="false" for an app that had none.
      # What has to come back is the set of suspensions itself, so that is what is
      # compared: the names the record says are suspended. A line saying
      # suspended="false" for an app that had no line before is the phone writing
      # down that nothing is suspended - it is not the mode leaving something
      # behind, and demanding it be erased would be demanding the phone forget.
      users/*/package-restrictions.xml)
        printf '%s=' "${f#$WORK/stub}"
        sed -n 's/.*<pkg name="\([^"]*\)".*suspended="true".*/\1/p' "$f" | sort | tr '\n' ' '
        printf '\n'
        continue ;;
    esac
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

# Is the deep phase in force?
#
# Two things can hold the processor down while the screen is off, and which one
# is in charge depends on an option: with gov_powersave on (the shipped default)
# the kernel's own power-save governor does it and no ceiling is written; with it
# off, the ceiling is written as it always was. Both are "the idle limits are in
# place"; the tests below ask this instead of one of the two spellings, so a case
# cannot pass merely because one mechanism went missing. The mechanism itself is
# tested directly, twice, in case 70.
deep_limits_on() {
  [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" 2>/dev/null)" = "powersave" ] && return 0
  [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" 2>/dev/null)" = "1100000" ] && return 0
  return 1
}
deep_limits_off() {
  [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" 2>/dev/null)" != "powersave" ] || return 1
  [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" 2>/dev/null)" = "1800000" ] || return 1
  return 0
}
# Did the kernel's governor take over the frequency? (The gov_powersave option.)
governor_is_powersave() {
  [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" 2>/dev/null)" = "powersave" ]
}
screen_on()  { echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"; echo on  > "$WORK/stub/screen"; }

enable_knobs() { # enable_knobs id...
  for k in "$@"; do echo "knob.$k=1" >> "$WORK/spsm/config"; done
}
disable_knobs() { # disable_knobs id... - for options whose default is on
  for k in "$@"; do echo "knob.$k=0" >> "$WORK/spsm/config"; done
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
# ...when the in-use option is off. With cap_always on - which is the shipped
# default - the speed limits are held while the screen is on instead; that is
# case 52's job below.
make_tree; make_stubs; seed_stub_state
disable_knobs cap_always
enable_knobs cpu_cap app_restrict
disable_knobs gov_powersave    # this case is about the ceiling itself
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
# A case about the deep phase must say the in-use option is off: with it on (the
# shipped default) the offline cores are held while the screen is on, which is
# case 52's subject, not this one's.
disable_knobs cap_always
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
disable_knobs gov_powersave    # this case is about the ceiling itself
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
disable_knobs gov_powersave    # this case is about the ceiling itself
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
# Both directions of this case are the deep phase: what matters here is the
# timing of the reaction, so the in-use option is off and the cap really is
# lifted on wake. With it on - the shipped default - the cap stays, by design.
echo "knob.cap_always=0" >> "$WORK/spsm/config"
# And the governor option off, for the same reason: with it on (the shipped
# default) the ceiling is deliberately never written, so there is nothing here
# to lift on wake and nothing that could go wrong while lifting it.
echo "knob.gov_powersave=0" >> "$WORK/spsm/config"
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
while [ $i -lt 80 ] && ! deep_limits_on; do sleep 0.25; i=$((i + 1)); done
deep_limits_on
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
deep_limits_off
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
disable_knobs gov_powersave    # this case is about the ceiling itself
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
disable_knobs gov_powersave    # this case is about the ceiling itself
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
deep_limits_on
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
disable_knobs gov_powersave    # this case is about the ceiling itself
screen_off
run_engine activate >/dev/null 2>&1
run_engine screen-off >/dev/null 2>&1
deep_limits_on
check "the cap is applied" $?
# The exit was interrupted after it had already marked the mode off: the
# journal is the only record of what the phone looked like before.
rm -f "$WORK/spsm/state/active"
run_engine activate >"$WORK/out.act27" 2>&1
run_engine deactivate >"$WORK/out.dea27" 2>&1
deep_limits_off
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

# The panel outranks the app's marker - but the app's write can genuinely arrive
# a moment before the backlight node lights, so a marker that is only seconds old
# is allowed to win a dark reading.
echo on > "$WORK/spsm/state/screen"
echo 0 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "a dark panel right after the app says \"on\" is not called asleep yet (the backlight has not come up)" $?

# The expensive mistake, and the one that was really happening on the device:
# the app writes "on" every time it is opened, and then its process is killed, so
# the marker stays "on" with nobody left to write "off". Trusting that for a
# whole day meant the daemon was certain the screen was never off, never entered
# the deep phase, and saved nothing at all.
echo on > "$WORK/spsm/state/screen"
touch -d '2 hours ago' "$WORK/spsm/state/screen"
echo 0 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "off" ]
check "a stale \"on\" marker cannot keep the mode out of its deep phase" $?

# And what decided is recorded, so a log answers the question by itself.
run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state; echo "src=$SCREEN_SRC raw=$PANEL_RAW"' > "$WORK/out.s31"
grep -q "src=panel raw=0" "$WORK/out.s31"
check "the panel is named as the source when the panel decides ($(cat "$WORK/out.s31" | tr '\n' ' '))" $?
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
echo "knob.cap_always=0" >> "$WORK/spsm/config"
# Both directions of this case are read from the ceiling itself, so the governor
# option - which deliberately leaves the ceiling alone - is off here.
echo "knob.gov_powersave=0" >> "$WORK/spsm/config"
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
while [ $i -lt 24 ] && ! deep_limits_on; do
  sleep 0.25; i=$((i + 1))
done
deep_limits_on
check "the cap landed with no app involved (${i}x250ms)" $?
# And the wake must be just as prompt, in the other direction.
echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
i=0
while [ $i -lt 24 ] && [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" != "1800000" ]; do
  sleep 0.25; i=$((i + 1))
done
deep_limits_off
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


say "34. a home that never comes up gets the launcher back"
make_tree; make_stubs; seed_stub_state
enable_knobs home_swap timeout_short
screen_on
# The new home is configured, launched and dies instead of coming up - exactly
# what happened on the device on 2026-09-13, where the phone was left with no
# home screen and the app restarting forever.
touch "$WORK/stub/home_broken"
run_engine activate >"$WORK/out.act34" 2>&1
grep -q "home_swap: our home did not come up" "$WORK/spsm/spsm.log"
check "the module noticed the home never came up" $?
[ "$(cat "$WORK/stub/home_activity")" = "com.android.launcher3/.Launcher" ]
check "the user's launcher is the configured home again" $?
[ "$(cat "$WORK/stub/home_role")" = "com.android.launcher3" ]
check "the home role went back to the user's launcher" $?
[ "$(cat "$WORK/stub/resumed")" = "com.android.launcher3/.Launcher" ]
check "and the launcher is the one on screen" $?
[ "$(cat "$WORK/spsm/journal/home_swap.state")" = "restored" ]
check "home_swap is recorded as restored, not as applied" $?
run_engine verify >"$WORK/out.ver34" 2>&1
grep -q 'drift=0' "$WORK/out.ver34"
check "verify does not call the change we undid a broken promise" $?
# The failure was the home alone: the rest of the mode must be untouched.
[ "$(cat "$WORK/stub/settings/system.screen_off_timeout")" = "15000" ]
check "the rest of the mode still applied" $?
[ -f "$WORK/spsm/state/active" ]
check "the mode is on, with the user's own launcher" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/system.screen_off_timeout")" = "30000" ]
check "exiting still restores everything else" $?
[ "$(cat "$WORK/stub/home_role")" = "com.android.launcher3" ]
check "and the launcher is still the home" $?

say "34b. a home that does come up is left alone"
make_tree; make_stubs; seed_stub_state
enable_knobs home_swap
screen_on
run_engine activate >/dev/null 2>&1
[ "$(cat "$WORK/stub/resumed")" = "dev.axion.spsm/.SpsmHomeActivity" ]
check "our home is the one on screen" $?
[ "$(cat "$WORK/spsm/journal/home_swap.state")" = "applied" ]
check "and it is recorded as applied" $?
if grep -q "did not come up" "$WORK/spsm/spsm.log"; then
  bad "no false alarm about a home that is working"
else
  ok "no false alarm about a home that is working"
fi
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/resumed")" = "com.android.launcher3/.Launcher" ]
check "exiting puts the real launcher back on screen" $?
[ "$(cat "$WORK/stub/home_activity")" = "com.android.launcher3/.Launcher" ]
check "and the launcher is the configured home again" $?


say "35. a read that fails is never stored, and never made a change of ours"
make_tree; make_stubs; seed_stub_state
# The device refuses to hand over this one key, on every session.
touch "$WORK/stub/fail_read.global.ble_scan_always_enabled"
printf '%s' 1 > "$WORK/stub/settings/global.ble_scan_always_enabled"
enable_knobs scan_always_off
screen_on
run_engine activate >"$WORK/out.act35" 2>&1
grep -q "(MISSING)" "$WORK/spsm/journal/scan_always_off.orig"
check "the failed read is recorded as no reading, not as the error sentence" $?
if grep -q "Failure calling service" "$WORK/spsm/journal/scan_always_off.orig" "$WORK/spsm/journal/scan_always_off.applied"; then
  bad "the error sentence never reached the journal"
else
  ok "the error sentence never reached the journal"
fi
[ "$(cat "$WORK/stub/settings/global.ble_scan_always_enabled")" = "1" ]
check "a value that could not be read was left alone (not overwritten with our value)" $?
grep -q "skip @global:ble_scan_always_enabled" "$WORK/spsm/spsm.log"
check "and the log says why it was skipped" $?
# The keys that ARE readable in the same knob must still be applied and reverted.
[ "$(cat "$WORK/stub/settings/global.wifi_scan_always_enabled")" = "0" ]
check "the readable values in the same knob were applied" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/global.wifi_scan_always_enabled")" = "1" ]
check "and reverted" $?
[ "$(cat "$WORK/stub/settings/global.ble_scan_always_enabled")" = "1" ]
check "the unreadable key is still untouched" $?
if grep -rq "Failure calling service" "$WORK/stub/settings/"; then
  bad "no setting was ever written from an error sentence"
else
  ok "no setting was ever written from an error sentence"
fi

say "36. the home snapshot survives a ROM that answers with complaints"
make_tree; make_stubs; seed_stub_state
enable_knobs home_swap
screen_on
run_engine activate >/dev/null 2>&1
grep -q "^activity	com.android.launcher3/.Launcher$" "$WORK/spsm/journal/home_swap.orig"
check "the real launcher activity was recorded (with the action resolve-activity needs)" $?
grep -q "^component	unknown$" "$WORK/spsm/journal/home_swap.orig"
check "a missing subcommand is recorded as unknown, not as its complaint" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/home_activity")" = "com.android.launcher3/.Launcher" ]
check "exiting configures the launcher again, from a believable record" $?
if grep -q "No activity found" "$WORK/spsm/journal/home_swap.orig"; then
  bad "no command complaint was recorded as the original home"
else
  ok "no command complaint was recorded as the original home"
fi

say "37. turning it on while it is on is cheap and changes nothing"
make_tree; make_stubs; seed_stub_state
enable_knobs timeout_short
screen_on
run_engine activate >/dev/null 2>&1
: > "$WORK/stub/calls"
run_engine activate >"$WORK/out.act37" 2>&1
grep -q "already on - ensuring the daemon and the deep phase" "$WORK/spsm/spsm.log"
check "a second activation says what it is doing" $?
_more=$(wc -l < "$WORK/stub/calls" | tr -d ' ')
[ "$_more" -lt 12 ]
check "and costs a handful of commands, not a whole re-apply (used $_more)" $?
[ "$(cat "$WORK/spsm/journal/timeout_short.state")" = "applied" ]
check "the knob is still applied, untouched by the second activation" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/system.screen_off_timeout")" = "30000" ]
check "and the session still reverts cleanly afterwards" $?

say "38. a full turn of the mode is not a subprocess marathon"
make_tree; make_stubs; seed_stub_state
screen_on
: > "$WORK/stub/calls"
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
_total=$(wc -l < "$WORK/stub/calls" | tr -d ' ')
# The device spends about a fifth of a second on each of these, so the count is
# what the user feels. This is a guard, not a target: it exists to catch a
# change that quietly multiplies the work (the way a second full snapshot per
# knob used to).
[ "$_total" -lt 400 ]
check "a whole turn stays under the command budget ($_total stubbed commands, was 300+ before the read rework)" $?


say "39. blocking other apps undoes only its own work"
make_tree; make_stubs; seed_stub_state
# Four third-party apps: one the user allowed, one the user had already
# suspended themselves, one root manager, and one ordinary app.
printf 'com.whatsapp\ncom.spotify.music\ncom.example.game\ncom.resukisu.resukisu\n' > "$WORK/stub/pkgs3"
user_suspends com.example.game
printf 'com.spotify.music\n' > "$WORK/spsm/whitelist.txt"
enable_knobs block_other_apps
screen_on
run_engine activate >"$WORK/out.act39" 2>&1
[ -f "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "an app the user did not allow was suspended" $?
[ ! -f "$WORK/stub/pkg/com.spotify.music.suspended" ]
check "an allowed app was left alone" $?
[ ! -f "$WORK/stub/pkg/com.resukisu.resukisu.suspended" ]
check "the root manager was left alone (it is how the user gets out)" $?
[ -f "$WORK/stub/pkg/com.example.game.suspended" ]
check "an app the user had suspended themselves is still suspended" $?
grep -q "^com.whatsapp$" "$WORK/spsm/state/blocked_by_us.tsv"
check "the module recorded what it suspended" $?
if grep -q "^com.example.game$" "$WORK/spsm/state/blocked_by_us.tsv"; then
  bad "it did not claim the user's own suspension as its own"
else
  ok "it did not claim the user's own suspension as its own"
fi
run_engine deactivate >"$WORK/out.de39" 2>&1
[ ! -f "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "exiting released the app it suspended" $?
[ -f "$WORK/stub/pkg/com.example.game.suspended" ]
check "and left the user's own suspension exactly as it was" $?
run_engine verify >"$WORK/out.ver39" 2>&1
grep -q 'drift=0' "$WORK/out.ver39"
check "no drift after the block ($(cat "$WORK/out.ver39"))" $?
# And the knob is an opt-out: with it off, nothing is suspended at all.
make_tree; make_stubs; seed_stub_state
printf 'com.whatsapp\ncom.spotify.music\n' > "$WORK/stub/pkgs3"
echo "knob.block_other_apps=0" >> "$WORK/spsm/config"
screen_on
run_engine activate >/dev/null 2>&1
[ ! -f "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "with the knob off, nothing is suspended (opt-out honoured)" $?
run_engine deactivate >/dev/null 2>&1

say "40. the idle state is written down where it can be read afterwards"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap deep_doze
disable_knobs gov_powersave    # this case is about the ceiling itself
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >"$WORK/out.off40" 2>&1
run_engine status >"$WORK/out.st40" 2>&1
grep -q "^deep=little_max=" "$WORK/out.st40"
check "status shows what the caps actually were while asleep" $?
grep -q "little_max=1100000" "$WORK/out.st40"
check "and the little cluster ceiling is in it (little_max=1100000)" $?
grep -q "deep applied: " "$WORK/spsm/spsm.log"
check "the same line is in the log, written at the moment it applied" $?
screen_on
run_engine screen-on >/dev/null 2>&1
run_engine status >"$WORK/out.st40b" 2>&1
grep -q "^deep=released$" "$WORK/out.st40b"
check "after waking, status says the idle state is released" $?
run_engine deactivate >/dev/null 2>&1


say "41. the phone that saved nothing: a stale marker, and a screen that goes off"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/state"
echo "knob.cpu_cap=1" >> "$WORK/spsm/config"
echo "knob.cap_always=0" >> "$WORK/spsm/config"   # the wake must release the caps
echo "knob.gov_powersave=0" >> "$WORK/spsm/config" # ...and the caps themselves are what is watched here
# Heartbeats every two ticks, so the suite does not have to wait three minutes
# for one.
echo "heartbeat_ticks=2" >> "$WORK/spsm/config"
screen_on
# What is left of the app after Android reclaims it: it wrote "on" the last time
# it was opened, and the process that would have written "off" is long gone.
echo on > "$WORK/spsm/state/screen"
touch -d '3 hours ago' "$WORK/spsm/state/screen"
echo 1 > "$WORK/spsm/state/active"
SPSM_ROOT="$ROOT" SPSM_DIR="$WORK/spsm" SPSM_STUB="$WORK/stub" PATH="$BIN:$PATH" \
  sh "$WORK/spsm/scripts/daemon.sh" >>"$WORK/spsm/spsm.log" 2>&1 &
DPID=$!
sleep 2
echo 0 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
i=0
while [ $i -lt 24 ] && ! deep_limits_on; do
  sleep 0.25; i=$((i + 1))
done
deep_limits_on
check "the deep phase engages despite the stale \"on\" marker (${i}x250ms)" $?
grep -q "screen on -> off (panel=0 via panel)" "$WORK/spsm/spsm.log"
check "and the log names the panel as what decided it" $?
# The heartbeat proves the daemon is alive and watching while nothing else is
# happening - the difference between "doing nothing" and "not running".
# Wait for the heartbeat that says the whole sentence - the screen off, the deep
# phase applied, the ceiling in it and a tick count - rather than for the first
# line that happens to carry "panel=0": the heartbeat at the top of a tick prints
# the state the tick found, so the line that names the dark screen only comes
# round a tick or two later, and a tick here is seconds long.
i=0
heartbeat=""
while [ $i -lt 60 ]; do
  heartbeat=$(grep -m1 -E "daemon alive: panel=0 state=off deep=applied caps_little=[0-9]+ ticks=[0-9]+" "$WORK/spsm/spsm.log")
  [ -n "$heartbeat" ] && break
  sleep 0.5; i=$((i + 1))
done
[ -n "$heartbeat" ]
check "the heartbeat says the state, the caps and that it is alive (after $((i * 5))00ms: $(printf '%s' "$heartbeat" | sed 's/^[0-9-]* [0-9:]* //'))" $?
echo 900 > "$ROOT/sys/class/leds/lcd-backlight/brightness"
i=0
while [ $i -lt 24 ] && [ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" != "1800000" ]; do
  sleep 0.25; i=$((i + 1))
done
deep_limits_off
check "and the wake still releases everything (${i}x250ms)" $?
rm -f "$WORK/spsm/state/active"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null

say "42. status says which source decided, and whether the daemon is alive"
make_tree; make_stubs; seed_stub_state
screen_off
run_engine status > "$WORK/out.st42" 2>&1
grep -q "^screen=off$" "$WORK/out.st42"
check "a dark panel reads as off" $?
grep -q "^screen_source=panel$" "$WORK/out.st42"
check "and the panel is named as the source" $?
grep -q "^daemon=none$" "$WORK/out.st42"
check "with the mode off, there is no daemon and status says so" $?
screen_on
enable_knobs timeout_short
run_engine activate >/dev/null 2>&1
run_engine status > "$WORK/out.st42b" 2>&1
grep -q "^daemon=[0-9]" "$WORK/out.st42b"
check "with the mode on, status shows the daemon's pid" $?
run_engine deactivate >/dev/null 2>&1

say "43. a value that could not be read can never be counted as drift"
make_tree; make_stubs; seed_stub_state
# This ROM refuses to read these two keys at all - the exact pair from the
# device log.
touch "$WORK/stub/fail_read.global.ble_scan_always_enabled"
touch "$WORK/stub/fail_read.secure.location_mode"
enable_knobs timeout_short scan_always_off location_off
screen_on
run_engine activate > "$WORK/out.a43" 2>&1
grep -q "skip @global:ble_scan_always_enabled: it could not be read" "$WORK/spsm/spsm.log"
check "the unreadable key is skipped on the way in" $?
run_engine deactivate > "$WORK/out.d43" 2>&1
grep -q "revert clean" "$WORK/spsm/spsm.log"
check "and the exit is clean, not a false alarm about it ($(grep -o 'exit: .*' "$WORK/spsm/spsm.log" | tail -1))" $?
if grep -q "could not be restored" "$WORK/spsm/spsm.log"; then
  bad "the exit did not claim an unreadable value it never changed was unrestored"
else
  ok "the exit did not claim an unreadable value it never changed was unrestored"
fi

say "44. a restore that failed once is tried again instead of being counted forever"
make_tree; make_stubs; seed_stub_state
enable_knobs timeout_short
screen_on
run_engine activate >/dev/null 2>&1
# A session that died left this record behind in the state a failed revert
# writes. Its change is still on the device, so it is still ours to undo.
echo applied > "$WORK/spsm/journal/timeout_short.state"
run_engine deactivate > "$WORK/out.d44a" 2>&1
_before=$(cat "$WORK/spsm/journal/timeout_short.state")
echo restored-drift > "$WORK/spsm/journal/timeout_short.state"
# The value is put back on the device so that the second revert has real work to
# do, exactly like a phone where the first attempt was interrupted.
run_engine activate >/dev/null 2>&1
echo restored-drift > "$WORK/spsm/journal/timeout_short.state"
run_engine deactivate > "$WORK/out.d44" 2>&1
[ "$(cat "$WORK/spsm/journal/timeout_short.state")" = "restored" ]
check "the leftover record was reverted and closed, not just counted" $?
grep -q "revert clean" "$WORK/spsm/spsm.log"
check "so the exit reports a clean revert" $?
if grep -q "value(s) could not be restored" "$WORK/spsm/spsm.log"; then
  bad "the exit did not invent drifted knobs from an earlier session"
else
  ok "the exit did not invent drifted knobs from an earlier session"
fi

say "45. location is switched off only when its state can be read, and put back as it was"
make_tree; make_stubs; seed_stub_state
enable_knobs location_off
screen_on
echo true > "$WORK/stub/location_enabled"
run_engine activate > "$WORK/out.a45" 2>&1
[ "$(cat "$WORK/stub/location_enabled")" = "false" ]
check "location that was on was switched off" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/location_enabled")" = "true" ]
check "and switched back on again on exit" $?
# Location the user had already switched off is not ours to switch on.
make_tree; make_stubs; seed_stub_state
enable_knobs location_off
screen_on
echo false > "$WORK/stub/location_enabled"
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/location_enabled")" = "false" ]
check "location the user had off stays off (we did not switch it on)" $?
# And when the switch cannot be read, nothing is touched at all.
make_tree; make_stubs; seed_stub_state
enable_knobs location_off
screen_on
echo true > "$WORK/stub/location_enabled"
touch "$WORK/stub/fail_read.cmd.location_enabled"
run_engine activate > "$WORK/out.a45b" 2>&1
[ "$(cat "$WORK/stub/location_enabled")" = "true" ]
check "with the state unreadable, location is left alone" $?
grep -q "skip location: its state could not be read" "$WORK/spsm/spsm.log"
check "and it says so in the log" $?
run_engine deactivate > "$WORK/out.d45b" 2>&1
grep -q "revert clean" "$WORK/spsm/spsm.log"
check "and the exit is clean" $?

say "46. an unreadable panel asks the power manager instead of believing an old marker"
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/spsm/state"
rm -f "$ROOT/sys/class/leds/lcd-backlight/brightness"
# What the app left behind the last time it was opened, hours ago.
echo on > "$WORK/spsm/state/screen"
touch -d '3 hours ago' "$WORK/spsm/state/screen"
echo off > "$WORK/stub/screen"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "off" ]
check "with no panel, the system's own answer is believed over an old marker" $?
rm -f "$WORK/spsm/state/screen_dump"   # let the cache expire, as time would
echo on > "$WORK/stub/screen"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "and in the other direction too" $?
# A marker written seconds ago is a real event and still wins.
echo off > "$WORK/stub/screen"
echo on > "$WORK/spsm/state/screen"
[ "$(run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state')" = "on" ]
check "a marker from seconds ago still outranks it (a screen that has just woken)" $?
# The dump is a binder call, so it is not repeated for every tick.
rm -f "$WORK/spsm/state/screen" "$WORK/spsm/state/screen_dump"
: > "$WORK/stub/calls"
run_shell -c '. "$SPSM_DIR/scripts/lib.sh"; screen_state >/dev/null; screen_state >/dev/null; screen_state >/dev/null'
_n=$(grep -c "^dumpsys power" "$WORK/stub/calls")
[ "$_n" = "1" ]
check "three ticks while the panel is unreadable cost exactly one dump ($_n)" $?

say "47. the phone can be asked which options actually do something"
make_tree; make_stubs; seed_stub_state
screen_on
# One of each: a knob that changes something, one that is already satisfied
# (accelerometer_rotation is 0 here, so rotate_lock has nothing to do), and one
# whose controls cannot be read at all.
echo "knob.rotate_lock=1" >> "$WORK/spsm/config"
echo "knob.wifi_off=1" >> "$WORK/spsm/config"
echo "knob.aod_off=1" >> "$WORK/spsm/config"
run_engine probe > "$WORK/out.p47" 2>&1
[ -s "$WORK/spsm/state/probe.tsv" ]
check "a report was written where the app can read it" $?
grep -q "^wifi_off	works" "$WORK/spsm/state/probe.tsv"
check "an option that changed the phone is called works ($(grep '^wifi_off' "$WORK/spsm/state/probe.tsv"))" $?
grep -q "^rotate_lock	works" "$WORK/spsm/state/probe.tsv"
check "an option that changed something is called works ($(grep '^rotate_lock' "$WORK/spsm/state/probe.tsv"))" $?
# An option whose work is already done is inert, not broken: NFC is already off
# here, so switching it off achieves nothing - which is worth knowing.
echo disable > "$WORK/stub/svc.nfc"
printf '0' > "$WORK/stub/settings/global.nfc_on"
printf 'knob.nfc_off=1\n' >> "$WORK/spsm/config"
run_engine probe > "$WORK/out.p47c" 2>&1
grep -q "^nfc_off	inert" "$WORK/spsm/state/probe.tsv"
check "an option with nothing to do is called inert, not broken ($(grep '^nfc_off' "$WORK/spsm/state/probe.tsv"))" $?
# Nothing the probe touched may be left behind.
[ "$(cat "$WORK/stub/svc.wifi")" = "enable" ]
check "the probe put the radio back" $?
[ ! -d "$WORK/spsm/probe" ]
check "and took its scratch journal with it" $?
run_engine verify > "$WORK/out.v47" 2>&1
grep -q "drift=0" "$WORK/out.v47"
check "a probe leaves no drift ($(cat "$WORK/out.v47"))" $?
# It refuses to run while the mode is on: that is not its journal to touch.
enable_knobs timeout_short
run_engine activate >/dev/null 2>&1
run_engine probe > "$WORK/out.p47b" 2>&1
grep -q "SPSM is ON" "$WORK/out.p47b"
check "the probe refuses to run in the middle of a session" $?
run_engine deactivate >/dev/null 2>&1
run_engine status > "$WORK/out.s47" 2>&1
grep -q "^probe=works:" "$WORK/out.s47"
check "status summarises the last probe" $?
grep -q "^scripts=" "$WORK/out.s47"
check "and status names the scripts this phone is running" $?

say "48. a radio is switched only when its state could be read"
make_tree; make_stubs; seed_stub_state
enable_knobs wifi_off bt_off nfc_off
screen_on
# Bluetooth is ON (the stub's svc state says enable) even though the setting the
# old code recorded said 0 - which is how the device ended up with the radio off
# and nothing to turn it back on.
[ "$(cat "$WORK/stub/svc.bluetooth")" = "enable" ]
run_engine activate > "$WORK/out.a48" 2>&1
[ "$(cat "$WORK/stub/svc.bluetooth")" = "disable" ]
check "bluetooth that was on was switched off" $?
run_engine deactivate > "$WORK/out.d48" 2>&1
[ "$(cat "$WORK/stub/svc.bluetooth")" = "enable" ]
check "and switched back on because it was on before" $?
[ "$(cat "$WORK/stub/svc.wifi")" = "enable" ]
check "the same for wifi" $?
[ "$(cat "$WORK/stub/svc.nfc")" = "enable" ]
check "and nfc" $?
# A radio whose state cannot be read is left completely alone.
make_tree; make_stubs; seed_stub_state
enable_knobs wifi_off
screen_on
touch "$WORK/stub/fail_read.radio.wifi"
touch "$WORK/stub/fail_read.global.wifi_on"
run_engine activate > "$WORK/out.a48b" 2>&1
[ "$(cat "$WORK/stub/svc.wifi")" = "enable" ]
check "an unreadable radio is not switched at all" $?
grep -q "skip wifi: its state could not be read" "$WORK/spsm/spsm.log"
check "and the log says why" $?
run_engine deactivate > "$WORK/out.d48b" 2>&1
[ "$(cat "$WORK/stub/svc.wifi")" = "enable" ]
check "and it is still on after the exit" $?

say "49. a session names the code it is running"
make_tree; make_stubs; seed_stub_state
screen_on
enable_knobs timeout_short
run_engine activate >/dev/null 2>&1
grep -q "===== SPSM v3 ON (scripts .* module .*) =====" "$WORK/spsm/spsm.log"
check "the session header says which scripts and which module ($(grep -m1 'SPSM v3 ON' "$WORK/spsm/spsm.log" | sed 's/^[0-9-]* [0-9:]* //'))" $?
run_engine deactivate >/dev/null 2>&1
# And a phone running stale scripts is told so, loudly, on the next switch.
printf '3.0.0\n' > "$WORK/spsm/state/script_version"
mkdir -p "$WORK/module/scripts"
cp "$WORK/spsm/scripts/"*.sh "$WORK/module/scripts/"
printf 'version=9.9.9\n' > "$WORK/module/module.prop"
echo "$WORK/module" > "$WORK/spsm/moddir"
run_engine activate >/dev/null 2>&1
grep -q "scripts updated: this phone was running 3.0.0, the module is 9.9.9" "$WORK/spsm/spsm.log"
check "stale scripts are replaced and the log says which was running" $?
[ "$(cat "$WORK/spsm/state/script_version")" = "9.9.9" ]
check "and the stamp now matches the module" $?
run_engine deactivate >/dev/null 2>&1

say "50. mobile data is an option, and it goes back the way it was"
make_tree; make_stubs; seed_stub_state
screen_on
# Off by default: cutting data is the user's decision, not the mode's.
run_engine activate > "$WORK/out.a50" 2>&1
[ "$(cat "$WORK/stub/svc.data")" = "enable" ]
check "with the option off, mobile data is untouched (it defaults to off)" $?
run_engine deactivate >/dev/null 2>&1
make_tree; make_stubs; seed_stub_state
screen_on
enable_knobs data_off
run_engine activate > "$WORK/out.a50b" 2>&1
[ "$(cat "$WORK/stub/svc.data")" = "disable" ]
check "with the option on, mobile data is switched off" $?
run_engine deactivate > "$WORK/out.d50" 2>&1
[ "$(cat "$WORK/stub/svc.data")" = "enable" ]
check "and switched back on when the mode is switched off" $?
run_engine verify > "$WORK/out.v50" 2>&1
grep -q "drift=0" "$WORK/out.v50"
check "with no drift ($(cat "$WORK/out.v50"))" $?
# Data the user had off stays off - the mode never switches a radio on that it
# did not switch off.
make_tree; make_stubs; seed_stub_state
screen_on
enable_knobs data_off
printf '0' > "$WORK/stub/settings/global.mobile_data"
printf 'disable' > "$WORK/stub/svc.data"
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/svc.data")" = "disable" ]
check "data the user had off is still off (nothing was switched on)" $?
# And when its state cannot be read from any source, it is not touched at all -
# the same rule the other radios follow, because a radio switched off with no
# believable way back is the mistake this whole family of checks exists to stop.
make_tree; make_stubs; seed_stub_state
screen_on
enable_knobs data_off
touch "$WORK/stub/fail_read.global.mobile_data"
touch "$WORK/stub/fail_read.global.mobile_data1"
touch "$WORK/stub/fail_read.global.mobile_data2"
printf 'disable' > "$WORK/stub/svc.data"
run_engine activate > "$WORK/out.a50c" 2>&1
grep -q "skip mobile data: its state could not be read" "$WORK/spsm/spsm.log"
check "with the state unreadable, data is left alone and the log says so" $?
run_engine deactivate >/dev/null 2>&1

say "51. the exit takes the lock from its own worker instead of queueing behind it"
make_tree; make_stubs; seed_stub_state
enable_knobs timeout_short
screen_on
run_engine activate >/dev/null 2>&1
# A transition in flight: a live process holding the lock, exactly like the
# screen-on revert that was running when the user tapped exit.
# A live worker holding the lock, with a command line that says it is ours: the
# preemption only ever ends engine.sh/daemon.sh, never a stranger. The script is
# a stand-in for the real engine - it only has to exist under that name and hold
# the lock while it "works".
mkdir -p "$WORK/spsm/lock" "$WORK/fake"
printf '#!/bin/sh\nsleep 30\n' > "$WORK/fake/engine.sh"
sh "$WORK/fake/engine.sh" &
FAKE=$!
sleep 0.3
[ -d "/proc/$FAKE" ]
check "the stand-in worker is really running" $?
echo "$FAKE" > "$WORK/spsm/lock/pid"
_t0=$(date +%s)
run_engine deactivate > "$WORK/out.d51" 2>&1
_took=$(( $(date +%s) - _t0 ))
[ "$_took" -lt 10 ]
check "the exit did not wait out the lock (${_took}s, was 20s+)" $?
grep -q "exit preempted an in-flight transition" "$WORK/spsm/spsm.log"
check "and it says so in the log" $?
kill "$FAKE" 2>/dev/null; wait 2>/dev/null
run_engine verify > "$WORK/out.v51" 2>&1
grep -q "drift=0" "$WORK/out.v51"
check "a preempted exit still leaves nothing behind ($(cat "$WORK/out.v51"))" $?

say "52. the speed limits can be held with the screen on, if that is what is wanted"
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap gpu_cap cpu_offline_big deep_doze
disable_knobs gov_powersave    # this case is about the ceiling itself
disable_knobs cap_always
screen_on
run_engine activate >/dev/null 2>&1
deep_limits_off
check "with the in-use option off, nothing is capped while the screen is on" $?
run_engine deactivate >/dev/null 2>&1
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap gpu_cap cpu_offline_big deep_doze
disable_knobs gov_powersave    # this case is about the ceiling itself
enable_knobs cap_always
screen_on
run_engine activate > "$WORK/out.a52" 2>&1
grep -q "cap_always: performance limits applied now" "$WORK/spsm/spsm.log"
check "with cap_always the limits are applied as soon as the mode is on" $?
deep_limits_on
check "and the little cluster is capped with the screen on" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu7/online")" = "0" ]
check "the big cores are offline with the screen on" $?
# A screen-off/screen-on cycle must not release them...
run_engine screen-off >/dev/null 2>&1
run_engine screen-on >/dev/null 2>&1
deep_limits_on
check "an ordinary screen change does not release them" $?
# ...but doze must never be held while the phone is being used.
[ ! -f "$WORK/stub/doze_forced" ]
check "deep doze is still released when the screen comes back on" $?
# And the exit puts everything back, cap_always or not.
run_engine deactivate > "$WORK/out.d52" 2>&1
deep_limits_off
check "the exit restores the ceiling" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpu7/online")" = "1" ]
check "and brings the cores back" $?
run_engine verify > "$WORK/out.v52" 2>&1
grep -q "drift=0" "$WORK/out.v52"
check "with no drift ($(cat "$WORK/out.v52"))" $?

say "53. the check says why it declined instead of finishing silently"
make_tree; make_stubs; seed_stub_state
enable_knobs timeout_short
screen_on
run_engine activate >/dev/null 2>&1
run_engine probe > "$WORK/out.p53" 2>&1
grep -q "SPSM is ON" "$WORK/out.p53"
check "a check while the mode is on explains that it needs the mode off" $?
grep -q "probe: declined" "$WORK/spsm/spsm.log"
check "and the refusal is in the log, where it can be seen later" $?
run_engine deactivate >/dev/null 2>&1
# A single option can be checked on its own, which is how to work through them
# one at a time on a real phone.
run_engine probe wifi_off > "$WORK/out.p53b" 2>&1
grep -q "^wifi_off: " "$WORK/out.p53b"
check "one option can be checked by name ($(grep -m1 '^wifi_off' "$WORK/out.p53b"))" $?
grep -q "probe: starting" "$WORK/spsm/spsm.log"
check "and the check's own findings stay in the log instead of being deleted with its scratch files" $?
[ ! -d "$WORK/spsm/probe" ]
check "while the scratch journal is still removed" $?

say "54. an app added to a slot is freed at once; one taken out is not"
make_tree; make_stubs; seed_stub_state
enable_knobs block_other_apps
printf 'com.whatsapp\ncom.spotify.music\n' > "$WORK/stub/pkgs3"
screen_on
run_engine activate >/dev/null 2>&1
[ -f "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "both apps are blocked while the mode is on" $?
# The user adds one of them to a slot: this is what the app writes and then asks
# the engine to apply.
printf 'com.whatsapp\n' > "$WORK/spsm/whitelist.txt"
run_engine allow > "$WORK/out.allow54" 2>&1
[ ! -f "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "the app in a slot is usable again immediately" $?
[ -f "$WORK/stub/pkg/com.spotify.music.suspended" ]
check "and the others are still blocked" $?
grep -q "allow com.whatsapp: it is in the six slots" "$WORK/spsm/spsm.log"
check "the log says why it was let through" $?
# Taking it out again puts it back under the mode, without waiting for a reboot.
: > "$WORK/spsm/whitelist.txt"
screen_off
run_engine allow > "$WORK/out.allow54b" 2>&1
[ -f "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "an app taken out of the slots is blocked again while the phone is idle" $?
screen_on
run_engine deactivate > "$WORK/out.d54" 2>&1
[ ! -f "$WORK/stub/pkg/com.whatsapp.suspended" ] && [ ! -f "$WORK/stub/pkg/com.spotify.music.suspended" ]
check "and the exit restores every app the module blocked" $?
run_engine verify > "$WORK/out.v54" 2>&1
grep -q "drift=0" "$WORK/out.v54"
check "with no drift ($(cat "$WORK/out.v54"))" $?
# An app the user suspended themselves is never released just because it is in a
# slot - that is their own decision, not ours to undo.
make_tree; make_stubs; seed_stub_state
printf 'com.example.game\n' > "$WORK/stub/pkgs3"
user_suspends com.example.game
enable_knobs block_other_apps
screen_on
run_engine activate >/dev/null 2>&1
printf 'com.example.game\n' > "$WORK/spsm/whitelist.txt"
run_engine allow >/dev/null 2>&1
[ -f "$WORK/stub/pkg/com.example.game.suspended" ]
check "an app the user suspended themselves stays suspended" $?
run_engine deactivate >/dev/null 2>&1

say "55. the graphics lock is released, not left holding the GPU down"
make_tree; make_stubs; seed_stub_state
disable_knobs cap_always        # this case is about the wake releasing things
enable_knobs gpu_cap
screen_on
mkdir -p "$ROOT/proc/gpufreq"
printf 'Keeping OPP frequency is disabled\n' > "$ROOT/proc/gpufreq/gpufreq_opp_freq"
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off > "$WORK/out.off55" 2>&1
grep -q "Keeping OPP frequency is enabled" "$ROOT/proc/gpufreq/gpufreq_opp_freq" \
  || [ "$(cat "$ROOT/proc/gpufreq/gpufreq_opp_freq")" = "300000" ]
check "the graphics lock is set while asleep" $?
run_engine screen-on > "$WORK/out.on55" 2>&1
[ "$(cat "$ROOT/proc/gpufreq/gpufreq_opp_freq")" = "0" ]
check "and explicitly released on wake, rather than left engaged" $?
grep -q "gpu_cap did not return" "$WORK/spsm/spsm.log"
if [ $? = 0 ]; then bad "the readback of a write-only node is no longer mistaken for drift"; else ok "the readback of a write-only node is no longer mistaken for drift"; fi

say "56. a control option is a setting, not an untestable device change"
make_tree; make_stubs; seed_stub_state
echo "knob.cap_always=1" >> "$WORK/spsm/config"
screen_on
run_engine probe cap_always > "$WORK/out.p56" 2>&1
grep -q "^cap_always: preference" "$WORK/out.p56"
check "the check reports it as a preference ($(grep -m1 '^cap_always' "$WORK/out.p56"))" $?
grep -q "^cap_always	unknown" "$WORK/spsm/state/probe.tsv"
if [ $? = 0 ]; then bad "it is not reported as an untestable option"; else ok "it is not reported as an untestable option"; fi

say "57. the app's text, its placeholders and the home screen it must never lose"
# The crash that took the phone's home screen down: a string was changed from
# "About %1$s remaining" to a number placeholder while the code still passed it
# text, so the first battery reading threw and the home screen died. Nothing in
# the build looks at that, so it is checked here.
python3 - "$REPO" <<'PY57'
import re, sys, os
repo = sys.argv[1]
strings = {}
xml = open(os.path.join(repo, 'app/res/values/strings.xml')).read()

# name -> placeholder kinds, in the order they appear, e.g. ['s','d']
for m in re.finditer(r'<string name="([a-z_]+)"[^>]*>(.*?)</string>', xml, re.S):
    strings[m.group(1)] = re.findall(r'%\d+\$([sdf])', m.group(2))

src_dir = os.path.join(repo, 'app/src/dev/axion/spsm')

# Which methods in this app hand back text? A number placeholder fed by one of
# them is the bug that blanked the home screen (estimate() returns the text
# "2 hr 15 min" and was passed to a %d), and this is what catches it again.
str_methods = set()
for fn in sorted(os.listdir(src_dir)):
    if fn.endswith('.java'):
        str_methods |= set(re.findall(r'\bString\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(',
                                      open(os.path.join(src_dir, fn)).read()))

bad = []
for fn in sorted(os.listdir(src_dir)):
    if not fn.endswith('.java'):
        continue
    text = open(os.path.join(src_dir, fn)).read()
    # Only getString(...) takes values; R.string.x is often just an argument to
    # something else (setNegativeButton(R.string.cancel, null)), which takes none.
    for m in re.finditer(r'getString\(\s*R\.string\.([a-z_]+)', text):
        name = m.group(1)
        i = m.end()
        if i < len(text) and text[i] != ',':
            continue                      # no values passed
        depth = 1
        j = i
        while j < len(text):
            if text[j] == '(':
                depth += 1
            elif text[j] == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        args = text[i + 1:j]
        parts, level, cur = [], 0, ''
        for ch in args:
            if ch in '([':
                level += 1
            elif ch in ')]':
                level -= 1
            if ch == ',' and level == 0:
                parts.append(cur.strip())
                cur = ''
                continue
            cur += ch
        parts = [q for q in [cur.strip()] + parts if q]
        want = strings.get(name)
        if want is None:
            bad.append('%s: string %s does not exist' % (fn, name))
            continue
        if len(want) != len(parts):
            bad.append('%s: %s takes %d value(s), the app passes %d'
                       % (fn, name, len(want), len(parts)))
            continue
        for kind, arg in zip(want, parts):
            if kind not in 'df':
                continue
            # Text reaching a number placeholder is the failure mode. Locals and
            # arithmetic (min, hrs, hrs / 24, all.size()) are numbers by
            # construction and must not be flagged.
            looks_text = (arg.startswith('"') or arg.startswith("'")
                          or '.toString()' in arg or 'getString(' in arg
                          or 'String.format' in arg)
            for m in str_methods:
                if re.search(r'\b' + re.escape(m) + r'\s*\(', arg):
                    looks_text = True
            if looks_text:
                bad.append('%s: %s wants a number, got text "%s"' % (fn, name, arg))
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY57
check "every placeholder matches what the app passes it" $?
grep -q '<string name="remaining">About %1$s remaining</string>' "$REPO/app/res/values/strings.xml" \
  && grep -q 'R.string.remaining, estimate(' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "the home screen's time-left line is text, and is passed text" $?
grep -q '<string name="setup_title">Super power saving mode</string>' "$REPO/app/res/values/strings.xml"
check "the app's header is the mode's name, not the word Setup" $?
grep -qE '<string name="[a-z_]+">[^<]*v3\.|<string name="[a-z_]+">[^<]*3\.0\.[0-9]' "$REPO/app/res/values/strings.xml"
if [ $? = 0 ]; then bad "no visible text carries a build number"; else ok "no visible text carries a build number"; fi
grep -q 'setContentView(R.layout.activity_home);' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java" \
  && grep -q 'catch (Throwable t) {' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java" \
  && grep -q 'fallbackHome()' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "the home screen falls back to a working one if the layout cannot be shown" $?
grep -q 'updateBatteryText(intent)' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java" \
  && grep -q 'catch (Throwable ignored) {' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "and a bad battery reading cannot take it down either" $?
# The same class of failure, one step earlier: findViewById on a view that no
# layout declares returns null, and the next line throws. Nothing in the build
# notices - a layout can be edited and the code left behind.
python3 - "$REPO" <<'PY57'
import re, sys, os, glob
repo = sys.argv[1]
declared = set()
for f in glob.glob(os.path.join(repo, 'app/res/layout/*.xml')):
    declared |= set(re.findall(r'@\+id/([a-z_0-9]+)', open(f).read()))
bad = []
for f in sorted(glob.glob(os.path.join(repo, 'app/src/dev/axion/spsm/*.java'))):
    for m in re.finditer(r'findViewById\(R\.id\.([a-z_0-9]+)\)', open(f).read()):
        if m.group(1) not in declared:
            bad.append('%s: %s' % (os.path.basename(f), m.group(1)))
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY57
check "every view the app looks for is declared by a layout" $?

say "58. a value that came back is not called unrestored, and a real one is named"
# From the phone's log: "cpu_cap did not return" printed the same values on both
# sides of the sentence, cost 10 seconds of forced safety valves, and told nobody
# anything. The values are now compared the way they are read, and a genuine
# difference says which value and what it holds.
make_tree
cat > "$WORK/verdict58.sh" <<'SH58'
. "$1/scripts/lib.sh"
orig=$(printf 'a\t1\nb\t"two "\nc\t3\n')
# The same values, one carrying a carriage return and a trailing space, as a
# shell command on this phone hands them over.
now=$(printf 'a\t1\nb\t"two "\r\nc\t3\n')
printf 'same: %s\n' "$(revert_verdict "$now" "$orig" "$orig")"
now2=$(printf 'a\t1\nb\t"two "\nc\t9\n')
printf 'diff: %s\n' "$(revert_verdict "$now2" "$orig" "$now2")"
printf 'named: %s\n' "$(drift_list "$now2" "$orig")"
SH58
run_shell "$WORK/verdict58.sh" "$WORK/spsm" > "$WORK/out.v58" 2>&1
grep -q "^same: restored" "$WORK/out.v58"
check "whitespace and carriage returns are not a failed restore ($(head -1 "$WORK/out.v58"))" $?
grep -q "^diff: drift" "$WORK/out.v58"
check "a value that really did not come back is still caught" $?
grep -q "named: c: want \[3\] got \[9\]" "$WORK/out.v58"
check "and the log names the value and both sides ($(grep '^named:' "$WORK/out.v58"))" $?

# Through a real session, the other way round: a value that genuinely cannot be
# written back is a drift, and the log has to say which one and what it holds.
# (A value that somebody else changed is a different verdict on purpose - it is
# left alone, which case 5 covers.)
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap
disable_knobs gov_powersave    # this case is about the ceiling itself
disable_knobs cap_always        # the cap must be lifted on wake for this test
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
NODE="$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
[ "$(cat "$NODE")" = "1100000" ]
check "the cap is on the device after the idle phase" $?
chmod 400 "$NODE"          # readable, no longer writable: the restore fails
screen_on
run_engine screen-on >/dev/null 2>&1
chmod 644 "$NODE"
[ "$(cat "$NODE")" = "1100000" ]
check "the value really did not come back" $?
grep -q "WARN cpu_cap did not return: /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq: want \[1800000\] got \[1100000\]" "$WORK/spsm/spsm.log"
check "and the log names that one value and both sides" $?

say "59. the cap and the phone's power mode are separate things"
# v3.1.0 wrote 0 at exit and the node still read 1 (the phone's own log:
#   WARN cpu_cap did not return: cpufreq_power_mode: want [0] got [1]).
# The cap no longer writes the power mode at all - the power mode has its own
# option (mtk_low_power, case 62). What these checks hold on to is that the cap
# still caps, and that a power mode somebody else set is not the cap's business.
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap
disable_knobs gov_powersave    # this case is about the ceiling itself
disable_knobs mtk_low_power
F="$ROOT/proc/cpufreq/cpufreq_power_mode"
printf 'Default(Normal) mode\n' > "$F"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$F")" = "Default(Normal) mode" ]
check "the cap does not put the phone into Low Power mode" $?
grep -q "cpufreq_power_mode" "$WORK/spsm/journal/cpu_cap.orig"
if [ $? = 0 ]; then bad "and does not journal it either"; else ok "and does not journal it either"; fi
deep_limits_on
check "while the frequency ceiling still applies" $?
screen_on
run_engine deactivate > "$WORK/out.d59" 2>&1
[ "$(cat "$F")" = "Default(Normal) mode" ]
check "and the exit leaves the power mode alone" $?
grep -q "did not return" "$WORK/spsm/spsm.log"
if [ $? = 0 ]; then bad "with no false drift reported"; else ok "with no false drift reported"; fi
grep -q "revert clean" "$WORK/spsm/spsm.log" || grep -q "0 drifted" "$WORK/spsm/spsm.log"
check "so the exit is clean and quick" $?

# A phone already in Low Power mode - the state the user's own battery saver put
# it in - is left exactly as it is: we never set it, so it is not ours to clear.
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap
disable_knobs gov_powersave    # this case is about the ceiling itself
disable_knobs mtk_low_power
F="$ROOT/proc/cpufreq/cpufreq_power_mode"
printf 'Low Power mode\n' > "$F"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >> "$WORK/out.a59" 2>&1
[ "$(cat "$F")" = "Low Power mode" ]
check "a Low Power mode somebody else set survives the cap" $?
screen_on
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$F")" = "Low Power mode" ]
check "and is still there after the mode is off" $?

# The node cannot be read at all. The cap must not care, and must not record it
# as something it changed - that record is what used to make the exit chase a
# value the module never wrote.
make_tree; make_stubs; seed_stub_state
enable_knobs cpu_cap
disable_knobs gov_powersave    # this case is about the ceiling itself
disable_knobs mtk_low_power
F="$ROOT/proc/cpufreq/cpufreq_power_mode"
chmod 000 "$F"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
chmod 644 "$F"
grep -q "cpufreq_power_mode" "$WORK/spsm/journal/cpu_cap.orig"
if [ $? = 0 ]; then bad "an unreadable power mode is not journaled by the cap"; else ok "an unreadable power mode is not journaled by the cap"; fi
deep_limits_on
check "and the cap applies anyway" $?
screen_on
run_engine deactivate >/dev/null 2>&1
grep -q "did not return" "$WORK/spsm/spsm.log"
if [ $? = 0 ]; then bad "with nothing reported that was never ours"; else ok "with nothing reported that was never ours"; fi

say "60. no app stays suspended after an exit, however the slots moved"
# The v3.0.12 log showed the app being added to a slot mid-session, which makes
# the exit take the "somebody else changed this" path for block_other_apps. The
# rule is right; what matters is that nothing is left suspended afterwards.
make_tree; make_stubs; seed_stub_state
printf 'com.whatsapp\ncom.spotify.music\ncom.example.solo\n' > "$WORK/stub/pkgs3"
enable_knobs block_other_apps app_restrict
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
ls "$WORK/stub/pkg"/*.suspended >/dev/null 2>&1
check "apps outside the slots are suspended while the screen is off" $?
# The user adds one of them to the six slots, from the SPSM home screen.
printf 'com.spotify.music\n' > "$WORK/spsm/whitelist.txt"
run_engine allow >/dev/null 2>&1
[ ! -f "$WORK/stub/pkg/com.spotify.music.suspended" ]
check "the app added to a slot is usable at once" $?
screen_on
run_engine deactivate > "$WORK/out.d60" 2>&1
[ -z "$(ls "$WORK/stub/pkg"/*.suspended 2>/dev/null)" ]
check "after the exit, nothing at all is left suspended" $?
[ ! -s "$WORK/spsm/state/blocked_by_us.tsv" ]
check "and the module keeps no record of apps it blocked" $?
run_engine verify > "$WORK/out.v60" 2>&1
grep -q "drift=0" "$WORK/out.v60"
check "with no drift ($(cat "$WORK/out.v60"))" $?
# Suspension by the user is still theirs: we do not release it on the way out.
make_tree; make_stubs; seed_stub_state
printf 'com.example.game\n' > "$WORK/stub/pkgs3"
user_suspends com.example.game
enable_knobs block_other_apps
screen_on
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ -f "$WORK/stub/pkg/com.example.game.suspended" ]
check "an app the user suspended is still suspended after the mode is off" $?

say "61. SPSM's recents reads the phone's task list and switches without the launcher"
# The dump below is the phone's own output (narzo 50A, Android 16, AxionOS).
# Reading it is what lets SPSM show recents without starting the Pulse launcher,
# whose RecentsActivity is itself one of the tasks in the list.
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
run_engine recents > "$WORK/out.r61" 2>&1
[ "$(wc -l < "$WORK/out.r61")" = "2" ]
check "only the apps worth switching to are listed ($(tr '\n' ' ' < "$WORK/out.r61"))" $?
grep -q "^1455	com.termux	com.termux/.app.TermuxActivity	725551$" "$WORK/out.r61"
check "the newest task is read with its id, package and activity" $?
grep -q "^1454	com.openai.chatgpt" "$WORK/out.r61"
check "and the one after it" $?
grep -q "dev.axion.spsm" "$WORK/out.r61"
if [ $? = 0 ]; then bad "the SPSM home is not offered as somewhere to switch to"; else ok "the SPSM home is not offered as somewhere to switch to"; fi
grep -q "RecentsActivity" "$WORK/out.r61"
if [ $? = 0 ]; then bad "and the launcher's recents task is not listed either"; else ok "and the launcher's recents task is not listed either"; fi

run_engine recents-switch 1455 > "$WORK/out.sw61" 2>&1
[ "$(cat "$WORK/stub/task_in_front")" = "1455" ]
check "switching moves that task to the front" $?
grep -q "am task move-to-front 1455" "$WORK/stub/calls" || grep -q "move-to-front 1455" "$WORK/stub/calls"
check "through the system, not by starting the launcher" $?
run_engine recents-remove 1454 >/dev/null 2>&1
grep -q "^1454$" "$WORK/stub/tasks_removed"
check "closing a task closes that task" $?
# Nothing that comes from the screen may become shell syntax.
run_engine recents-switch '1455; reboot' > "$WORK/out.bad61" 2>&1
grep -q "not a task id" "$WORK/out.bad61"
check "a task id that is not a number is refused" $?
run_engine recents-switch 1455 'com.termux/.app.TermuxActivity; rm -rf /' > "$WORK/out.bad61b" 2>&1
[ ! -f "$WORK/stub/task_restarted_bad" ] && [ -f "$WORK/stub/task_in_front" ]
check "and a component that is not a component name is refused" $?
# The close the owner reported as doing nothing: `am task remove` reports
# success, the task stays, and the screen reloads it as if nothing was asked.
# The removal is verified against the phone's own list now, and the fallback is
# what actually closes it.
run_engine recents > "$WORK/out.r61c" 2>&1
grep -q "^1454" "$WORK/out.r61c"
if [ $? = 0 ]; then bad "a closed task is really gone from the list"; else ok "a closed task is really gone from the list"; fi
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
touch "$WORK/stub/task_remove_broken"        # the command exists and does nothing
run_engine recents-remove 1455 com.termux > "$WORK/out.rm61" 2>&1
grep -q "^com.termux$" "$WORK/stub/force_stopped"
check "when removing the task does nothing, the app is closed instead" $?
grep -q "closed by stopping com.termux" "$WORK/spsm/spsm.log"
check "and the log says which route closed it" $?
run_engine recents > "$WORK/out.r61d" 2>&1
grep -q "^1455" "$WORK/out.r61d"
if [ $? = 0 ]; then bad "and the task is gone from the list afterwards"; else ok "and the task is gone from the list afterwards"; fi
# A phone where neither works: said plainly, never pretended.
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
touch "$WORK/stub/task_remove_broken" "$WORK/stub/force_stop_broken"
run_engine recents-remove 1455 com.termux > "$WORK/out.rm61b" 2>&1
grep -q "could not close task 1455" "$WORK/spsm/spsm.log"
check "a task that will not close at all is reported, not claimed as closed" $?
run_engine recents > "$WORK/out.r61e" 2>&1
grep -q "^1455" "$WORK/out.r61e"
check "and the task is still listed, so the screen tells the truth" $?
# Switching: same rule. A move-to-front that lies falls back to starting the
# task's activity, and that is verified too.
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
touch "$WORK/stub/task_move_broken"
run_engine recents-switch 1454 com.openai.chatgpt/.MainActivity > "$WORK/out.sw61b" 2>&1
[ "$(run_engine recents | head -1 | cut -f1)" = "1454" ]
check "a switch is verified, and falls back when the first way does nothing" $?
grep -q "restarted by component" "$WORK/spsm/spsm.log"
check "and the log names the way that worked" $?
# A ROM that prints something unexpected must yield nothing, not nonsense.
printf 'no tasks here\n' > "$WORK/stub/recents.dump"
run_engine recents > "$WORK/out.r61b" 2>&1
[ ! -s "$WORK/out.r61b" ]
check "an unexpected dump yields an empty list rather than rubbish" $?

say "62. the phone's Low Power mode: entered on request, left on exit, verified"
# The phone measured this itself: writing 1 reads "Low Power mode", writing 0
# reads "Default(Normal) mode" about a second later. The exit used to read the
# node too soon and report a change that had in fact worked.
make_tree; make_stubs; seed_stub_state
enable_knobs mtk_low_power
F="$ROOT/proc/cpufreq/cpufreq_power_mode"
printf 'Default(Normal) mode\n' > "$F"
screen_on
run_engine activate > "$WORK/out.a62" 2>&1
grep -q "cpu low power mode engaged" "$WORK/spsm/spsm.log"
check "turning the mode on engages Low Power mode while the screen is still on" $?
screen_off
run_engine screen-off >> "$WORK/out.a62" 2>&1
run_engine deactivate > "$WORK/out.d62" 2>&1
grep -q "cpu low power mode released to its original state" "$WORK/spsm/spsm.log"
check "and the exit releases it, on the record" $?
grep -q "did not accept leaving" "$WORK/spsm/spsm.log"
if [ $? = 0 ]; then bad "without calling a change that worked unrestored"; else ok "without calling a change that worked unrestored"; fi
grep -q "revert clean" "$WORK/spsm/spsm.log"
check "so the exit is clean and quick, with no safety pass" $?
# The reverse of the same claim: the governor the deep phase writes back must be
# there, and the power mode must be off. Whichever order they ran in, both are
# true now - so a change that made one undefine the other would be caught.
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" = "schedutil" ]
check "the processor is back on its normal governor" $?
[ "$(cat "$F")" = "0" ]
check "and out of Low Power mode" $?
# Released FIRST, before the deep phase writes the governor back. While Low
# Power mode is on this kernel owns the governor and puts powersave straight
# back over a schedutil write, which is the phantom drift and the 41-second exit
# in the v3.1.0 log. knobs_reversed would reach it last, so the call has to come
# before phase_deep_revert - and that is a property of the source.
awk '/^do_deactivate\(\)/,/^}/' module/scripts/engine.sh > "$WORK/da62.sh"
_a=$(grep -n "knob_revert mtk_low_power" "$WORK/da62.sh" | head -1 | cut -d: -f1)
_b=$(grep -n "phase_deep_revert" "$WORK/da62.sh" | head -1 | cut -d: -f1)
[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ]
check "and is released before the deep reverts touch the processors (lines $_a and $_b)" $?

# A phone that was already in Low Power mode by its owner's choice gets it back.
make_tree; make_stubs; seed_stub_state
enable_knobs mtk_low_power
printf 'Low Power mode\n' > "$ROOT/proc/cpufreq/cpufreq_power_mode"
screen_on
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "1" ]
check "a phone already in Low Power mode is still in it after the mode is off" $?

# The option can be switched off on its own, and then nothing is touched.
make_tree; make_stubs; seed_stub_state
disable_knobs mtk_low_power cpu_cap
printf 'Default(Normal) mode\n' > "$ROOT/proc/cpufreq/cpufreq_power_mode"
screen_on
run_engine activate >/dev/null 2>&1
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "Default(Normal) mode" ]
check "with the option off, the power mode is not touched at all" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "Default(Normal) mode" ]
check "on exit as well" $?

# A state we do not recognise is never written, and never lands in the journal as
# something we will later try to put back.
make_tree; make_stubs; seed_stub_state
enable_knobs mtk_low_power
printf 'Sports mode\n' > "$ROOT/proc/cpufreq/cpufreq_power_mode"
screen_on
run_engine activate >/dev/null 2>&1
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "Sports mode" ]
check "an unknown power state is left exactly as it was" $?
grep -q "does not read as a state we can put back" "$WORK/spsm/spsm.log"
check "and the log says why" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "Sports mode" ]
check "and the exit does not invent a value for it" $?
grep -q "did not return" "$WORK/spsm/spsm.log"
if [ $? = 0 ]; then bad "and does not report it as a change we failed to undo"; else ok "and does not report it as a change we failed to undo"; fi

# A phone that will not enter Low Power mode is left alone, told so plainly, and
# the exit is still clean: nothing was changed, so nothing has to come back.
make_tree; make_stubs; seed_stub_state
enable_knobs mtk_low_power
F="$ROOT/proc/cpufreq/cpufreq_power_mode"
printf 'Default(Normal) mode\n' > "$F"
chmod 400 "$F"                       # readable, as the phone is; not writable
screen_on
run_engine activate >/dev/null 2>&1
grep -q "did not accept Low Power mode; leaving it as it is" "$WORK/spsm/spsm.log"
check "a phone that refuses Low Power mode is told so, not forced" $?
[ "$(cat "$F")" = "Default(Normal) mode" ]
check "and its state is untouched" $?
chmod 644 "$F"
run_engine deactivate > "$WORK/out.d62b" 2>&1
grep -q "revert clean" "$WORK/spsm/spsm.log"
check "and the exit is clean" $?

say "63. window blur off, and back on again"
make_tree; make_stubs; seed_stub_state
enable_knobs blur_off
screen_on
run_engine activate >/dev/null 2>&1
[ -f "$WORK/stub/settings/global.disable_window_blurs" ]
check "turning the mode on disables window blur" $?
[ "$(cat "$WORK/stub/settings/global.disable_window_blurs")" = "1" ]
check "with the value the framework reads" $?
run_engine deactivate > "$WORK/out.d63" 2>&1
# It was not set before we touched it, so "back" means gone, not zero.
[ ! -e "$WORK/stub/settings/global.disable_window_blurs" ]
check "and the exit removes it, because it was not there before" $?
run_engine verify > "$WORK/out.v63" 2>&1
grep -q "drift=0" "$WORK/out.v63"
check "with nothing left behind ($(cat "$WORK/out.v63"))" $?

# And a value the user had set themselves comes back as itself.
make_tree; make_stubs; seed_stub_state
enable_knobs blur_off
echo 0 > "$WORK/stub/settings/global.disable_window_blurs"
screen_on
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/global.disable_window_blurs")" = "0" ]
check "a blur setting the user already had is put back as it was" $?

say "64. every option in the list is complete, reversible and described"
# The audit for "no bugs left": an option that is offered to the user but has no
# snapshot, apply or restore function is a promise the module cannot keep. This
# walks the list the app shows and checks each one end to end.
make_tree; make_stubs; seed_stub_state
run_engine dump-knobs > "$WORK/out.knobs64" 2>&1
grep -c "^" "$WORK/out.knobs64" >/dev/null
cat > "$WORK/audit64.sh" <<'SH64'
. "$1/scripts/lib.sh"
. "$1/scripts/knobs.sh"
for k in $(knobs_all); do
  for fn in "meta_$k" "snapshot_$k" "apply_$k" "restore_$k"; do
    if ! type "$fn" >/dev/null 2>&1; then
      echo "MISSING $fn"
    fi
  done
  echo "$k|$(knob_meta "$k" | awk -F'|' 'NF!=6{print "BADMETA"}')"
done
SH64
run_shell "$WORK/audit64.sh" "$WORK/spsm" > "$WORK/out.a64" 2>&1
grep -q "MISSING" "$WORK/out.a64"
if [ $? = 0 ]; then bad "every option has all its functions ($(grep MISSING "$WORK/out.a64" | head -3 | tr '\n' ' '))"; else ok "every option has its snapshot, apply and restore functions"; fi
grep -q "BADMETA" "$WORK/out.a64"
if [ $? = 0 ]; then bad "every option's description has exactly six fields"; else ok "every option's description has exactly six fields"; fi

# And the same list, end to end on the device: every option applied on its own,
# then the whole device compared field by field with how it started.
make_tree; make_stubs; seed_stub_state
screen_on
dump_state "$WORK/before64"
for k in $(sh -c '. '"$WORK/spsm"'/scripts/lib.sh; . '"$WORK/spsm"'/scripts/knobs.sh; knobs_all'); do
  enable_knobs "$k"
done
screen_on
run_engine activate > "$WORK/out.a64b" 2>&1
screen_off
run_engine screen-off >> "$WORK/out.a64b" 2>&1
run_engine deactivate > "$WORK/out.d64b" 2>&1
screen_on            # the comparison starts from a phone that was on, so end there
dump_state "$WORK/after64"
cmp -s "$WORK/before64" "$WORK/after64"
_rc=$?
[ "$_rc" = "0" ] || { echo "--- what did not come back:"; diff "$WORK/before64" "$WORK/after64" | head -10; }
check "with every option on at once, the device still comes back byte for byte" $_rc
run_engine verify > "$WORK/out.v64" 2>&1
grep -q "drift=0" "$WORK/out.v64"
check "and the module agrees nothing is left ($(cat "$WORK/out.v64"))" $?
_left=$(grep -rl '^disabled' "$WORK/stub/component" 2>/dev/null | grep -v dev.axion.spsm | head -3 | tr '\n' ' ')
[ -z "$_left" ]
check "and no component we switched off is still switched off ($_left)" $?
say "65. the mode is at its strongest while you are using the phone, by default"
# What the owner asked for, and what the shipped defaults now are: the caps held
# while the phone is in use, the processor in its own Low Power mode, and blur
# off - each one still switchable off on its own.
make_tree; make_stubs; seed_stub_state
for k in cpu_cap gpu_cap deep_doze mtk_low_power blur_off; do enable_knobs "$k"; done
screen_on
run_engine activate >/dev/null 2>&1
deep_limits_on
check "the shipped defaults cap the processor while the screen is on" $?
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "1" ]
check "and the processor is in Low Power mode while the screen is on" $?
[ "$(cat "$WORK/stub/settings/global.disable_window_blurs")" = "1" ]
check "and window blur is off" $?
[ ! -f "$WORK/stub/doze_forced" ]
check "while deep sleep is still only for the screen being off" $?
run_engine deactivate > "$WORK/out.d66" 2>&1
deep_limits_off
check "and the exit lifts all of it" $?
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "0" ]
check "including the processor's power mode" $?
run_engine verify > "$WORK/out.v66" 2>&1
grep -q "drift=0" "$WORK/out.v66"
check "with nothing left behind ($(cat "$WORK/out.v66"))" $?

# Each of the three can still be switched off on its own, which is what makes
# them options rather than surprises.
make_tree; make_stubs; seed_stub_state
for k in cpu_cap gpu_cap deep_doze; do enable_knobs "$k"; done
disable_knobs cap_always
screen_on
run_engine activate >/dev/null 2>&1
deep_limits_off
check "switching the in-use limits off leaves the phone at full speed in use" $?
run_engine deactivate >/dev/null 2>&1
make_tree; make_stubs; seed_stub_state
disable_knobs mtk_low_power
screen_on
run_engine activate >/dev/null 2>&1
[ "$(cat "$ROOT/proc/cpufreq/cpufreq_power_mode")" = "0" ]
check "and switching the power mode off leaves the processor alone" $?
run_engine deactivate >/dev/null 2>&1
make_tree; make_stubs; seed_stub_state
disable_knobs blur_off
screen_on
run_engine activate >/dev/null 2>&1
[ ! -e "$WORK/stub/settings/global.disable_window_blurs" ]
check "and switching blur off leaves the interface as it is" $?
run_engine deactivate >/dev/null 2>&1

say "66. the status bar is never hidden by this mode, and an immersive rule is cleared"
# The phone report: the status bar disappeared a second or two after every swipe
# from the top. The cause was in the mode's own resources - the home screen's
# theme asked for full screen (android:windowFullscreen), which is FLAG_FULLSCREEN
# - so that the bar comes back, hides again, and looks like the ROM fighting the
# user. Both halves of the fix are checked here: nothing in the app asks for full
# screen, and a system-wide immersive rule is cleared while the mode is on.
grep -q 'name="android:windowFullscreen"' "$REPO/app/res/values/styles.xml"
if [ $? = 0 ]; then bad "no screen in this app asks to be full screen"; else ok "no screen in this app asks to be full screen"; fi
if grep -rq "SYSTEM_UI_FLAG_FULLSCREEN\\|FLAG_FULLSCREEN\\|hide(WindowInsets" app/ --include=*.java --include=*.xml; then
  bad "nothing in the app hides the status bar"
else
  ok "nothing in the app hides the status bar"
fi
grep -q "Type.statusBars" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "and the home screen asks for the bars to be shown" $?
# The way into recents is three buttons now, not a swipe. On the owner's report
# from the phone the swipe was removed outright: v3.5.1 logged the swipe
# arriving and the list still did not come up, because on a gesture-navigation
# phone Android takes the bottom edge for its own "go home" mid-swipe. Nothing
# may be left of it - no touch reader, no swipe strings - and the three buttons
# have to be wired on both of this mode's screens.
if grep -q "dispatchTouchEvent\|ACTION_MOVE\|touchStartY\|swipeFired" \
     "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"; then
  bad "the swipe is gone from the home screen"
else
  ok "the swipe is gone from the home screen"
fi
if grep -rq 'name="swipe_up_recents"\|name="swipe_for_recents"\|R.string.swipe' "$REPO/app/res" "$REPO/app/src"; then
  bad "and the hint that taught it is gone too"
else
  ok "and the hint that taught it is gone too"
fi
# The owner's correction: "i didn't told you to implement a custom three button
# navigation bar, i mean i want system own 3-button navigation bar. Also you
# custom three button navigation bar is too buggy, so remove it completely and
# then just add system one". So there must be no bar drawn by this app at all -
# no layout, no class, no icons, not even the strings - and what replaces it is
# the phone's own bar, switched by the phone's own mechanism.
if grep -rq "nav_bar\|NavBar\|nav_back\|nav_home\|nav_recents" "$REPO/app/res" "$REPO/app/src"; then
  bad "this app draws no navigation bar of its own"
else
  ok "this app draws no navigation bar of its own"
fi
if [ -e "$REPO/app/res/layout/nav_bar.xml" ] || [ -e "$REPO/app/src/dev/axion/spsm/NavBar.java" ]; then
  bad "and the buggy bar's own files are gone"
else
  ok "and the buggy bar's own files are gone"
fi
# The owner's constraint, verbatim: "DO NOT intercept KEYCODE_APP_SWITCH" - the
# system's own Recents pipeline belongs to Quickstep, and this app touches
# nothing of it. The key handler that used to consume the key is gone.
if grep -q "KEYCODE_APP_SWITCH" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"; then
  bad "the app still intercepts APP_SWITCH"
else
  ok "the app intercepts no APP_SWITCH key - Quickstep's pipeline is untouched"
fi
# The Quick Settings tile is a real toggle now: tap switches the mode on or
# off in place - it never opens the app - and long-press opens the options.
grep -q "Root.enter()" "$REPO/app/src/dev/axion/spsm/SpsmTileService.java" && \
  grep -q "Root.exit()" "$REPO/app/src/dev/axion/spsm/SpsmTileService.java"
check "the tile toggles the mode itself, with the same scripts as the door" $?
if grep -q "startActivityAndCollapse" "$REPO/app/src/dev/axion/spsm/SpsmTileService.java"; then
  bad "tapping the tile opens no activity"
else
  ok "tapping the tile opens no activity"
fi
grep -q "android.service.quicksettings.action.QS_TILE_PREFERENCES" "$REPO/app/AndroidManifest.xml" && \
  grep -q ".KnobsActivity" "$REPO/app/AndroidManifest.xml"
check "and long-pressing the tile opens this mode's options" $?
grep -q ">Super power saving mode<" "$REPO/app/res/values/strings.xml"
check "and the tile says the mode's whole name" $?
grep -q 'engine.sh recents-opened' "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java" && \
  grep -q 'recents-opened)' "$REPO/module/scripts/engine.sh"
check "and every open of the list is noted in the log, with what opened it" $?
for _cb in onPause onStop onDestroy; do
  awk "/protected void $_cb\\(\\)/,/^    }/" "$REPO/app/src/dev/axion/spsm/SpsmRecentsActivity.java" | grep -q "visible = false"
  check "the flag that guards the list is cleared in $_cb" $?
done
grep -q "protected void onNewIntent" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java" && \
  grep -q "SpsmRecentsActivity.visible" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "and being sent home from inside an app opens the same list, without bouncing" $?
if grep -q "setOnLongClickListener" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"; then
  bad "the long press on the empty space is gone"
else
  ok "the long press on the empty space is gone"
fi
grep -q 'name="home_hint_hold">Hold an app to change it<' "$REPO/app/res/values/strings.xml"
check "and the hint on the home screen says what it really does" $?
grep -q '@+id/btn_home' "$REPO/app/res/layout/activity_recents.xml" && \
  grep -q "R.id.btn_home" "$REPO/app/src/dev/axion/spsm/SpsmRecentsActivity.java"
check "with a way back to the six apps from the list itself" $?
# Clear all, on the owner's instruction: everything the list is showing is closed
# at once, and the frozen background with it.
grep -q '@+id/btn_clear_all' "$REPO/app/res/layout/activity_recents.xml" && \
  grep -q "R.id.btn_clear_all" "$REPO/app/src/dev/axion/spsm/SpsmRecentsActivity.java" && \
  grep -q 'engine.sh clear-all' "$REPO/app/src/dev/axion/spsm/SpsmRecentsActivity.java"
check "the recents screen has a Clear all button, and it runs the real thing" $?

# The switch is gone. The option is not offered in the app's list, and even a
# stored "off" from the old build cannot turn the behaviour off: the status bar
# is kept visible because the mode is on.
run_engine dump-knobs >/dev/null 2>&1
if grep -q "^statusbar_on|" "$WORK/spsm/knobs.list" 2>/dev/null; then
  bad "the option list no longer offers the status bar switch"
else
  ok "the option list no longer offers the status bar switch"
fi
make_tree; make_stubs; seed_stub_state
echo "knob.statusbar_on=0" >> "$WORK/spsm/config"
printf '%s' 'immersive.full=*' > "$WORK/stub/settings/global.policy_control"
screen_on
run_engine activate >/dev/null 2>&1
[ ! -e "$WORK/stub/settings/global.policy_control" ]
check "an immersive rule that hid the status bar is cleared while the mode is on" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/global.policy_control" 2>/dev/null)" = "immersive.full=*" ]
check "and the rule is put back exactly as it was on exit" $?
run_engine verify > "$WORK/out.v65" 2>&1
grep -q "drift=0" "$WORK/out.v65"
check "with nothing left behind ($(cat "$WORK/out.v65"))" $?

# A phone with no such rule: nothing is invented, and nothing is written.
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
[ ! -e "$WORK/stub/settings/global.policy_control" ]
check "a phone with no immersive rule is not given one" $?
grep -q "note statusbar_on: this ROM hides no bar with a policy rule" "$WORK/spsm/spsm.log"
check "and the log says plainly that there was nothing to clear" $?
run_engine deactivate > "$WORK/out.d65" 2>&1
grep -q "revert clean" "$WORK/spsm/spsm.log"
check "and the exit is clean" $?

say "67. the power-saving home looks like a phone's own super power saving mode"
# The redesign, checked as properties of the files rather than as a memory of
# what was asked for: no yellow, no state pill, the clock still the biggest thing
# on the screen and the date under it, a 3x2 grid of large rounded containers, a
# plus in the empty ones, the battery near the bottom, a pencil that takes apps
# out, and an exit sheet with a red Exit. Each of these has been reported broken
# once already, in another form.
HOME="$REPO/app/res/layout/activity_home.xml"
SLOT="$REPO/app/res/layout/item_app_slot.xml"
ACT="$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
[ -f "$REPO/app/res/layout/dialog_exit.xml" ]
check "the exit is its own sheet, not a platform alert" $?
grep -q 'name="android:windowFullscreen"' "$HOME"
if [ $? = 0 ]; then bad "the home does not ask to be full screen (the status bar stays)"; else ok "the home does not ask to be full screen (the status bar stays)"; fi
grep -q "chip_mode" "$HOME"
if [ $? = 0 ]; then bad "the yellow state pill is gone"; else ok "the yellow state pill is gone"; fi
grep -q "@color/accent" "$HOME"
if [ $? = 0 ]; then bad "and nothing on it is coloured yellow (white and greys only)"; else ok "and nothing on it is coloured yellow (white and greys only)"; fi
# The clock: the largest text on the screen, kept exactly as it was. The date
# that used to sit under it is gone - the owner asked for the percentage and the
# date to go, and for the apps to come down to where they are now.
_clock=$(sed -n '/@+id\/clock/,/\/>/p' "$HOME" | sed -n 's/.*textSize="\([0-9]*\)sp".*/\1/p')
[ -n "$_clock" ] && [ "$_clock" -ge 60 ]
check "the large centred clock is still the largest thing on the screen (${_clock}sp)" $?
if grep -q '@+id/date' "$HOME"; then bad "the date line under the clock is gone"; else ok "and nothing was added under it"; fi
# The grid: six slots, three to a row, in large rounded containers.
[ "$(grep -c 'layout="@layout/item_app_slot"' "$HOME")" = "6" ]
check "the six apps are a grid of six slots" $?
[ "$(grep -c 'android:radius="22dp"' "$SLOT" 2>/dev/null)" = "0" ]
check "the container's rounding comes from the drawable, not the layout" $?
grep -q 'android:radius="22dp"' "$REPO/app/res/drawable/bg_slot.xml"
check "and that drawable is a large rounded dark container (22dp radius)" $?
grep -q 'android:layout_width="68dp"' "$SLOT"
check "the container is large (68dp)" $?
grep -q 'android:src="@drawable/ic_plus_thin"' "$SLOT"
check "an empty slot shows the thin plus" $?
grep -q 'android:text="@string/empty_slot"' "$SLOT"
check "with the word Add under it" $?
grep -q '@+id/badge' "$SLOT"
check "and a slot with an app in it can show an edit badge" $?
# No percentage anywhere on the screen, and the apps sit just above the time
# they have left - the owner's two layout instructions, checked as layout order.
if grep -q '@+id/battery' "$HOME"; then bad "the battery percentage is gone from the screen"; else ok "the battery percentage is gone from the screen"; fi
if grep -q 'R.id.battery' "$ACT"; then bad "and no code asks for it any more"; else ok "and no code asks for it any more"; fi
_r=$(grep -n '@+id/remaining' "$HOME" | head -1 | cut -d: -f1)
_g=$(grep -n '@layout/item_app_slot' "$HOME" | tail -1 | cut -d: -f1)
_s=$(grep -n 'layout_weight="1"' "$HOME" | head -1 | cut -d: -f1)
[ -n "$_r" ] && [ -n "$_g" ] && [ -n "$_s" ] && [ "$_s" -lt "$_g" ] && [ "$_g" -lt "$_r" ]
check "the six apps sit just above the time left, at the bottom (spacer line $_s, grid $_g, time $_r)" $?
grep -q "R.string.remaining, estimate(pct)" "$ACT"
check "and the estimate is still the thing that is shown" $?
# Two controls, and that they are wired to something. The Recents button is gone
# on the owner's instruction: the way in is the upward swipe, and the list itself
# has the way back to the apps.
for id in btn_exit btn_edit; do
  grep -q "@+id/$id" "$HOME" || bad "the home still has $id"
  grep -q "R.id.$id" "$ACT" || bad "$id is bound in the home screen's code"
done
ok "Exit and Edit are on the screen and bound in code"
if grep -q '@+id/btn_recents' "$HOME"; then bad "the recents button is gone"; else ok "the recents button is gone"; fi
if grep -q 'R.id.btn_recents' "$ACT"; then bad "and nothing binds it"; else ok "and nothing binds it"; fi
grep -q "R.drawable.ic_edit" "$ACT" && grep -q "R.drawable.ic_check" "$ACT"
check "the pencil turns into a tick while the slots are being edited" $?
grep -q 'Prefs.setSlot(SpsmHomeActivity.this, idx, "")' "$ACT"
check "a tap while editing takes that app out of its slot" $?
grep -q "Apps.launch(SpsmHomeActivity.this, pkg)" "$ACT"
check "and a tap outside editing still opens the app" $?
grep -q "AppPickerActivity.open" "$ACT"
check "and the app chooser still opens from a slot" $?
grep -q "estimate(pct)" "$ACT" && grep -q "R.string.remaining, estimate(pct)" "$ACT"
check "the battery estimate is untouched" $?
grep -q "AppPickerActivity" "$REPO/app/src/dev/axion/spsm/AppPickerActivity.java" && \
  grep -q "Apps.launchable" "$REPO/app/src/dev/axion/spsm/AppPickerActivity.java"
check "and the picker still lists every installed app" $?
# The exit sheet: dark, rounded, from the bottom, with a red Exit.
grep -q 'android:background="@drawable/bg_sheet"' "$REPO/app/res/layout/dialog_exit.xml"
check "the sheet is the dark rounded one" $?
grep -q 'android:background="@drawable/bg_pill_danger"' "$REPO/app/res/layout/dialog_exit.xml"
check "with the red Exit button" $?
grep -q "Gravity.BOTTOM" "$ACT"
check "and it comes up from the bottom edge" $?
grep -q "setTitle(R.string.exit_title)" "$ACT" && grep -q "doExit()" "$ACT"
check "while the plain dialog is still the fallback underneath it" $?

say "68. no screen of this app can be opened into a crash"
# The owner reported, from the phone: opening the app threw
#   java.lang.ClassCastException: android.widget.FrameLayout cannot be cast to
#   android.widget.LinearLayout   at SetupActivity.bindSlots(SetupActivity.java:79)
# The slot layout's root changed from LinearLayout to FrameLayout (so a slot could
# carry its edit badge) and two activities went on casting those slots. It
# compiled, and no test of the scripts could see it. This case is the net that
# catches that whole family of bug, and it proves the net works.
if command -v python3 >/dev/null 2>&1; then
  python3 "$REPO/tests/audit-ids.py" > "$WORK/out.audit69" 2>&1
  check "every view lookup matches the layout it comes from ($(tail -1 "$WORK/out.audit69"))" $?
  grep -q "no view is held as something its layout is not" "$WORK/out.audit69"
  check "and the audit read the app rather than guessing" $?

  # The audit is only worth having if it fails on the bug it was written for:
  # put the cast back into a copy of the tree and demand that it is caught.
  rm -rf "$WORK/app69"; mkdir -p "$WORK/app69"
  cp -r "$REPO/app" "$WORK/app69/app"
  ls "$WORK/app69/app/src/dev/axion/spsm" >/dev/null 2>&1 || bad "the copy of the app tree was made"
  sed -i 's/View slot = findViewById(slotIds\[i\]);/LinearLayout slot = findViewById(slotIds[i]);/' \
      "$WORK/app69/app/src/dev/axion/spsm/SetupActivity.java"
  grep -q "LinearLayout slot = findViewById(slotIds\[i\])" "$WORK/app69/app/src/dev/axion/spsm/SetupActivity.java"
  check "the copy has the crash that shipped put back into it" $?
  python3 "$REPO/tests/audit-ids.py" "$WORK/app69" > "$WORK/out.audit69b" 2>&1
  [ $? != 0 ]
  check "and the audit refuses it" $?
  grep -q "WRONG-TYPE" "$WORK/out.audit69b"
  check "naming the type it found instead ($(grep -m1 WRONG-TYPE "$WORK/out.audit69b" | cut -c1-90)…)" $?
  grep -q "SetupActivity.java" "$WORK/out.audit69b"
  check "and the file and line to look at" $?

  # The build stops on it too, so a broken app cannot be packaged again.
  grep -q "audit-ids.py" "$REPO/build.sh"
  check "the build runs the same audit and stops on it" $?
else
  ok "python3 is not installed here: the audit was skipped (the build does run it)"
fi

  # And the APK, not just the source: this reads the dex of the built APK and
  # demands the fixed method is in it and the broken one is not.
  grep -q "dexcheck.py" "$REPO/build.sh"
  check "the build also checks the APK it is about to stage" $?
  if [ -f "$REPO/build/AxionSPSM.apk" ]; then
    python3 "$REPO/tools/dexcheck.py" "$REPO/build/AxionSPSM.apk" \
      "Ldev/axion/spsm/Apps;->bindSlot(Landroid/content/Context;Landroid/view/View;ILdev/axion/spsm/Apps\$SlotClick;)V" \
      > "$WORK/out.dex69" 2>&1
    check "the built APK carries the fixed slot method ($(tail -1 "$WORK/out.dex69"))" $?
    python3 "$REPO/tools/dexcheck.py" "$REPO/build/AxionSPSM.apk" \
      "Ldev/axion/spsm/Apps;->bindSlot(Landroid/content/Context;Landroid/widget/LinearLayout;ILdev/axion/spsm/Apps\$SlotClick;)V" \
      >/dev/null 2>&1 && bad "the built APK still carries the method that crashed"
    ok "and not the one that crashed"
  else
    ok "no built APK here to read (the build checks it before every release)"
  fi

# The two screens that can be opened blind must not die on a view problem: the
# app's own switch is worth more than a row of icons.
grep -q "try {" "$REPO/app/src/dev/axion/spsm/SetupActivity.java" && \
  grep -q "} catch (Throwable ignored)" "$REPO/app/src/dev/axion/spsm/SetupActivity.java"
check "opening the app cannot be taken down by a slot" $?
grep -q "if (slot == null) return;" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "the home screen skips a missing slot rather than throwing over it" $?
# In this mode this activity IS the phone's home, so the slots are bound one at
# a time and a failure in one of them is skipped: five icons beat no home.
grep -q "private void bindSlot(final int i) {" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java" && \
  grep -q "^                bindSlot(i);" "$REPO/app/src/dev/axion/spsm/SpsmHomeActivity.java"
check "and each of its six slots is bound on its own, so one cannot take the home down" $?
grep -q "static void bindSlot(final Context c, View slot" "$REPO/app/src/dev/axion/spsm/Apps.java"
check "and nothing anywhere holds a slot as a specific widget" $?

say "69. the power-save governor: the idle frequency is the kernel's job again"
# The owner's instruction: "if you change the governor to powersave then no need
# to change frequency of cpu cores which may reduce time, because its managed by
# the powersave governor". With the option on - the shipped default - the governor
# is set and the ceiling is deliberately NOT written; with it off the ceiling is
# written exactly as every older case in this file assumes.
make_tree; make_stubs; seed_stub_state
disable_knobs cap_always        # so any ceiling can only have come from the deep phase
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
GOV="$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
[ "$(cat "$GOV")" = "powersave" ]
check "the kernel's power-save governor is put in charge while the screen is off" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1800000" ]
check "and no frequency ceiling is written on top of it" $?
grep -q "governor: power-save on 2 of 2 cluster(s)" "$WORK/spsm/spsm.log"
check "with the log saying how many clusters took it" $?
grep -q "cpu_cap: the power-save governor holds the frequency - no ceiling written" "$WORK/spsm/spsm.log"
check "and the ceiling step saying why it did nothing" $?
run_engine status > "$WORK/out.g70" 2>&1
grep -q "held_by=governor" "$WORK/out.g70"
check "and the idle report naming the governor as what holds the frequency" $?
screen_on
run_engine screen-on >/dev/null 2>&1
[ "$(cat "$GOV")" = "schedutil" ]
check "waking puts the governor back" $?
run_engine verify > "$WORK/out.g70b" 2>&1
grep -q "drift=0" "$WORK/out.g70b"
check "with nothing left behind ($(cat "$WORK/out.g70b"))" $?
run_engine deactivate >/dev/null 2>&1

# The same tree with the option off: the ceiling is written by hand and the
# governor is left as the phone had it. This is the mechanism the rest of the
# suite tests, so it has to stay working.
make_tree; make_stubs; seed_stub_state
disable_knobs gov_powersave
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$GOV")" = "schedutil" ]
check "with the option off the governor is left alone" $?
[ "$(cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" = "1100000" ]
check "and the ceiling is written by hand as before" $?
run_engine status > "$WORK/out.g70d" 2>&1
grep -q "held_by=ceiling" "$WORK/out.g70d"
check "and the idle report says the ceiling is what holds the frequency" $?
run_engine screen-on >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1

# A phone that refuses the write. The change must be recorded as one that was
# not made, so the exit does not go looking for a governor this phone never took.
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
# Every cluster, not just the first: while one governor write succeeds the module
# is right to call the change made, and this case is about the phone that refuses
# all of them.
chmod 400 "$GOV" "$ROOT/sys/devices/system/cpu/cpufreq/policy6/scaling_governor"
screen_off
run_engine screen-off >/dev/null 2>&1
chmod 644 "$GOV" "$ROOT/sys/devices/system/cpu/cpufreq/policy6/scaling_governor"
grep -q "governor: this phone did not accept the power-save governor" "$WORK/spsm/spsm.log"
check "a phone that refuses the governor says so in the log" $?
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.g70c" 2>&1
grep -q "drift=0" "$WORK/out.g70c"
check "and nothing of ours is left to chase at the exit ($(cat "$WORK/out.g70c"))" $?

say "70. a second screen-off in the same idle period does not redo the long work"
# From the v3.4.1 log, verbatim: "slow: apply app_restrict took 86s" in one
# screen-off and "slow: apply deep_doze took 619s" in another - in every period,
# for a state the phone was already in. Those two are applied once per idle
# period now: neither can undo itself while the phone sleeps, and the report that
# this is judged by is cleared on wake, so a real wake re-applies both.
make_tree; make_stubs; seed_stub_state
enable_knobs app_restrict deep_doze
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(grep -c 'snap app_restrict' "$WORK/spsm/spsm.log")" = "1" ]
check "the app restrictions are applied once when the screen goes off" $?
run_engine screen-off >/dev/null 2>&1
grep -q "idle: app_restrict is already in place from this idle period - not redoing it" "$WORK/spsm/spsm.log"
check "and a second screen-off in the same idle period skips them" $?
grep -q "idle: deep_doze is already in place from this idle period - not redoing it" "$WORK/spsm/spsm.log"
check "the deep-sleep request is skipped the same way" $?
[ "$(grep -c 'snap app_restrict' "$WORK/spsm/spsm.log")" = "1" ]
check "so nothing re-recorded the apps' original states" $?
# A real wake ends the idle period, and the next one must do the work again.
screen_on
run_engine screen-on >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(grep -c 'snap app_restrict' "$WORK/spsm/spsm.log")" = "2" ]
check "and after a wake the next screen-off applies them again" $?
run_engine screen-on >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1

say "71. the launcher is refreshed once on the way out, and never while the mode runs"
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
screen_off; run_engine screen-off >/dev/null 2>&1
screen_on;  run_engine screen-on  >/dev/null 2>&1
n=$(grep -c "^am force-stop com.android.launcher3$" "$WORK/stub/calls" 2>/dev/null || true)
[ "${n:-0}" = 0 ]
check "the launcher is left alone while the mode is running (got ${n:-0} restart(s))" $?
run_engine deactivate >/dev/null 2>&1
n=$(grep -c "^am force-stop com.android.launcher3$" "$WORK/stub/calls" 2>/dev/null || true)
[ "${n:-0}" = 1 ]
check "coming out of the mode restarts it exactly once (got ${n:-0})" $?
# No ^ here: every line this mode writes is stamped with the time first.
n=$(grep -c "launcher refreshed: com.android.launcher3 restarted" "$WORK/spsm/spsm.log" 2>/dev/null || true)
[ "${n:-0}" = 1 ]
check "and the log says which app was restarted and why (got ${n:-0} line(s))" $?
# Started again in the same breath: a force-stopped home must not leave the phone
# with nothing on screen.
grep -q "^am start -a android.intent.action.MAIN -c android.intent.category.HOME$" "$WORK/stub/calls"
check "and it is put back on screen straight away" $?
# The reverts run side by side now - the owner measured this exit at about
# three times the module installer's own revert for the same work, because the
# phone answers one question at a time and the exit used to ask in single
# file - but the two knobs that have an order keep it: the navigation overlay
# goes back before the home role is handed over, never the other way round.
_n=$(grep -n "the phone's own navigation is back" "$WORK/spsm/spsm.log" | tail -1 | cut -d: -f1)
_h=$(grep -n "launcher refreshed" "$WORK/spsm/spsm.log" | tail -1 | cut -d: -f1)
[ -n "$_n" ] && [ -n "$_h" ] && [ "$_n" -lt "$_h" ]
check "and the ordered reverts kept their order on the way out" $?

# An exit with every option switched off changed nothing, so there is nothing for
# the launcher to rebuild and no reason to restart somebody's home screen.
make_tree; make_stubs; seed_stub_state
run_engine dump-knobs >/dev/null 2>&1
while IFS='|' read -r _id _rest; do echo "knob.$_id=0" >> "$WORK/spsm/config"; done < "$WORK/spsm/knobs.list"
screen_on
run_engine activate >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
n=$(grep -c "^am force-stop " "$WORK/stub/calls" 2>/dev/null || true)
[ "${n:-0}" = 0 ]
check "a session that changed nothing restarts nothing (got ${n:-0})" $?

# And an exit on a phone that was never in the mode does even less.
make_tree; make_stubs; seed_stub_state
run_engine deactivate >/dev/null 2>&1
n=$(grep -c "^am force-stop " "$WORK/stub/calls" 2>/dev/null || true)
[ "${n:-0}" = 0 ]
check "an exit with no session behind it force-stops nothing (got ${n:-0})" $?


# ==========================================================================
say "72. the phone's own three-button navigation, switched by its own command"
# The owner's correction and his own verified commands:
#   "i didn't told you to implement a custom three button navigation bar, i mean
#    i want system own 3-button navigation bar. Also you custom three button
#    navigation bar is too buggy, so remove it completely and then just add
#    system one ... su -c 'cmd overlay enable-exclusive --user 0 --category
#    com.android.internal.systemui.navbar.threebutton' ... su -c 'cmd overlay
#    enable-exclusive --user 0 --category com.android.internal.systemui.navbar.gestural'"
#
# The app half - no bar drawn by this app at all - is in case 66. This is the
# phone half: the system's own bar, switched by the system's own mechanism, and
# put back the same way on the way out.
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/secure.navigation_mode" 2>/dev/null)" = "0" ]
check "the phone is put on three-button navigation while the mode is on" $?
grep -q "^cmd overlay enable-exclusive --user 0 --category com.android.internal.systemui.navbar.threebutton$" "$WORK/stub/calls"
check "with the phone's own command, the one the owner verified" $?
grep -q "nav: the phone is on three-button navigation (was 2, overlay com.android.internal.systemui.navbar.gestural)" "$WORK/spsm/spsm.log"
check "and the log says what it was before - both the setting and the overlay" $?
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/secure.navigation_mode" 2>/dev/null)" = "2" ]
check "gesture navigation is put back exactly as it was on exit" $?
grep -q "^cmd overlay enable-exclusive --user 0 --category com.android.internal.systemui.navbar.gestural$" "$WORK/stub/calls"
check "and the overlay that draws his bar is the one put back" $?
grep -q "nav: the phone's own navigation is back (overlay com.android.internal.systemui.navbar.gestural)" "$WORK/spsm/spsm.log"
check "with the log saying so, rather than leaving it to be guessed" $?
run_engine verify > "$WORK/out.v73" 2>&1
grep -q "drift=0" "$WORK/out.v73"
check "with nothing left behind ($(cat "$WORK/out.v73"))" $?

# A ROM that takes either command and does nothing with it: the phone's own
# navigation is put back explicitly, and the journal is told, so the exit does
# not chase a value that is already right.
make_tree; make_stubs; seed_stub_state
touch "$WORK/stub/refuse_overlay" "$WORK/stub/refuse_put.secure.navigation_mode"
screen_on
run_engine activate > "$WORK/out.a73" 2>&1
[ "$(cat "$WORK/stub/settings/secure.navigation_mode" 2>/dev/null)" = "2" ]
check "a phone that refuses the switch keeps its own navigation" $?
grep -q "nav: this phone did not take three-button navigation (still 2); the system bar is left exactly as it was" "$WORK/spsm/spsm.log"
check "and the log says so, in words" $?
grep -q "note nav_buttons: applied, did not take, and was put back by the module" "$WORK/spsm/spsm.log"
check "and it is recorded as a change that was undone, not one to undo later" $?
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v73b" 2>&1
grep -q "drift=0" "$WORK/out.v73b"
check "with a clean exit ($(cat "$WORK/out.v73b"))" $?

# A phone already on three buttons: nothing is asked of it, and the exit has
# nothing to put back.
make_tree; make_stubs; seed_stub_state
printf '%s' 0 > "$WORK/stub/settings/secure.navigation_mode"
screen_on
run_engine activate >/dev/null 2>&1
grep -q "nav: the phone already uses three-button navigation" "$WORK/spsm/spsm.log"
check "a phone already on three buttons is recognised as such" $?
if grep -q "^cmd overlay enable-exclusive" "$WORK/stub/calls"; then
  bad "and nothing is asked of it"
else
  ok "and nothing is asked of it"
fi
run_engine deactivate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/secure.navigation_mode" 2>/dev/null)" = "0" ]
check "and its own setting survives the round trip" $?

# Switched off by the user: the phone's navigation is not touched at all.
make_tree; make_stubs; seed_stub_state
disable_knobs nav_buttons
screen_on
run_engine activate >/dev/null 2>&1
[ "$(cat "$WORK/stub/settings/secure.navigation_mode" 2>/dev/null)" = "2" ]
check "with the option off the phone's navigation is left alone" $?
if grep -q "^cmd overlay enable-exclusive" "$WORK/stub/calls"; then
  bad "and nothing is even asked of it"
else
  ok "and nothing is even asked of it"
fi
run_engine deactivate >/dev/null 2>&1

# A phone that will not say which navigation it uses: left alone, and told so.
# Writing a guess here is how a phone ends up on a bar its owner did not ask for.
make_tree; make_stubs; seed_stub_state
rm -f "$WORK/stub/settings/secure.navigation_mode"
touch "$WORK/stub/no_overlay_list"
screen_on
run_engine activate >/dev/null 2>&1
grep -q "nav: this phone will not say which navigation it uses, so it is left alone" "$WORK/spsm/spsm.log"
check "a phone that will not say which navigation it uses is left alone" $?
[ ! -e "$WORK/stub/settings/secure.navigation_mode" ]
check "and nothing is written for it" $?
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v73c" 2>&1
grep -q "drift=0" "$WORK/out.v73c"
check "with nothing left behind ($(cat "$WORK/out.v73c"))" $?

say "73. the background sweep: the memory the frozen apps hold is handed back"
# The owner's numbers: 649 processes, 3.78G of 3.83G used, 47M free, one chat app
# holding 490M. Suspending an app stops it being started; it does not give back
# the memory it already holds. Stopping it does, and make-uid-idle is the
# platform's own "this app is idle now".
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
grep -q "background sweep (mode on): 3 frozen app(s) stopped" "$WORK/spsm/spsm.log"
check "switching the mode on stops the frozen apps and says how many" $?
grep -q "free memory" "$WORK/spsm/spsm.log"
check "and reports the memory it freed, before and after" $?
grep -q "^am make-uid-idle com.spotify.music$" "$WORK/stub/calls"
check "and each one is handed to ActivityManager as idle, not merely stopped" $?
grep -q "^am kill-all$" "$WORK/stub/calls"
check "and the phone is asked to clear what it still calls background" $?
# Screen off: memory an app grabbed while the screen was on is given back the
# moment it goes off. This is the half that keeps the mode saving over a long day.
screen_off
run_engine screen-off >/dev/null 2>&1
grep -q "background sweep (screen off)" "$WORK/spsm/spsm.log"
check "every screen-off sweeps again" $?
n=$(grep -c "^am kill-all$" "$WORK/stub/calls" 2>/dev/null || true)
[ "${n:-0}" -ge 2 ]
check "so a phone left alone all afternoon keeps giving the memory back (${n:-0} sweeps)" $?
screen_on
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v74" 2>&1
grep -q "drift=0" "$WORK/out.v74"
check "and the sweep leaves nothing to undo ($(cat "$WORK/out.v74"))" $?

# Switched off by the user: nothing is stopped by the sweep, and no line claims it.
make_tree; make_stubs; seed_stub_state
disable_knobs sweep_bg
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
if grep -q "background sweep" "$WORK/spsm/spsm.log"; then
  bad "with the option off nothing is swept"
else
  ok "with the option off nothing is swept"
fi
if grep -q "^am kill-all$" "$WORK/stub/calls"; then
  bad "and the phone's background is not cleared either"
else
  ok "and the phone's background is not cleared either"
fi
screen_on
run_engine deactivate >/dev/null 2>&1

say "74. the ROM's own background work is restricted while the screen is off, and put back"
# The owner's question: "Axion rom put their components all around even in system
# server (a very large process). Can we do something for this."
#
# system_server itself is the phone's Android and is not touched. What is taken
# away is its clients: a system package working in the background keeps Android
# busy, and the switch that stops it is the one Settings already offers per app -
# the standby bucket, plus RUN_ANY_IN_BACKGROUND. Nothing is disabled or
# suspended, and every package is put back on wake.
make_tree; make_stubs; seed_stub_state
printf 'com.whatsapp\ncom.example.freebie\ncom.android.traceur\ncom.android.settings\ncom.android.providers.calendar\n' > "$WORK/stub/procs"
printf 'com.android.traceur\ncom.android.settings\ncom.android.providers.calendar\n' > "$WORK/stub/pkgs_sys"
printf '10\n' > "$WORK/stub/bucket/com.android.traceur"
printf 'RUN_ANY_IN_BACKGROUND: allow\n' > "$WORK/stub/appop/com.android.traceur"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ "$(cat "$WORK/stub/bucket/com.android.traceur" 2>/dev/null)" = "restricted" ]
check "a system package working in the background is put in the restricted bucket" $?
grep -q "RUN_ANY_IN_BACKGROUND: deny" "$WORK/stub/appop/com.android.traceur"
check "and its background running is denied - the same switch Settings offers" $?
grep -q "^am make-uid-idle com.android.traceur$" "$WORK/stub/calls"
check "and it is put to sleep now, not at some later point" $?
grep -q "rom background: .* of the phone's own package(s) restricted for this idle period" "$WORK/spsm/spsm.log"
check "and the log names what was restricted, and that it is for this idle period" $?
[ ! -e "$WORK/stub/bucket/com.android.settings" ] && [ ! -e "$WORK/stub/appop/com.android.settings" ]
check "the phone's own core - Settings, System UI, the phone - is not touched" $?
[ ! -e "$WORK/stub/bucket/com.android.providers.calendar" ] && [ ! -e "$WORK/stub/appop/com.android.providers.calendar" ]
check "nor anything Android is already exempting from battery optimisation" $?
[ ! -e "$WORK/stub/bucket/com.example.freebie" ] && [ ! -e "$WORK/stub/appop/com.example.freebie" ]
check "nor a third-party app: restricting those is the other option's job, not this one's" $?
n=$(find "$WORK/stub/pkg" -name '*.enabled' 2>/dev/null | wc -l)
[ "${n:-0}" = 0 ]
check "and nothing anywhere was disabled (${n:-0} disabled)" $?
# Wake: the values go back, and the record of them goes with them.
screen_on
run_engine screen-on >/dev/null 2>&1
[ "$(cat "$WORK/stub/bucket/com.android.traceur" 2>/dev/null)" = "10" ]
check "waking puts the standby bucket back" $?
grep -q "RUN_ANY_IN_BACKGROUND: allow" "$WORK/stub/appop/com.android.traceur"
check "and gives the app its background running back" $?
[ ! -e "$WORK/spsm/journal/orig/rom_bg.tsv" ]
check "and the record of what it was is gone with it" $?
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v75" 2>&1
grep -q "drift=0" "$WORK/out.v75"
check "with a clean exit ($(cat "$WORK/out.v75"))" $?

# A value something else moved after us is a newer decision than ours: the exit
# leaves it, and says so.
make_tree; make_stubs; seed_stub_state
printf 'com.android.traceur\n' > "$WORK/stub/procs"
printf 'com.android.traceur\n' > "$WORK/stub/pkgs_sys"
printf '10\n' > "$WORK/stub/bucket/com.android.traceur"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
printf '40\n' > "$WORK/stub/bucket/com.android.traceur"
screen_on
run_engine screen-on >/dev/null 2>&1
[ "$(cat "$WORK/stub/bucket/com.android.traceur" 2>/dev/null)" = "40" ]
check "a bucket something else changed since is left as they set it" $?
run_engine deactivate >/dev/null 2>&1

# Switched off by the user, and a phone with no system packages running: nothing
# is written and the log says which of the two it was.
make_tree; make_stubs; seed_stub_state
printf 'com.android.traceur\n' > "$WORK/stub/procs"
printf 'com.android.traceur\n' > "$WORK/stub/pkgs_sys"
disable_knobs rom_bg_off
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ ! -e "$WORK/stub/bucket/com.android.traceur" ]
check "with the option off no system package is restricted" $?
screen_on
run_engine deactivate >/dev/null 2>&1

make_tree; make_stubs; seed_stub_state
printf 'com.android.traceur\n' > "$WORK/stub/procs"
screen_on
run_engine activate >/dev/null 2>&1
screen_off
run_engine screen-off >/dev/null 2>&1
[ ! -e "$WORK/stub/bucket/com.android.traceur" ]
check "a phone running none of its own packages in the background is left alone" $?
grep -q "rom background: nothing of the phone's own was running in the background" "$WORK/spsm/spsm.log"
check "and the log says exactly that, rather than claiming a change" $?
screen_on
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v75b" 2>&1
grep -q "drift=0" "$WORK/out.v75b"
check "with a clean exit ($(cat "$WORK/out.v75b"))" $?

say "75. Clear all: everything the list is showing is closed at once"
# The owner's instruction: "add a clear all button in recents which force stop all
# the processes which is running in the background at once."
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
screen_on
run_engine activate >/dev/null 2>&1
_before=$(run_engine recents 2>/dev/null | grep -c .)
[ "${_before:-0}" -ge 2 ]
check "there are tasks in the list to close (${_before:-0})" $?
out=$(run_engine clear-all 2>/dev/null)
printf '%s\n' "$out" | grep -q "asked=${_before} gone=${_before} left=0"
check "every listed task is closed, and the report counts what is left ($out)" $?
[ "$(run_engine recents 2>/dev/null | grep -c .)" = "0" ]
check "and the phone's own task list really is empty afterwards" $?
grep -q "background sweep (clear all)" "$WORK/spsm/spsm.log"
check "and the frozen background is swept in the same press" $?
grep -q "clear all: ${_before} task(s) asked to close, ${_before} gone, 0 still listed, free memory" "$WORK/spsm/spsm.log"
check "with the count and the memory it freed written down" $?

# A task that will not close: an honest count, not an optimistic one. This is the
# same read-back the owner asked for when closing one app looked like it worked.
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
touch "$WORK/stub/task_remove_broken" "$WORK/stub/force_stop_broken"
screen_on
run_engine activate >/dev/null 2>&1
_before=$(run_engine recents 2>/dev/null | grep -c .)
out=$(run_engine clear-all 2>/dev/null)
printf '%s\n' "$out" | grep -q "asked=${_before} gone=0 left=${_before}"
check "a task that will not close is counted as still open ($out)" $?
[ "$(run_engine recents 2>/dev/null | grep -c .)" = "${_before}" ]
check "and the list still shows it, because it is still there" $?

# Nothing left behind: the button closes tasks and stops apps, and changes no
# setting at all.
make_tree; make_stubs; seed_stub_state
cp "$REPO/tests/fixtures/recents-narzo.txt" "$WORK/stub/recents.dump"
screen_on
run_engine activate >/dev/null 2>&1
run_engine clear-all >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v76" 2>&1
grep -q "drift=0" "$WORK/out.v76"
check "and clearing everything leaves nothing to undo ($(cat "$WORK/out.v76"))" $?

say "76. the frame rate: the screen is held to 30 by SurfaceFlinger, and the phone's own 60 is put back"
# The owner found the lever that works on this phone and verified it by hand:
#   su -c 'service call SurfaceFlinger 1035 i32 0 i64 0 f 30 f 30'  -> 30 fps
#   su -c 'service call SurfaceFlinger 1035 i32 0 i64 0 f 60 f 60'  -> 60 fps, his default
# It is SurfaceFlinger's own override - below panel modes, below settings keys,
# below the ROM's Game Mode setting - and it covers every app and this mode's
# home. It is a setter with no getter, so the test asserts the exact command and
# the exit's restore, and that nothing readable is left behind.

# 1. On: the verified 30 command. Off: the verified 60 command.
make_tree; make_stubs; seed_stub_state
enable_knobs fps_cap
rm -f "$WORK/stub/calls"
screen_on
run_engine activate >/dev/null 2>&1
grep -q "service call SurfaceFlinger 1035 i32 0 i64 0 f 30 f 30" "$WORK/stub/calls"
check "the screen is asked for 30 fps with the owner's verified command" $?
grep -q "fps: the whole screen is held to 30 frames a second" "$WORK/spsm/spsm.log"
check "and the log says so in the same words" $?
run_engine deactivate >/dev/null 2>&1
grep -q "service call SurfaceFlinger 1035 i32 0 i64 0 f 60 f 60" "$WORK/stub/calls"
check "and the phone's own 60 is put back on exit, the owner's restore command" $?
grep -q "fps: the screen's frame rate is put back to 60" "$WORK/spsm/spsm.log"
check "and the log says that too" $?
run_engine verify > "$WORK/out.v79" 2>&1
grep -q "drift=0" "$WORK/out.v79"
check "with a clean exit ($(cat "$WORK/out.v79"))" $?

# 2. Check (probe) names the command and the two rates.
run_engine probe fps_cap > "$WORK/out.p79" 2>&1
grep -q "works - set by the owner-verified SurfaceFlinger command" "$WORK/out.p79"
check "Check says what the option does on this phone" $?

# 3. Without the override armed (a phone that has not rebooted since install)
#    the command is left alone and the refusal is honest - the owner proved the
#    alternative: the same command with the override off crashes the compositor.
make_tree; make_stubs; seed_stub_state
enable_knobs fps_cap
rm -f "$WORK/stub/props/ro.surface_flinger.enable_frame_rate_override" "$WORK/stub/calls"
screen_on
run_engine activate >/dev/null 2>&1
if grep -q "service call SurfaceFlinger" "$WORK/stub/calls" 2>/dev/null; then
  bad "an unarmed phone is never given the frame-rate command"
else
  ok "an unarmed phone is never given the frame-rate command"
fi
grep -q "one more reboot after installing arms it" "$WORK/spsm/spsm.log"
check "and the log says exactly that, and why" $?
run_engine deactivate >/dev/null 2>&1
if grep -q "f 60 f 60" "$WORK/stub/calls" 2>/dev/null; then
  bad "nothing was applied, so the exit restores nothing"
else
  ok "nothing was applied, so the exit restores nothing"
fi

# 4. With the option off, SurfaceFlinger is never asked.
make_tree; make_stubs; seed_stub_state
disable_knobs fps_cap
rm -f "$WORK/stub/calls"
screen_on
run_engine activate >/dev/null 2>&1
if grep -q "service call SurfaceFlinger" "$WORK/stub/calls" 2>/dev/null; then
  bad "with the option off the frame rate is never touched"
else
  ok "with the option off the frame rate is never touched"
fi
run_engine deactivate >/dev/null 2>&1

say "77. the exit measures itself honestly, and stops doing work it does not need"
# The owner asked for a faster exit. The first thing it needed was a number worth
# trusting: `_t0` in the exit was also used inside the phase loops, and a shell has
# no local variables, so the stopwatch was being reset by the last knob reverted -
# the log said "revert clean in 4s" for an exit that took ninety seconds.
grep -q "_exit_t0" "$REPO/module/scripts/engine.sh" && grep -q "_kt0" "$REPO/module/scripts/engine.sh"
check "the exit and the phase loops keep their own stopwatches" $?
if grep -qE '(^|[^_a-zA-Z])_t0=' "$REPO/module/scripts/engine.sh"; then
  bad "and no two stopwatches share a variable"
else
  ok "and no two stopwatches share a variable"
fi
# The journal files are handed over as they are: the two copies and two deletes
# per knob were four processes each, twenty-odd times.
if grep -q 'JOURNAL"\/$_id.orig.txt' "$REPO/module/scripts/engine.sh"; then
  bad "the revert does not copy the journal for no reason"
else
  ok "the revert does not copy the journal for no reason"
fi
grep -q 'has_function' "$REPO/module/scripts/engine.sh" && grep -q "^has_function()" "$REPO/module/scripts/lib.sh"
check "and a function that is missing is no longer called anyway" $?

# The two things the device log showed: a per-knob note line with nothing after
# it (a shell error next to it), and the app list being read again on every
# screen-off even though the journal already knew what it looked like.
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
if grep -q "^2026.*note [a-z_]*: $" "$WORK/spsm/spsm.log"; then
  bad "no knob writes an empty note line"
else
  ok "no knob writes an empty note line"
fi
if grep -q "note .*: inaccessible or not found" "$WORK/spsm/spsm.log"; then
  bad "and no missing function is called"
else
  ok "and no missing function is called"
fi
# A second deep pass inside one idle period does not read every app again: the
# journal already says what the phone looked like before we touched it.
#
# The daemon is stopped first on purpose. It does a pass of its own the moment it
# sees the screen go off, and with the two racing, "how much did the second pass
# read" becomes a question about the race rather than about the code - that is
# how this check first failed, with four reads and then ten.
make_tree; make_stubs; seed_stub_state
screen_on
run_engine activate >/dev/null 2>&1
stop_daemons
[ "$(daemons_alive)" = "0" ]
check "no daemon is running while the idle pass is measured ($(daemons_alive) alive)" $?
screen_off
run_engine screen-off >/dev/null 2>&1
_n1=$(grep -c "^am get-standby-bucket" "$WORK/stub/calls" 2>/dev/null || true)
run_engine screen-off >/dev/null 2>&1
_n2=$(grep -c "^am get-standby-bucket" "$WORK/stub/calls" 2>/dev/null || true)
_n2=$(( ${_n2:-0} - ${_n1:-0} ))
[ "$_n2" = "0" ]
check "a second idle pass inside the same idle period reads nothing again (${_n1:-0} reads, then $_n2 more)" $?
screen_on
run_engine screen-on >/dev/null 2>&1
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v80" 2>&1
grep -q "drift=0" "$WORK/out.v80"
check "and it leaves nothing behind ($(cat "$WORK/out.v80"))" $?

# The suspend state, read from the file the system keeps, rather than by asking
# about each app: twenty apps asked separately was eighteen seconds of the exit
# in the v3.6.1 log, and it is the exit the owner asked to be quicker.
make_tree; make_stubs; seed_stub_state
mkdir -p "$WORK/stub/users/0"
cat > "$WORK/stub/users/0/package-restrictions.xml" <<'XML'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<package-restrictions>
<pkg name="com.whatsapp" ceDataInode="124" enabled="1" installed="1" stopped="0" hidden="false" suspended="true" />
<pkg name="com.spotify.music" ceDataInode="125" enabled="1" installed="1" stopped="0" hidden="false" suspended="false" />
</package-restrictions>
XML
screen_on
run_engine activate >/dev/null 2>&1
# com.whatsapp is recorded as suspended by somebody else, so it is not ours to
# take over - and it is not suspended again by us.
grep -q "^com.whatsapp	1$" "$WORK/spsm/journal/block_other_apps.orig"
check "an app suspended by somebody else is recorded as theirs" $?
[ ! -e "$WORK/stub/pkg/com.whatsapp.suspended" ]
check "and it is left exactly as it was" $?
run_engine deactivate >/dev/null 2>&1
[ -f "$WORK/stub/pkg/com.whatsapp.suspended" ] && bad "and it is not unsuspended on the way out either" || ok "and it is not unsuspended on the way out either"
run_engine verify > "$WORK/out.v80b" 2>&1
grep -q "drift=0" "$WORK/out.v80b"
check "with a clean exit ($(cat "$WORK/out.v80b"))" $?
# And with no such file at all, the phone is asked per app as it always was.
make_tree; make_stubs; seed_stub_state
rm -rf "$WORK/stub/users"
screen_on
run_engine activate >/dev/null 2>&1
grep -q "^com.whatsapp	0$" "$WORK/spsm/journal/block_other_apps.orig"
check "a phone without that file is asked about each app, as before" $?
run_engine deactivate >/dev/null 2>&1
run_engine verify > "$WORK/out.v80c" 2>&1
grep -q "drift=0" "$WORK/out.v80c"
check "with a clean exit ($(cat "$WORK/out.v80c"))" $?


# ==========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
