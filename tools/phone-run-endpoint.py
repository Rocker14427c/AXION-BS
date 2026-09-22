#!/usr/bin/env python3
# Run-on-phone endpoint, path-addressed. No query string.
#
#   GET /<token>/<name>   fetch tools/remote/<name> from the GitHub repo,
#                         run it as root IN THE BACKGROUND, return instantly
#   GET /<token>/_out/<name>   return that script's output so far
#   GET /<token>          liveness probe
#
# Why path-only: the caller's page fetcher intermittently rewrites any URL that
# carries a query string into a signed proxy link whose signature does not
# match, so every "?c=" request fails while bare paths succeed. Paths are also
# short, which the same fetcher needs.
#
# Why background + poll: some probes call dumpsys, which takes long enough on
# this ROM to outlast the fetcher. Returning immediately and reading the output
# in a second request removes every timeout from the design.
#
# Why fetch from GitHub: the repo is public and the phone has normal internet,
# so new probes are delivered by pushing them. The endpoint never changes and
# the operator never pastes again.
import http.server, socketserver, subprocess, sys, os, threading, urllib.parse, urllib.request

T = sys.argv[1]
P = int(sys.argv[2]) if len(sys.argv) > 2 else 8099
TMP = os.environ.get("SPSM_TMP", "/data/local/tmp")
BASE = os.environ.get(
    "SPSM_RAW",
    "https://raw.githubusercontent.com/Rocker14427c/AXION-BS/"
    "arena/01a0c508-axion-bs/tools/remote/",
)
SU = os.environ.get("SPSM_SU", "su")
MAX = 200000


def fetch(name):
    return urllib.request.urlopen(BASE + name, timeout=30).read().decode("utf-8", "replace")


def start(name):
    """Kick off a probe and answer immediately.

    The download and the run both happen on a worker thread. Doing the download
    inline is what made the relay report "# no tunnel here": the request sat
    waiting on a GitHub round trip from the phone, outlasted the relay's
    patience, and looked exactly like a dead tunnel even though the server was
    fine and answering other paths.
    """
    tag = name.replace("/", "_")
    out = "%s/remote-%s.out" % (TMP, tag)
    threading.Thread(target=_run, args=(name, tag, out), daemon=True).start()
    return "started %s\noutput will be at %s\n" % (name, out)


def _run(name, tag, out):
    try:
        src = fetch(name)
    except Exception as e:
        _append(out, "FETCH ERROR %s: %r\n[done rc=99]\n" % (name, e))
        return
    script = "%s/remote-%s.sh" % (TMP, tag)
    try:
        with open(script, "w") as fh:
            fh.write(src)
    except Exception as e:
        _append(out, "WRITE ERROR: %r\n[done rc=98]\n" % e)
        return
    cmd = "sh %s > %s 2>&1; echo \"[done rc=$?]\" >> %s" % (script, out, out)
    try:
        subprocess.Popen([SU, "-c", cmd])
    except Exception as e:
        _append(out, "EXEC ERROR: %r\n[done rc=97]\n" % e)


def _append(path, text):
    try:
        with open(path, "a") as fh:
            fh.write(text)
    except Exception:
        pass


def _unused_start(name):
    tag = name.replace("/", "_")
    script = "%s/remote-%s.sh" % (TMP, tag)
    out = "%s/remote-%s.out" % (TMP, tag)
    try:
        with open(script, "w") as fh:
            fh.write(src)
    except Exception as e:
        return "WRITE ERROR: %r" % e
    # The trailing marker is what tells a later poll the run has finished
    # rather than merely produced partial output.
    cmd = "sh %s > %s 2>&1; echo \"[done rc=$?]\" >> %s" % (script, out, out)
    subprocess.Popen([SU, "-c", cmd])
    return "started %s\noutput will be at %s\n" % (name, out)


def catout(name):
    out = "%s/remote-%s.out" % (TMP, name.replace("/", "_"))
    try:
        with open(out) as fh:
            data = fh.read()
    except Exception:
        return "(no output file yet for %s)\n" % name
    return data[:MAX] + ("\n...[truncated]\n" if len(data) > MAX else "")


class H(http.server.BaseHTTPRequestHandler):
    def _s(self, b, code=200):
        b = b.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        parts = [x for x in urllib.parse.urlparse(self.path).path.split("/") if x]
        if not parts or parts[0] != T:
            return self._s("nope\n", 404)
        if len(parts) == 1:
            return self._s("ready. /%s/<name> runs it, /%s/_out/<name> reads it\n" % (T, T))
        if parts[1] == "_out":
            if len(parts) < 3:
                return self._s("usage: _out/<name>\n")
            return self._s(catout("/".join(parts[2:])))
        return self._s(start("/".join(parts[1:])))

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


print("READY 127.0.0.1:%d base=%s" % (P, BASE), flush=True)
S(("127.0.0.1", P), H).serve_forever()
