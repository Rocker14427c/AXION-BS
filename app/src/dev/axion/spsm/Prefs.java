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
