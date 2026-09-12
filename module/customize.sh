#!/system/bin/sh
ui_print " "
ui_print "  Axion Super Power Saving Mode"
ui_print "  realme UI-style 6-app emergency mode"
ui_print "  Target: AxionOS 2.7 / Android 16"
ui_print "  Device: Realme Narzo 50A (RMX3430) + generic"
ui_print " "
ui_print "  After reboot:"
ui_print "  1. Open Super Power Saving"
ui_print "  2. SukiSU will ask for root → Allow"
ui_print "  3. Turn it on"
ui_print " "
ui_print "  Stuck? SukiSU → Modules → disable this → reboot"
ui_print "  or:  su -c 'touch /data/adb/spsm/disable'"
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

mkdir -p /data/adb/spsm
cp -af "$MODPATH/scripts/"*.sh /data/adb/spsm/ 2>/dev/null
chmod 755 /data/adb/spsm/*.sh 2>/dev/null
echo "$MODPATH" > /data/adb/spsm/moddir
