import http.server, socketserver, subprocess, sys, base64, urllib.parse

T = sys.argv[1]
P = int(sys.argv[2]) if len(sys.argv) > 2 else 8099
MAX = 150000

def run(b64):
    try:
        pad = "=" * ((4 - len(b64) % 4) % 4)
        script = base64.urlsafe_b64decode(b64 + pad).decode("utf-8", "replace")
    except Exception as e:
        return "DECODE ERROR: %r" % e
    try:
        p = subprocess.run(["su", "-c", script], capture_output=True,
                           text=True, timeout=200)
        out = (p.stdout or "")
        if p.stderr:
            out += "\n[stderr]\n" + p.stderr
        out += "\n[rc=%d]" % p.returncode
        return out[:MAX] + ("\n...[truncated]" if len(out) > MAX else "")
    except Exception as e:
        return "EXEC ERROR: %r" % e

# THREADED, deliberately. The single-threaded first version was the reason the
# tunnel appeared to "die" after one or two requests: one `su` that blocked on a
# KernelSU prompt, or one slow `dumpsys`, held the only handler forever, and
# every later request queued behind it and timed out. Nothing had actually
# disconnected - the server was just permanently busy.
class H(http.server.BaseHTTPRequestHandler):
    timeout = 25
    def _s(self, b, code=200):
        b = b.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        parts = [x for x in u.path.split("/") if x]
        if not parts or parts[0] != T:
            return self._s("nope\n", 404)
        q = urllib.parse.parse_qs(u.query)
        if "c" not in q:
            return self._s("ready. send ?c=<urlsafe-base64 of a shell script>\n")
        self._s(run(q["c"][0]))

    def log_message(self, *a):
        pass

class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

print("READY listening 127.0.0.1:%d token=%s" % (P, T), flush=True)
S(("127.0.0.1", P), H).serve_forever()
