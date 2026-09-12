package dev.axion.spsm;

import java.io.BufferedReader;
import java.io.InputStreamReader;

final class Root {
    static final String ENTER = "/data/adb/spsm/enter.sh";
    static final String EXIT = "/data/adb/spsm/exit.sh";
    static final String ACTIVE = "/data/adb/spsm/active";
    static final String WHITELIST = "/data/adb/spsm/whitelist.txt";

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

    static void writeWhitelist(String[] pkgs) {
        StringBuilder sb = new StringBuilder();
        for (String p : pkgs) {
            if (p == null || p.length() == 0) continue;
            sb.append("echo ").append(shellQuote(p)).append(" >> ").append(WHITELIST).append("; ");
        }
        exec("mkdir -p /data/adb/spsm; echo -n '' > " + WHITELIST + "; " + sb);
    }

    static String exec(String cmd) {
        Process p = null;
        try {
            // Merge stderr so we cannot deadlock on a full error pipe.
            p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd + " 2>&1"});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder out = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                out.append(line).append('\n');
            }
            p.waitFor();
            return out.toString();
        } catch (Exception ex) {
            return null;
        } finally {
            if (p != null) p.destroy();
        }
    }

    private static String shellQuote(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }
}
