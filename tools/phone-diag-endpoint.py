#!/data/data/com.termux/files/usr/bin/python3
# SPSM read-only diagnostic endpoint for Termux.
#
# SAFETY, on purpose: this runs ONLY the commands listed in ALLOWED. It does not
# accept arbitrary shell. If this URL ever leaked, the worst anyone could do is
# read the same diagnostics you can read yourself. There is no write, no delete,
# and no way to run anything not on this list.
#
# Token is in the path, so the list is not even visible without it.

import http.server, socketserver, subprocess, sys, json

TOKEN = sys.argv[1] if len(sys.argv) > 1 else "notoken"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8099

# name -> (needs_root, argv)
ALLOWED = {
    "config":      (True,  "cat /data/adb/spsm/config"),
    "log":         (True,  "tail -n 200 /data/adb/spsm/spsm.log"),
    "status":      (True,  "sh /data/adb/spsm/scripts/engine.sh status"),
    "knobs":       (True,  "cat /data/adb/spsm/state/knobs.list 2>/dev/null | head -60"),
    "deviceidle":  (False, "dumpsys deviceidle"),
    "doze":        (False, "dumpsys deviceidle | head -80"),
    "whitelist":   (False, "dumpsys deviceidle whitelist"),
    "power":       (False, "dumpsys power | head -60"),
    "alarms":      (False, "dumpsys alarm | head -120"),
    "jobs":        (False, "dumpsys jobscheduler | head -120"),
    "wifi":        (False, "dumpsys wifi | head -100"),
    "telephony":   (False, "dumpsys telephony.registry | head -60"),
    "sensors":     (False, "dumpsys sensorservice | head -120"),
    "location":    (False, "dumpsys location | head -80"),
    "battstats":   (False, "dumpsys batterystats --charged | head -150"),
    "procs":       (False, "dumpsys activity processes | head -150"),
    "wakeup":      (True,  "cat /sys/kernel/debug/wakeup_sources 2>/dev/null || for d in /sys/class/wakeup/wakeup*; do echo \"$d $(cat $d/name 2>/dev/null) $(cat $d/active_count 2>/dev/null) $(cat $d/prevent_suspend_time_ms 2>/dev/null)\"; done"),
    "suspend":     (True,  "for f in /sys/power/suspend_stats/*; do echo \"$f: $(cat $f 2>/dev/null)\"; done; echo \"wakeup_count: $(cat /sys/power/wakeup_count 2>/dev/null)\""),
    "cpuidle":     (True,  "for c in /sys/devices/system/cpu/cpu[0-9]*; do for s in $c/cpuidle/state[0-9]*; do [ -d $s ] && echo \"$(basename $c) $(basename $s) $(cat $s/name) usage=$(cat $s/usage) time=$(cat $s/time)\"; done; done"),
    "freq":        (True,  "for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do echo \"== $p gov=$(cat $p/scaling_governor) cur=$(cat $p/scaling_cur_freq)\"; cat $p/stats/time_in_state 2>/dev/null; done"),
    "battery":     (True,  "for f in current_now voltage_now capacity charge_counter status; do echo \"$f: $(cat /sys/class/power_supply/battery/$f 2>/dev/null)\"; done"),
    "interrupts":  (True,  "cat /proc/interrupts"),
    "thermal":     (True,  "for z in /sys/class/thermal/thermal_zone[0-9]*; do echo \"$(basename $z) $(cat $z/type) $(cat $z/temp)\"; done"),
    "props":       (False, "getprop | grep -iE 'axion|realme|oplus|mtk|vendor.power|doze|deviceidle|thermal' | head -80"),
    "id":          (False, "id; echo ---; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.display.id"),
}

MAX_BYTES = 120000


def run(name):
    root, cmd = ALLOWED[name]
    try:
        if root:
            p = subprocess.run(["su", "-c", cmd], capture_output=True, text=True, timeout=90)
        else:
            p = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=90)
        out = (p.stdout or "") + (("\n[stderr]\n" + p.stderr) if p.stderr else "")
        if len(out) > MAX_BYTES:
            out = out[:MAX_BYTES] + "\n...[truncated]"
        return out or "(empty)"
    except Exception as e:
        return "ERROR: %r" % e


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body, code=200):
        b = body.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        parts = [p for p in self.path.split("/") if p]
        if not parts or parts[0] != TOKEN:
            return self._send("nope\n", 404)
        if len(parts) == 1:
            return self._send("available: " + " ".join(sorted(ALLOWED)) + "\n")
        name = parts[1]
        if name not in ALLOWED:
            return self._send("unknown command. available: " + " ".join(sorted(ALLOWED)) + "\n", 404)
        self._send(run(name))

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
print("listening on 127.0.0.1:%d  token=%s" % (PORT, TOKEN), flush=True)
print("commands: %s" % " ".join(sorted(ALLOWED)), flush=True)
socketserver.TCPServer(("127.0.0.1", PORT), H).serve_forever()
