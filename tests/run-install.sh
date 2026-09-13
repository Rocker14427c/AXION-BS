#!/bin/sh
# Tests for module/scripts/install-apk.sh.
#
# The installer runs once, on a phone, in the module installer, where a failure
# means the user has a power mode with no UI. So the fallback chain is exercised
# here against a stub `pm` instead of being discovered on the device.
#
#   ./tests/run-install.sh
#
# Cases: first-try success, signature-mismatch recovery, package already
# present, total failure, missing APK.

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${TMPDIR:-/tmp}/spsm-install-test
PASS=0
FAIL=0

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

# ------------------------------------------------------------------ stub tools
# `pm` behaviour is driven by $PM_MODE:
#   ok        - install succeeds
#   sig       - fails with UPDATE_INCOMPATIBLE until the package is removed
#   always    - always fails
#   installed - always fails, but `pm path` reports the package as present
make_stubs() {
  rm -rf "$WORK"
  mkdir -p "$WORK/bin" "$WORK/spsm" "$WORK/tmp" "$WORK/module/app" "$WORK/calls"
  BIN="$WORK/bin"

  cat > "$BIN/pm" <<'STUB'
#!/bin/sh
echo "pm $*" >> "$CALLS/pm"
MODE=$(cat "$CALLS/mode")
case "$1" in
  path)
    [ "$MODE" = "installed" ] && { echo "package:/system/app/AxionSPSM/AxionSPSM.apk"; exit 0; }
    exit 1 ;;
  uninstall)
    echo removed > "$CALLS/uninstalled"
    exit 0 ;;
  install)
    case "$MODE" in
      ok)     echo "Success"; exit 0 ;;
      sig)    if [ -f "$CALLS/uninstalled" ]; then echo "Success"; exit 0; fi
              echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package dev.axion.spsm signatures do not match]"
              exit 1 ;;
      *)      echo "Failure [INSTALL_FAILED_INTERNAL_ERROR]"; exit 1 ;;
    esac ;;
esac
exit 0
STUB

  for t in appops cmd dumpsys chcon chown restorecon; do
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS/%s"\nexit 0\n' "$t" "$t" > "$BIN/$t"
  done
  chmod +x "$BIN"/*
}

run_installer() { # run_installer <pm-mode> [apk]
  MODE=$1
  echo "$MODE" > "$WORK/calls/mode"
  : > "$WORK/calls/pm"
  rm -f "$WORK/calls/uninstalled"
  PATH="$BIN:$PATH" \
  SPSM_DIR="$WORK/spsm" \
  SPSM_MODULE_DIR="$WORK/module" \
  SPSM_TMP_APK="$WORK/tmp/AxionSPSM.apk" \
  CALLS="$WORK/calls" \
  sh "$REPO/module/scripts/install-apk.sh" "$2"
}

apk_file() { # apk_file - create a stand-in apk
  printf 'not really an apk\n' > "$WORK/module/app/AxionSPSM.apk"
}

# ==========================================================================
say "1. clean install on the first try"
make_stubs; apk_file
run_installer ok > "$WORK/out1" 2>&1
check "exit 0" $?
grep -q "installed OK (plain)" "$WORK/spsm/install.log"; check "logged as a plain install (the form this ROM accepts)" $?
[ "$(grep -c '^pm install' "$WORK/calls/pm")" = "1" ]; check "installed in one call" $?
if grep -q 'disable-verification' "$WORK/spsm/install.log"; then
  bad "no rejected-flag attempt was logged before the one that works"
else
  ok "no rejected-flag attempt was logged before the one that works"
fi
[ ! -f "$WORK/calls/uninstalled" ]; check "did not remove anything" $?
[ ! -f "$WORK/tmp/AxionSPSM.apk" ]; check "temp APK cleaned up" $?
[ -s "$WORK/calls/appops" ]; check "appops granted after install" $?
grep -q 'whitelist +dev.axion.spsm' "$WORK/calls/dumpsys"; check "doze whitelisted" $?

say "2. an older build signed with another key is replaced, not fatal"
make_stubs; apk_file
run_installer sig > "$WORK/out2" 2>&1
check "exit 0" $?
grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE" "$WORK/spsm/install.log"
check "the real failure was recorded" $?
[ -f "$WORK/calls/uninstalled" ]; check "stale package removed" $?
grep -q "installed OK (plain, after clean)" "$WORK/spsm/install.log"; check "reinstalled after the clean" $?
grep -q '^pm uninstall dev.axion.spsm' "$WORK/calls/pm"; check "uninstall used the real package name" $?

say "3. package already present via overlay is accepted"
make_stubs; apk_file
run_installer installed > "$WORK/out3" 2>&1
check "exit 0" $?
grep -q "already present via overlay" "$WORK/spsm/install.log"; check "recognised the overlay case" $?

say "4. a real failure fails loudly"
make_stubs; apk_file
run_installer always > "$WORK/out4" 2>&1
[ $? = 1 ]; check "exit 1" $?
grep -q "INSTALL FAILED" "$WORK/spsm/install.log"; check "logged INSTALL FAILED" $?
[ ! -f "$WORK/calls/appops" ]; check "did not pretend to succeed" $?

say "5. no APK anywhere is reported, not crashed on"
make_stubs
run_installer ok > "$WORK/out5" 2>&1
[ $? = 1 ]; check "exit 1" $?
grep -q "APK not found" "$WORK/spsm/install.log"; check "logged APK not found" $?

say "6. the bundled APK is found when no path is passed"
make_stubs
mkdir -p "$WORK/module/system/app/AxionSPSM"
printf 'bundled\n' > "$WORK/module/system/app/AxionSPSM/AxionSPSM.apk"
run_installer ok > "$WORK/out6" 2>&1
check "exit 0" $?
[ -f "$WORK/calls/pm" ]; check "found the module copy" $?

# ==========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
