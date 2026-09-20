package dev.axion.spsm;

import android.content.Context;
import android.content.SharedPreferences;

final class Prefs {
    private static final String NAME = "spsm";
    private static final String KEY_SLOT = "slot_";

    private Prefs() {}

    static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(NAME, Context.MODE_PRIVATE);
    }

    static String getSlot(Context c, int i) {
        return sp(c).getString(KEY_SLOT + i, "");
    }

    static void setSlot(Context c, int i, String pkg) {
        sp(c).edit().putString(KEY_SLOT + i, pkg == null ? "" : pkg).apply();
        syncWhitelist(c);
    }

    /**
     * Writes the six slots to the module's keep-list and tells the engine.
     *
     * The six slots ARE the "keep working" list, so the module has to be told
     * every time it changes: an app added to a slot is freed at once if the
     * module had blocked it, and an app taken out becomes subject to the mode
     * again. Without this the mode kept blocking an app the user had just added,
     * and opening it answered "app suspended".
     */
    static void syncWhitelist(Context c) {
        // Same writer the turn-on path uses, so there is one quoting and one
        // format for the file both of them read. The set is de-duplicated
        // first: whatever the picker already refuses, an old preference file
        // must not be able to smuggle a double entry past the module.
        java.util.LinkedHashSet<String> seen = new java.util.LinkedHashSet<>();
        for (String s : getAll(c)) if (s != null && s.length() > 0) seen.add(s);
        final String[] slots = seen.toArray(new String[0]);
        new Thread(() -> {
            Root.writeWhitelist(slots);
            Root.exec("sh " + Root.DIR + "/scripts/engine.sh allow >/dev/null 2>&1");
        }).start();
    }

    static String[] getAll(Context c) {
        String[] a = new String[6];
        for (int i = 0; i < 6; i++) a[i] = getSlot(c, i);
        return a;
    }

    static boolean hasAny(Context c) {
        for (String s : getAll(c)) {
            if (s != null && s.length() > 0) return true;
        }
        return false;
    }
}
