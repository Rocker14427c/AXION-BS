package dev.axion.spsm;

import java.io.BufferedReader;
import java.io.InputStreamReader;

final class Root {
    static final String ENTER = "/data/adb/spsm/enter.sh";
    static final String EXIT = "/data/adb/spsm/exit.sh";
    // The engine's own marker (lib.sh: ACTIVE="$STATE/active"). The old path
    // here - /data/adb/spsm/active - is a file nothing has ever written, so
    // isActive() was always false: the app's button stayed "Turn on" while the
    // mode ran, and the tile never once showed itself active. Two symptoms,
    // one wrong path.
    static final String ACTIVE = "/data/adb/spsm/state/active";
    static final String WHITELIST = "/data/adb/spsm/whitelist.txt";
    // Apps the owner wants alive in the background. Written by the engine's own
    // `keep` verb rather than by this app directly, so that adding an app here
    // releases it immediately if the mode has it frozen right now - the reason
    // the screen exists at all.
    static final String KEEP = "/data/adb/spsm/keep_awake.txt";
    static final String ENGINE = "/data/adb/spsm/scripts/engine.sh";
    static final String DIR = "/data/adb/spsm";

    private Root() {}

    static boolean available() {
        String out = exec("id");
        return out != null && out.contains("uid=0");
    }

    static boolean isActive() {
        String out = read("[ -f " + ACTIVE + " ] && echo ON || echo OFF");
        return out != null && out.contains("ON");
    }

    static boolean modulePresent() {
        String out = exec(
                "if [ -x " + ENTER + " ] || [ -f /data/adb/modules/axion_spsm/scripts/enter.sh ]; then echo YES; else echo NO; fi");
        return out != null && out.contains("YES");
    }

    static String enter() {
        return exec("sh " + ENTER);
    }

    static String exit() {
        return exec("sh " + EXIT);
    }

    /**
     * Publishes the new screen state and wakes the daemon immediately.
     *
     * The file alone would only be read when the daemon's poll came round - up
     * to 8 seconds of capped CPU after the user presses the power button.
     * SIGUSR1 cuts its sleep short, so leaving the screen-off state is instant.
     */
    static void writeScreenState(String state) {
        // One writer whenever possible: if the daemon is alive it does the work,
        // and the signal means it starts now instead of at the next poll. If it
        // is not running, do the work here - the screen change must never leave
        // a CPU cap behind for even a few seconds.
        // The screen monitor is poked as well as the daemon, when there is one.
        //
        // The daemon spends its wait blocked reading the monitor's pipe, and
        // whether a USR1 trap can break a blocking read is shell-dependent:
        // dash returns and runs the trap, bash restarts the read and the
        // handler does not run until data actually arrives. Waking the monitor
        // makes it write a line, and the line unblocks the daemon on every
        // shell - so the poke is delivered by the pipe, not by the signal.
        read("mkdir -p " + DIR + "/state && echo " + state + " > " + DIR + "/state/screen; "
           + "m=$(cat " + DIR + "/state/monitor.pid 2>/dev/null); "
           + "[ -n \"$m\" ] && [ -d \"/proc/$m\" ] && kill -USR1 \"$m\" 2>/dev/null; "
           + "p=$(cat " + DIR + "/daemon.pid 2>/dev/null); "
           + "if [ -n \"$p\" ] && [ -d \"/proc/$p\" ]; then "
           + "  kill -USR1 \"$p\" 2>/dev/null; "
           + "else sh " + DIR + "/scripts/engine.sh screen-" + state + " >/dev/null 2>&1; fi; "
           + "exit 0");
    }

    /** The apps the owner has asked to keep running in the background. */
    static String[] keepList() {
        String out = exec("sh " + ENGINE + " keep list 2>/dev/null");
        if (out == null) return new String[0];
        java.util.List<String> out2 = new java.util.ArrayList<>();
        for (String line : out.split("\n")) {
            String p = line.trim();
            if (p.length() > 0 && p.indexOf('.') > 0 && p.indexOf(' ') < 0) out2.add(p);
        }
        return out2.toArray(new String[0]);
    }

    /** Adds or removes one app. Both go through the engine, not the file. */
    static boolean keep(String pkg, boolean on) {
        String out = exec("sh " + ENGINE + " keep " + (on ? "add " : "remove ")
                + (on ? "" : "") + pkg + " 2>&1");
        return out != null && !out.contains("not a package name");
    }

    /** Progress text the engine publishes while it is applying or reverting. */
    static String progress() {
        // Polled every 400 ms by the setup screen while the engine works, so
        // it uses the `read` builtin rather than forking a cat each time.
        return read("p=''; f=" + DIR + "/state/progress; "
                + "[ -f $f ] && { read p < $f 2>/dev/null || :; }; "
                + "[ -n \"$p\" ] && echo \"$p\" || :");
    }

