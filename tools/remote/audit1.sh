#!/system/bin/sh
# AxionOS 2.7 power-architecture audit, wave 1: inventory.
# Read-only. Every call time-guarded (this device blocks on some reads).
OUT=/data/local/tmp/audit1.txt
: > "$OUT"; exec >> "$OUT" 2>&1
t() { timeout 12 "$@" 2>/dev/null; }
g() { t grep -l "$@" 2>/dev/null; }

echo "################ ROM AUDIT WAVE 1  $(date '+%F %T') ################"
echo "device=$(t getprop ro.product.device) platform=$(t getprop ro.board.platform) sdk=$(t getprop ro.build.version.sdk)"
echo "build=$(t getprop ro.build.display.id)  fingerprint=$(t getprop ro.build.fingerprint)"
echo "real_kernel=$(cut -d' ' -f3 /proc/version)"

echo; echo "===== A. PARTITIONS ====="
for p in /system /system_ext /product /vendor /odm /vendor_dlkm /system_dlkm /my_product /my_heytap; do
  [ -d "$p" ] && echo "  PRESENT $p  ($(t du -sh $p 2>/dev/null | cut -f1))" || echo "  absent  $p"
done

echo; echo "===== B. APEX PACKAGES ====="
t pm list packages --apex-only 2>/dev/null | sed 's/package://' | head -40
echo "apex_count=$(t pm list packages --apex-only 2>/dev/null | wc -l)"
echo "--- /apex dir ---"
t ls /apex 2>/dev/null | head -30

echo; echo "===== C. POWER / PERF / THERMAL HALS AND SERVICES ====="
echo "--- vendor hw modules matching power/perf/thermal ---"
t ls /vendor/lib64/hw /vendor/lib/hw 2>/dev/null | grep -iE "power|perf|thermal|mtk" | head -20
echo "--- vendor binaries ---"
t ls /vendor/bin/hw 2>/dev/null | grep -iE "power|perf|thermal|mtk" | head -20
t ls /vendor/bin 2>/dev/null | grep -iE "^(mtk|power|perf|thermal|fuelgauger|charger)" | head -25
echo "--- running services/processes matching power/perf/thermal ---"
t ps -A -o PID,CMD 2>/dev/null | grep -iE "power|perf|thermal|mtk" | grep -v grep | head -25
echo "--- dumpsys services list ---"
t dumpsys -l 2>/dev/null | grep -iE "power|thermal|battery|deviceidle|perf|axion" | head -20

echo; echo "===== D. libperfmgr / powerhint ====="
for f in /vendor/etc/powerhint.json /vendor/etc/powerhint*.json /vendor/etc/perfmgr*.json /system/etc/powerhint.json /odm/etc/powerhint.json; do
  [ -f "$f" ] && echo "  FOUND $f ($(wc -c < $f) bytes)"
done
t find /vendor/etc /odm/etc /system/etc -maxdepth 2 -iname '*hint*' 2>/dev/null | head -10
t find /vendor/bin /vendor/lib64 -iname '*perfmgr*' -o -iname '*perfserv*' 2>/dev/null | head -10

echo; echo "===== E. MTK POWER COMPONENTS ====="
echo "--- mtk sysfs interfaces ---"
for d in /sys/class/mtk_power /sys/module/mtk_power /proc/mtk_power /sys/kernel/mtk_power /sys/class/ppm /proc/ppm; do
  [ -e "$d" ] && echo "  PRESENT $d" && t ls "$d" 2>/dev/null | head -12
done
echo "--- ppm / ppm policies ---"
[ -e /proc/ppm ] && t ls /proc/ppm 2>/dev/null | head -10
echo "--- vendor libs ---"
t ls /vendor/lib64 2>/dev/null | grep -iE "libmtk|power|thermal|perf" | head -20
echo "--- mtk props ---"
t getprop 2>/dev/null | grep -iE "mtk.*(power|perf|thermal)|persist.*(power|perf)" | head -20

echo; echo "===== F. AXION-SPECIFIC COMPONENTS ====="
echo "--- packages/bins with axion in the name ---"
t pm list packages 2>/dev/null | grep -i axion | head -15
t ls /system_ext/bin /system/bin 2>/dev/null | grep -i axion | head -10
t find /system_ext /product /system -maxdepth 3 -iname '*axion*' 2>/dev/null | head -20
echo "--- axion props ---"
t getprop 2>/dev/null | grep -iE "axion|axp" | head -20
echo "--- AxKernelManager / kernel manager ---"
t find /system /product /system_ext /data -maxdepth 4 -iname '*kernel*manager*' 2>/dev/null | head -6
t pm list packages 2>/dev/null | grep -iE "franco|kernel|exkernel|smartpack|kprofile" | head -8

echo; echo "===== G. INIT RC FILES (power relevant) ====="
for d in /system/etc/init /system_ext/etc/init /product/etc/init /vendor/etc/init /odm/etc/init /vendor/etc/init/hw; do
  [ -d "$d" ] && echo "--- $d ---" && t ls "$d" 2>/dev/null | grep -iE "power|perf|thermal|mtk|doze|battery|axion" | head -15
done
echo "--- vendor init hw files ---"
t ls /vendor/etc/init/hw 2>/dev/null | head -20

echo; echo "===== H. OVERLAYS (power/battery related) ====="
t find /product/overlay /vendor/overlay /system/overlay /odm/overlay -maxdepth 2 -iname '*.apk' 2>/dev/null | grep -iE "power|battery|doze|thermal|axion|perf|saving" | head -20
echo "overlay_count=$(t find /product/overlay /vendor/overlay /system/overlay -maxdepth 2 -iname '*.apk' 2>/dev/null | wc -l)"
echo "--- Axion overlay dirs ---"
t find /product /system_ext /vendor -maxdepth 3 -type d -iname '*overlay*' 2>/dev/null | head -10

echo; echo "===== I. KERNEL POWER INTERFACES ====="
for f in /sys/power/state /sys/power/mem_sleep /sys/power/autosleep /sys/power/wake_lock /sys/power/wake_unlock /sys/kernel/rcu_expedited /sys/devices/system/cpu/sched_energy_aware; do
  [ -e "$f" ] && echo "  $(basename $f) = $(t cat $f | head -c 120)"
done
echo "--- available cpuidle states per cluster ---"
for c in cpu0 cpu6; do
  for s in /sys/devices/system/cpu/$c/cpuidle/state*; do
    [ -d "$s" ] && echo "  $c $(basename $s) name=$(t cat $s/name) desc=$(t cat $s/desc) latency=$(t cat $s/latency) residency=$(t cat $s/residency) usage=$(t cat $s/usage)"
  done
done
echo "--- thermal zones ---"
t ls /sys/class/thermal 2>/dev/null | head -20

echo; echo "===== J. DEVICEIDLE / DOZE CONFIG ====="
t dumpsys deviceidle 2>/dev/null | sed -n '/Flags:/,/^$/p' | head -12
t dumpsys deviceidle 2>/dev/null | sed -n '/Settings:/,/^$/p' | head -40

echo; echo "===== K. BATTERY / POWER PROFILES ====="
t dumpsys batterymanager 2>/dev/null | head -25
echo "--- power profile file ---"
t find /system /vendor /product -maxdepth 4 -iname 'power_profile*.xml' 2>/dev/null | head -5

echo; echo "################ END $(date '+%F %T') ################"
