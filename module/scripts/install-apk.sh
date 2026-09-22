#!/system/bin/sh
# Install / update the SPSM app.
#
# PackageManager cannot read Magisk/KernelSU module files (SELinux
# magisk_file), so the APK is copied to /data/local/tmp with an apk_data_file
# context first.
#
# The signature case matters: if an older copy of the app was signed with a
# different key, `pm install -r` fails with INSTALL_FAILED_UPDATE_INCOMPATIBLE
# and the user is left with a module that has no UI. Removing the stale copy
# and installing fresh fixes that.

# Overridable so the fallback chain can be tested off-device; the defaults are
# the real ones. See tests/run-install.sh.
SPSM_DIR=${SPSM_DIR:-/data/adb/spsm}
MODULE_DIR=${SPSM_MODULE_DIR:-/data/adb/modules/axion_spsm}
TMP_APK=${SPSM_TMP_APK:-/data/local/tmp/AxionSPSM.apk}
mkdir -p "$SPSM_DIR"

log_inst() {
  echo "$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SPSM_DIR/install.log"
}

apk="$1"
if [ -z "$apk" ] || [ ! -f "$apk" ]; then
  for c in \
    "$MODULE_DIR/system/app/AxionSPSM/AxionSPSM.apk" \
    "$MODULE_DIR/app/AxionSPSM.apk"
  do
    [ -f "$c" ] && apk="$c" && break
  done
fi
if [ ! -f "$apk" ]; then
  log_inst "APK not found"
  exit 1
fi

tmp="$TMP_APK"
mkdir -p "$(dirname "$tmp")"
cp -f "$apk" "$tmp" || { log_inst "copy to /data/local/tmp failed"; exit 1; }
chmod 644 "$tmp"
chown 2000:2000 "$tmp" 2>/dev/null
chcon u:object_r:apk_data_file:s0 "$tmp" 2>/dev/null
restorecon "$tmp" 2>/dev/null

grant_app() {
  pm grant dev.axion.spsm android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
  appops set dev.axion.spsm QUERY_ALL_PACKAGES allow >/dev/null 2>&1
  appops set dev.axion.spsm RUN_IN_BACKGROUND allow >/dev/null 2>&1
  appops set dev.axion.spsm POST_NOTIFICATION allow >/dev/null 2>&1
  # The screen-state receiver is how the engine notices a screen change
  # instantly instead of polling for it.
  cmd appops set dev.axion.spsm RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
  dumpsys deviceidle whitelist +dev.axion.spsm >/dev/null 2>&1
}

try_install() {
  out=$(pm install -r -g --user 0 $1 "$tmp" 2>&1)
  log_inst "pm install $1 -> $out"
  case "$out" in
    *Success*) return 0 ;;
    *ALREADY_EXISTS*) return 0 ;;
  esac
  return 1
}

# Plain first. This is the form that works on the phone this module was written
# for: its `pm` rejects both flags below with "Unknown option" and a stack trace,
# so trying them first cost two failed rounds and filled install.log with noise
# before the attempt that was always going to succeed. They stay as fallbacks
# for a ROM that does need them.
if try_install ""; then
  grant_app; rm -f "$tmp"; log_inst "installed OK (plain)"; exit 0
fi
if try_install "--disable-verification --bypass-low-target-sdk-block"; then
  grant_app; rm -f "$tmp"; log_inst "installed OK (bypass)"; exit 0
fi
if try_install "--disable-verification"; then
  grant_app; rm -f "$tmp"; log_inst "installed OK (verification off)"; exit 0
fi

# Could be an older build signed with a different key. Drop the stale copy and
# retry once - losing a few preferences beats shipping a module with no UI.
log_inst "retrying after removing the previous copy"
pm uninstall --user 0 dev.axion.spsm >/dev/null 2>&1
pm uninstall dev.axion.spsm >/dev/null 2>&1

if try_install ""; then
  grant_app; rm -f "$tmp"; log_inst "installed OK (plain, after clean)"; exit 0
fi
if try_install "--disable-verification"; then
  grant_app; rm -f "$tmp"; log_inst "installed OK (after clean)"; exit 0
fi

if pm path dev.axion.spsm >/dev/null 2>&1; then
  grant_app
  log_inst "package already present via overlay"
  rm -f "$tmp"
  exit 0
fi

log_inst "INSTALL FAILED - see install.log"
exit 1