    /** Human readable summary of what is currently applied. */
    static String status() {
        return exec("sh " + DIR + "/scripts/engine.sh status 2>/dev/null");
    }

    static void writeWhitelist(String[] pkgs) {
        StringBuilder sb = new StringBuilder();
        for (String p : pkgs) {
            if (p == null || p.length() == 0) continue;
            sb.append("echo ").append(shellQuote(p)).append(" >> ").append(WHITELIST).append("; ");
        }
        exec("mkdir -p /data/adb/spsm; echo -n '' > " + WHITELIST + "; " + sb);
    }

    static String exec(String cmd) {
        return exec(cmd, 0);
    }

    // ---------------------------------------------------------------------
    // The persistent root shell.
    //
    // Every Root.exec() spawns a whole `su -c`: a fork, the su daemon
    // handshake, a new shell, then teardown - measured at ~1.15 ms per call
    // with a plain sh on a desktop, and a phone's su is a good deal heavier
    // than that. Paid once for a transition it is nothing. But the app also
    // POLLS: the setup screen reads the progress file every 400 ms while the
    // engine works, the tile re-reads state every 2500 ms through a
    // transition, and the knobs screen polls twice every 2 s while probing.
    // Those are hundreds of su spawns to read a few bytes out of two small
    // files, and every one of them is a root handshake the user pays for in
    // latency and battery.
    //
    // So short reads go down ONE shell that stays open, and a command is just
    // a line written to its stdin. The same measurement across a pipe is
    // ~0.04 ms - 28x cheaper - and the saving grows on a real su.
    //
    // Deliberately NOT used for long work (enter, exit, probe, pm list). A
    // single shell serialises whatever goes down it, so a command that runs
    // for a minute would block every status read behind it - and the existing
    // timeout, which works by destroying the process, cannot bound one
    // command without killing the session. Long jobs keep their own su, where
    // those semantics already hold. Short reads get the fast path; everything
    // else behaves exactly as before.
    // ---------------------------------------------------------------------

    private static final Object SESSION_LOCK = new Object();
    private static Process session;
    private static java.io.Writer sessionIn;
    private static BufferedReader sessionOut;
    private static String marker;
    private static long lastUsed;
    private static Thread reaper;
    // Lines the shell has produced, filled by ONE pump thread per session.
    // The obvious alternative - a watchdog thread per read - costs a thread
    // create and join on every poll, which measured slower than the su spawn
    // it was meant to replace once the spawn itself got cheap.
    private static java.util.concurrent.BlockingQueue<String> lines;
    private static Thread pump;

    /** Idle session teardown: a root shell must not be held open for ever. */
    private static final long IDLE_MS = 20_000L;
    /** A short read that takes this long is a broken session, not a slow one. */
    private static final long READ_TIMEOUT_MS = 5_000L;
    /** Sentinel pushed by the pump when the shell's stdout ends. Compared by
     *  identity, so a shell that literally prints this text cannot fake it. */
    private static final String EOF = new String("\u0000spsm-eof");

    private static void closeSessionLocked() {
        try { if (sessionIn != null) sessionIn.close(); } catch (Exception ignored) {}
        try { if (sessionOut != null) sessionOut.close(); } catch (Exception ignored) {}
        if (session != null) session.destroy();
        if (pump != null) pump.interrupt();
        session = null;
        sessionIn = null;
        sessionOut = null;
        marker = null;
        lines = null;
        pump = null;
    }

    /** Drop the shared root shell (called on idle, and on any protocol fault). */
    static void closeSession() {
        synchronized (SESSION_LOCK) { closeSessionLocked(); }
    }

