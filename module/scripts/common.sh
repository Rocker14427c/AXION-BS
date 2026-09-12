#!/system/bin/sh
# Shared helpers for Axion Super Power Saving Mode
# Device: Realme Narzo 50A (RMX3430, Helio G85) — also works generically.

SPSM_DIR="/data/adb/spsm"
STATE_DIR="$SPSM_DIR/state"
LOG="$SPSM_DIR/spsm.log"
WHITELIST="$SPSM_DIR/whitelist.txt"
ACTIVE="$SPSM_DIR/active"
DISABLE="$SPSM_DIR/disable"

mkdir -p "$SPSM_DIR" "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  # keep log small
  if [ -f "$LOG" ]; then
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 200000 ] && tail -c 80000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

w() {
  # w VALUE PATH
  [ -n "$2" ] && [ -e "$2" ] || return 0
  echo "$1" > "$2" 2>/dev/null
}

save() {
  # save KEY VALUE
  echo "$2" > "$STATE_DIR/$1" 2>/dev/null
}

load() {
  # load KEY [default]
  if [ -f "$STATE_DIR/$1" ]; then
    cat "$STATE_DIR/$1"
  else
    echo "${2-}"
  fi
}

save_file() {
  # copy sysfs/file contents if present
  [ -e "$2" ] || return 0
  cat "$2" > "$STATE_DIR/$1" 2>/dev/null
}

restore_file() {
  [ -f "$STATE_DIR/$1" ] && [ -e "$2" ] || return 0
  cat "$STATE_DIR/$1" > "$2" 2>/dev/null
}

lock_sysfs() {
  # lock_sysfs VALUE PATH
  [ -e "$2" ] || return 0
  if [ ! -f "$STATE_DIR/perm_$(echo "$2" | tr '/.' '_')" ]; then
    stat -c '%a' "$2" > "$STATE_DIR/perm_$(echo "$2" | tr '/.' '_')" 2>/dev/null
  fi
  chmod 644 "$2" 2>/dev/null
  echo "$1" > "$2" 2>/dev/null
  chmod 444 "$2" 2>/dev/null
}

unlock_sysfs() {
  [ -e "$1" ] || return 0
  key="perm_$(echo "$1" | tr '/.' '_')"
  chmod 644 "$1" 2>/dev/null
  if [ -f "$STATE_DIR/$key" ]; then
    chmod "$(cat "$STATE_DIR/$key")" "$1" 2>/dev/null
  fi
}

pick_freq_cap() {
  # pick highest available freq <= WANT from comma/space list
  # args: WANT available_frequencies_file
  want="$1"
  availf="$2"
  [ -f "$availf" ] || { echo "$want"; return; }
  best=0
  for f in $(cat "$availf"); do
    case "$f" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$f" -le "$want" ] && [ "$f" -gt "$best" ]; then
      best=$f
    fi
  done
  if [ "$best" -eq 0 ]; then
    # fallback min
    cat "${availf%available_frequencies}cpuinfo_min_freq" 2>/dev/null || echo "$want"
  else
    echo "$best"
  fi
}

is_protected() {
  p="$1"
  [ -z "$p" ] && return 0
  case "$p" in
    android|dev.axion.spsm) return 0 ;;
    com.android.systemui|com.android.systemui.*) return 0 ;;
    com.android.shell|com.android.settings|com.android.settings.intelligence) return 0 ;;
    com.android.phone|com.android.server.telecom|com.android.incallui) return 0 ;;
    com.android.dialer|com.google.android.dialer|org.lineageos.dialer) return 0 ;;
    com.android.launcher3*|com.android.launcher|app.lawnchair*|com.google.android.apps.nexuslauncher) return 0 ;;
    com.android.deskclock|com.google.android.deskclock|org.lineageos.etar) return 0 ;;
    org.lineageos.backgrounds|org.lineageos.overlay*|com.android.wallpaper*) return 0 ;;
    com.android.contacts|com.android.contacts.*) return 0 ;;
    com.android.mms.service|com.android.providers.telephony|com.android.providers.contacts) return 0 ;;
    com.android.providers.settings|com.android.providers.media|com.android.providers.media.module) return 0 ;;
    com.android.nfc|com.android.bluetooth|com.android.bluetoothmidiservice) return 0 ;;
    com.android.keychain|com.android.se|com.android.location.fused) return 0 ;;
    com.android.permissioncontroller|com.google.android.permissioncontroller) return 0 ;;
    com.android.packageinstaller|com.google.android.packageinstaller) return 0 ;;
    com.android.safetycenter*|com.android.permissioncontroller.*) return 0 ;;
    com.android.inputmethod*|com.google.android.inputmethod*|com.touchtype.swiftkey*) return 0 ;;
    com.android.webview|com.google.android.webview|com.android.chrome.stable) return 0 ;;
    com.google.android.gms|com.google.android.gsf|com.google.android.ext.services|com.google.android.ext.shared) return 0 ;;
    com.android.networkstack*|com.android.wifi*|com.android.connectivity*) return 0 ;;
    com.android.cellbroadcast*|com.android.emergency|com.android.smspush|com.android.stk) return 0 ;;
    com.android.ims*|com.android.imsservice*|org.codeaurora.ims|com.mediatek.ims) return 0 ;;
    com.android.vpndialogs|com.android.externalstorage|com.android.localtransport) return 0 ;;
    com.android.intentresolver|com.android.documentsui) return 0 ;;
    com.android.modulemetadata|com.android.dynsystem|com.android.rkpd*) return 0 ;;
    com.android.microdroid*|com.android.virtualization*|com.android.uwb*) return 0 ;;
    com.android.ons|com.android.proxyhandler|com.android.pacprocessor) return 0 ;;
    com.android.theme*|com.android.internal.*|android.overlay*|com.android.overlay*) return 0 ;;
    *overlay*|*Overlay*) return 0 ;;
    com.mediatek.*|vendor.mediatek.*|com.android.mtk*) return 0 ;;
    me.weishu.kernelsu|com.rifsxd.ksunext|me.bmax.apatch|com.sukisu.ultra|io.github.huskydg.magisk|com.topjohnwu.magisk) return 0 ;;
  esac
  echo "$p" | grep -qiE 'magisk|kernelsu|sukisu|ksunext|apatch|lsposed|zygisk|riru|edxposed|superuser' && return 0
  if [ -f "$SPSM_DIR/ime.txt" ] && grep -qx "$p" "$SPSM_DIR/ime.txt" 2>/dev/null; then
    return 0
  fi
  if [ -f "$WHITELIST" ] && grep -qx "$p" "$WHITELIST" 2>/dev/null; then
    return 0
  fi
  if [ -f "$SPSM_DIR/launchers.txt" ] && grep -qx "$p" "$SPSM_DIR/launchers.txt" 2>/dev/null; then
    return 0
  fi
  return 1
}

collect_imes() {
  ime list -s 2>/dev/null | awk -F/ '{print $1}' | sort -u > "$SPSM_DIR/ime.txt"
}

collect_launchers() {
  # keep other launchers unsuspended so Home role can be restored
  dumpsys package | grep -A1 'android.intent.category.HOME' >/dev/null 2>&1
  pm query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
    | awk '{print $1}' | awk -F/ '{print $1}' | grep -v '^dev.axion.spsm$' | sort -u > "$SPSM_DIR/launchers.txt"
}

detect_home() {
  h=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | head -1)
  if [ -z "$h" ]; then
    h=$(cmd shortcut get-default-home 2>/dev/null | head -1)
  fi
  echo "$h"
}
