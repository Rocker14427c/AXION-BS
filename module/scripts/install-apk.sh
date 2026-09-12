#!/system/bin/sh
# PackageManager cannot read Magisk/KSU module files (SELinux magisk_file).
# Copy to /data/local/tmp with apk_data_file context, then pm install.

SPSM_DIR=/data/adb/spsm
mkdir -p "$SPSM_DIR"

log_inst() {
  echo "$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SPSM_DIR/install.log"
}

apk="$1"
if [ -z "$apk" ] || [ ! -f "$apk" ]; then
  for c in \
    /data/adb/modules/axion_spsm/system/app/AxionSPSM/AxionSPSM.apk \
    /data/adb/modules/axion_spsm/app/AxionSPSM.apk
  do
    [ -f "$c" ] && apk="$c" && break
  done
fi
if [ ! -f "$apk" ]; then
  log_inst "APK not found"
  exit 1
fi

tmp=/data/local/tmp/AxionSPSM.apk
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
}

try_install() {
  # $1 = extra flags
  out=$(pm install -r -g --user 0 $1 "$tmp" 2>&1)
  rc=$?
  log_inst "pm install $1 → rc=$rc $out"
  echo "$out" | grep -qi 'Success' && return 0
  echo "$out" | grep -qi 'INSTALL_FAILED_ALREADY_EXISTS' && return 0
  return 1
}

if try_install "--disable-verification --bypass-low-target-sdk-block"; then
  grant_app
  rm -f "$tmp"
  log_inst "installed OK (bypass)"
  exit 0
fi
if try_install "--disable-verification"; then
  grant_app
  rm -f "$tmp"
  log_inst "installed OK"
  exit 0
fi
if try_install ""; then
  grant_app
  rm -f "$tmp"
  log_inst "installed OK (plain)"
  exit 0
fi

# Last resort: cmd package path (system overlay may already have registered it)
if pm path dev.axion.spsm >/dev/null 2>&1; then
  grant_app
  log_inst "package already present via overlay"
  rm -f "$tmp"
  exit 0
fi

log_inst "INSTALL FAILED — see install.log"
exit 1