    private static boolean openSessionLocked() {
        if (session != null) {
            // Still alive? A dead shell looks fine until it is written to.
            try {
                session.exitValue();
                closeSessionLocked();   // it exited; fall through and respawn
            } catch (IllegalThreadStateException alive) {
                return true;
            }
        }
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su"});
            session = p;
            sessionIn = new java.io.OutputStreamWriter(p.getOutputStream());
            sessionOut = new BufferedReader(new InputStreamReader(p.getInputStream()));
            marker = "__SPSM_" + Long.toHexString(System.nanoTime()) + "__";
            final BufferedReader src = sessionOut;
            final java.util.concurrent.BlockingQueue<String> q =
                    new java.util.concurrent.LinkedBlockingQueue<>();
            lines = q;
            pump = new Thread(() -> {
                try {
                    String line;
                    while ((line = src.readLine()) != null) q.put(line);
                } catch (Exception ignored) {
                } finally {
                    // Unblock any reader waiting on a shell that has gone away.
                    q.offer(EOF);
                }
            });
            pump.setDaemon(true);
            pump.setName("spsm-root-pump");
            pump.start();
            if (reaper == null) {
                reaper = new Thread(() -> {
                    for (;;) {
                        try { Thread.sleep(5_000L); } catch (InterruptedException e) { return; }
                        synchronized (SESSION_LOCK) {
                            if (session != null && System.currentTimeMillis() - lastUsed > IDLE_MS) {
                                closeSessionLocked();
                            }
                        }
                    }
                });
                reaper.setDaemon(true);
                reaper.setName("spsm-root-reaper");
                reaper.start();
            }
            return true;
        } catch (Exception e) {
            closeSessionLocked();
            return false;
        }
    }

    /**
     * Run a SHORT command down the shared root shell and return its output.
     *
     * Returns null if the session could not be used, exactly like exec() does
     * on failure - so every existing "null means it said nothing, leave the UI
     * alone" path keeps working unchanged.
     */
    static String read(String cmd) {
        synchronized (SESSION_LOCK) {
            String out = readOnce(cmd);
            if (out != null) return out;
            // One retry on a fresh shell: the old one may have been reaped or
            // killed by the su daemon between calls, which is normal and must
            // not surface as a failed read.
            closeSessionLocked();
            out = readOnce(cmd);
            if (out != null) return out;
        }
        // Still nothing - fall back to the one-shot path so a caller is never
        // worse off than it was before the session existed.
        return exec(cmd, 10);
    }

    private static String readOnce(String cmd) {
        if (!openSessionLocked()) return null;
        final String mark = marker;
        try {
            // A SUBSHELL, not a brace group: several callers end their script
            // with `exit 0`, which inside a brace group would terminate the
            // session shell itself. A subshell also keeps variables and cd
            // from leaking between unrelated reads.
            //
            // stdin comes from /dev/null so a command that reads (a bare cat,
            // say) cannot swallow the next command off the pipe and desync the
            // protocol. stderr is merged, matching exec().
            sessionIn.write("(\n" + cmd + "\n) </dev/null 2>&1\n");
            sessionIn.write("echo " + mark + "\n");
            sessionIn.flush();
        } catch (Exception e) {
            return null;
        }
        // Bounded by the queue's own timed poll - no per-read thread. A wedged
        // shell must not hang a UI thread's worker for ever.
        final StringBuilder b = new StringBuilder();
        boolean done = false;
        final long deadline = System.currentTimeMillis() + READ_TIMEOUT_MS;
        final java.util.concurrent.BlockingQueue<String> q = lines;
        try {
            for (;;) {
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) break;
                String line = q.poll(left, java.util.concurrent.TimeUnit.MILLISECONDS);
                if (line == null) break;                       // timed out
                if (line == EOF) break;                        // shell gone (identity, not equals)
                if (line.equals(mark)) { done = true; break; }
                b.append(line).append('\n');
            }
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
        if (!done) {
            // Timed out or the stream ended early: the session is no longer
            // trustworthy - its output and our commands may now be out of step.
            closeSessionLocked();
            return null;
        }
        lastUsed = System.currentTimeMillis();
        return b.toString();
    }

    /**
     * Run a command as root and read its output.
     *
     * The watchdog is not decoration: a read with no end let the tile sit on
     * "working" for five minutes when a su stream never came back after a
     * transition was pressed twice. `timeoutSec` bounds the wait - 0 means no
     * bound, for the few callers that legitimately stream.
     */
    static String exec(String cmd, int timeoutSec) {
        final Process[] holder = new Process[1];
        final StringBuilder[] out = new StringBuilder[1];
        Thread reader = new Thread(() -> {
            Process p = null;
            try {
                // Merge stderr so we cannot deadlock on a full error pipe.
                p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd + " 2>&1"});
                holder[0] = p;
                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                StringBuilder b = new StringBuilder();
                String line;
                while ((line = r.readLine()) != null) {
                    b.append(line).append('\n');
                }
                p.waitFor();
                out[0] = b;
            } catch (Exception ignored) {
            } finally {
                if (p != null) p.destroy();
            }
        });
        reader.setDaemon(true);
        reader.start();
        if (timeoutSec <= 0) {
            try {
                reader.join();
            } catch (InterruptedException ignored) {
            }
        } else {
            try {
                reader.join(timeoutSec * 1000L);
            } catch (InterruptedException ignored) {
            }
            if (reader.isAlive() && holder[0] != null) {
                holder[0].destroy();
            }
        }
        return out[0] == null ? null : out[0].toString();
    }

    /**
     * Run a command as root WITHOUT waiting for it: the shell forks the work
     * and returns at once, so the caller - a tile service the system may unbind
     * at any moment - is never the thing keeping a transition alive.
     */
    static void execDetached(String cmd) {
        new Thread(() -> {
            try {
                Runtime.getRuntime().exec(new String[]{"su", "-c", cmd + " 2>&1"}).waitFor();
            } catch (Exception ignored) {
            }
        }).start();
    }

    private static String shellQuote(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }
}
