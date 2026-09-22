import http.server, socketserver, subprocess, sys
T = sys.argv[1]; P = int(sys.argv[2]) if len(sys.argv) > 2 else 8099
# name -> (needs root, shell string). FIXED list: no arbitrary commands accepted.
A = {
 "config":(1,"cat /data/adb/spsm/config"),
 "log":(1,"tail -n 150 /data/adb/spsm/spsm.log"),
 "status":(1,"sh /data/adb/spsm/scripts/engine.sh status 2>&1 | head -60"),
 "id":(0,"id; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.display.id"),
 "doze":(0,"dumpsys deviceidle | head -70"),
 "whitelist":(0,"dumpsys deviceidle whitelist | head -60"),
 "power":(0,"dumpsys power | head -50"),
 "alarms":(0,"dumpsys alarm | head -100"),
 "jobs":(0,"dumpsys jobscheduler | head -100"),
 "wifi":(0,"dumpsys wifi | head -80"),
 "telephony":(0,"dumpsys telephony.registry | head -50"),
 "sensors":(0,"dumpsys sensorservice | head -100"),
 "props":(0,"getprop | grep -iE 'axion|realme|oplus|mtk|doze|deviceidle|thermal' | head -70"),
 "battstats":(0,"dumpsys batterystats --charged | head -120"),
 "wakeup":(1,"cat /sys/kernel/debug/wakeup_sources 2>/dev/null | head -80 || for d in /sys/class/wakeup/wakeup*; do echo \"$d $(cat $d/name 2>/dev/null) act=$(cat $d/active_count 2>/dev/null) prev=$(cat $d/prevent_suspend_time_ms 2>/dev/null)\"; done"),
 "suspend":(1,"for f in /sys/power/suspend_stats/*; do echo \"$f: $(cat $f 2>/dev/null)\"; done; echo wakeup_count=$(cat /sys/power/wakeup_count 2>/dev/null)"),
 "cpuidle":(1,"for c in /sys/devices/system/cpu/cpu[0-9]*; do for s in $c/cpuidle/state[0-9]*; do [ -d $s ] && echo \"$(basename $c) $(basename $s) $(cat $s/name) usage=$(cat $s/usage) time=$(cat $s/time)\"; done; done"),
 "freq":(1,"for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do echo \"== $p gov=$(cat $p/scaling_governor) cur=$(cat $p/scaling_cur_freq)\"; cat $p/stats/time_in_state 2>/dev/null; done"),
 "battery":(1,"for f in current_now voltage_now capacity charge_counter status; do echo \"$f=$(cat /sys/class/power_supply/battery/$f 2>/dev/null)\"; done"),
 "interrupts":(1,"cat /proc/interrupts | head -60"),
 "thermal":(1,"for z in /sys/class/thermal/thermal_zone[0-9]*; do echo \"$(basename $z) $(cat $z/type) $(cat $z/temp)\"; done"),
}
def run(n):
    r, c = A[n]
    try:
        argv = ["su","-c",c] if r else ["sh","-c",c]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=90)
        o = (p.stdout or "") + (("\n[stderr]\n"+p.stderr) if p.stderr else "")
        return (o[:110000] + "\n...[truncated]") if len(o) > 110000 else (o or "(empty)")
    except Exception as e:
        return "ERROR: %r" % e
class H(http.server.BaseHTTPRequestHandler):
    def _s(self, b, code=200):
        b = b.encode("utf-8","replace")
        self.send_response(code); self.send_header("Content-Type","text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        q = [x for x in self.path.split("/") if x]
        if not q or q[0] != T: return self._s("nope\n", 404)
        if len(q) == 1: return self._s("available: " + " ".join(sorted(A)) + "\n")
        if q[1] not in A: return self._s("unknown. available: " + " ".join(sorted(A)) + "\n", 404)
        self._s(run(q[1]))
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
print("listening 127.0.0.1:%d token=%s" % (P, T), flush=True)
print("cmds: %s" % " ".join(sorted(A)), flush=True)
socketserver.TCPServer(("127.0.0.1", P), H).serve_forever()
