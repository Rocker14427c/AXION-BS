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
    static final String DIR = "/data/adb/spsm";

    private Root() {}

    static boolean available() {
        String out = exec("id");
        return out != null && out.contains("uid=0");
    }

    static boolean isActive() {
        String out = exec("[ -f " + ACTIVE + " ] && echo ON || echo OFF");
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
        exec("mkdir -p " + DIR + "/state && echo " + state + " > " + DIR + "/state/screen; "
           + "p=$(cat " + DIR + "/daemon.pid 2>/dev/null); "
           + "if [ -n \"$p\" ] && [ -d \"/proc/$p\" ]; then "
           + "  kill -USR1 \"$p\" 2>/dev/null; "
           + "else sh " + DIR + "/scripts/engine.sh screen-" + state + " >/dev/null 2>&1; fi; "
           + "exit 0");
    }

    /** Progress text the engine publishes while it is applying or reverting. */
    static String progress() {
        return exec("cat " + DIR + "/state/progress 2>/dev/null");
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
