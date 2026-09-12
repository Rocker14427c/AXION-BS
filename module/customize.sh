#!/system/bin/sh
ui_print " "
ui_print "  Axion Super Power Saving Mode v2.1"
ui_print "  Snapshot-restore 6-app mode"
ui_print "  RMX3430 / AxionOS 2.7 — ResukiSU"
ui_print " "
ui_print "  v2 will NOT: kill logd, freeze every app,"
ui_print "  or force deep doze (that broke power-button wake)."
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
if [ -f "$MODPATH/system/app/AxionSPSM/AxionSPSM.apk" ]; then
  set_perm "$MODPATH/system/app/AxionSPSM/AxionSPSM.apk" 0 0 0644
fi

mkdir -p /data/adb/spsm
cp -af "$MODPATH/scripts/"*.sh /data/adb/spsm/ 2>/dev/null
chmod 755 /data/adb/spsm/*.sh 2>/dev/null
echo "$MODPATH" > /data/adb/spsm/moddir

# One-time install so the app exists before reboot. uninstall.sh removes it.
ui_print "  Installing Super Power Saving app…"
APK=""
[ -f "$MODPATH/system/app/AxionSPSM/AxionSPSM.apk" ] && APK="$MODPATH/system/app/AxionSPSM/AxionSPSM.apk"
[ -z "$APK" ] && [ -f "$MODPATH/app/AxionSPSM.apk" ] && APK="$MODPATH/app/AxionSPSM.apk"
if [ -n "$APK" ] && [ -f "$MODPATH/scripts/install-apk.sh" ]; then
  out=$(sh "$MODPATH/scripts/install-apk.sh" "$APK" 2>&1)
  ui_print "  $out"
else
  ui_print "  APK missing in zip"
fi

ui_print " "
ui_print "  After reboot:"
ui_print "  1. App drawer → Super Power Saving"
ui_print "  2. ResukiSU asks for root → Allow"
ui_print "  3. Turn it on (should take a few seconds)"
ui_print "  QS tile: add Super Power Save"
ui_print " "
ui_print "  Stuck? ResukiSU → Modules → remove this → reboot"
ui_print "  Log: /data/adb/spsm/spsm.log  (logd is never stopped)"
ui_print " "
