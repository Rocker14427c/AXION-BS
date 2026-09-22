#!/system/bin/sh
# Axion SPSM v3 - installer.
# Read the version from module.prop rather than repeating it here: a banner that
# disagrees with the zip is how a user ends up reporting the wrong version.
_VERSION=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -1)
[ -n "$_VERSION" ] || _VERSION=v?

ui_print " "
ui_print "  Axion Super Power Saving Mode $_VERSION"
ui_print "  Journaled: every change is recorded before it happens"
ui_print "  and reverted on exit - RMX3430 / AxionOS 2.7"
ui_print " "

SPSMD=${SPSM_DIR:-/data/adb/spsm}
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
if [ -f "$MODPATH/system/app/AxionSPSM/AxionSPSM.apk" ]; then
  set_perm "$MODPATH/system/app/AxionSPSM/AxionSPSM.apk" 0 0 0644
fi

# --- engine scripts -----------------------------------------------------------
# Canonical home is /data/adb/spsm/scripts. enter.sh/exit.sh at the top level are
# thin wrappers kept for anything (including the app) that used those paths.
mkdir -p "$SPSMD/scripts" "$SPSMD/state" "$SPSMD/journal"
cp -af "$MODPATH/scripts/"*.sh "$SPSMD/scripts/" 2>/dev/null
chmod 755 "$SPSMD/scripts/"*.sh 2>/dev/null
echo "$MODPATH" > "$SPSMD/moddir"

# --- native helpers -----------------------------------------------------------
# The screen monitor, for whichever ABI this phone can actually run. Optional by
# design: if none of the shipped builds load, the daemon polls the panel exactly
# as it always has, and the module is fully functional either way.
if [ -d "$MODPATH/bin" ]; then
  set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
  # shellcheck source=/dev/null
  . "$SPSMD/scripts/lib.sh" 2>/dev/null && publish_native "$MODPATH"
  if [ -x "$SPSMD/bin/spsm-screenmon" ]; then
    ui_print "  Screen monitor: event-driven ($(cat "$SPSMD/state/native_abi" 2>/dev/null))"
  else
    ui_print "  Screen monitor: polling (no native build runs on this device)"
  fi
fi
# Which scripts are on this phone, written where the app and the log can see it.
mkdir -p "$SPSMD/state" 2>/dev/null
printf '%s\n' "$_VERSION" > "$SPSMD/state/script_version" 2>/dev/null

cat > /data/adb/spsm/enter.sh <<'EOS'
#!/system/bin/sh
exec sh /data/adb/spsm/scripts/engine.sh activate
EOS
cat > /data/adb/spsm/exit.sh <<'EOS'
#!/system/bin/sh
exec sh /data/adb/spsm/scripts/engine.sh deactivate
EOS
chmod 755 /data/adb/spsm/enter.sh /data/adb/spsm/exit.sh

# Publish the knob list so the app's options screen matches the scripts exactly.
sh "$SPSMD/scripts/engine.sh" dump-knobs >/dev/null 2>&1

# A previous version may have left the phone capped: undo it before anything else.
if [ -d "$SPSMD/journal" ] && ls "$SPSMD/journal/"*.orig >/dev/null 2>&1; then
  ui_print "  Restoring changes left by a previous version…"
  sh "$SPSMD/scripts/engine.sh" deactivate >/dev/null 2>&1
fi

# The old version could leave these behind; they are never correct to keep.
if [ -f "$SPSMD/active" ]; then rm -f "$SPSMD/active"; fi
if [ -f "$SPSMD/disable" ]; then rm -f "$SPSMD/disable"; fi
if [ -f "$SPSMD/exiting" ]; then rm -f "$SPSMD/exiting"; fi
if [ -f "$SPSMD/snap/google_frozen" ]; then rm -rf "$SPSMD/snap"; fi

# --- app ----------------------------------------------------------------------
ui_print "  Installing Super Power Saving app…"
APK=""
if [ -f "$MODPATH/system/app/AxionSPSM/AxionSPSM.apk" ]; then
  APK="$MODPATH/system/app/AxionSPSM/AxionSPSM.apk"
elif [ -f "$MODPATH/app/AxionSPSM.apk" ]; then
  APK="$MODPATH/app/AxionSPSM.apk"
fi
if [ -n "$APK" ] && [ -f "$MODPATH/scripts/install-apk.sh" ]; then
  out=$(sh "$MODPATH/scripts/install-apk.sh" "$APK" 2>&1)
  ui_print "  $out"
else
  ui_print "  APK missing in zip"
fi

ui_print " "
ui_print "  After reboot:"
ui_print "   1. App drawer -> Super Power Saving"
ui_print "   2. ResukiSU asks for root -> Allow"
ui_print "   3. Options -> untick anything you do not want changed"
ui_print "   4. Turn on"
ui_print " "
ui_print "  Exit restores everything from the journal."
ui_print "  Stuck? ResukiSU -> Modules -> remove this -> reboot"
ui_print "  Log: /data/adb/spsm/spsm.log"
ui_print " "
