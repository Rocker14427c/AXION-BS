package dev.axion.spsm;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

final class Apps {
    static class Item {
        final String pkg;
        final String label;
        final Drawable icon;
        Item(String pkg, String label, Drawable icon) {
            this.pkg = pkg;
            this.label = label;
            this.icon = icon;
        }
    }

    private Apps() {}

    static void bindSlot(final Context c, LinearLayout slot, final int index, final SlotClick click) {
        ImageView icon = slot.findViewById(R.id.icon);
        TextView label = slot.findViewById(R.id.label);
        String pkg = Prefs.getSlot(c, index);
        if (pkg == null || pkg.length() == 0) {
            icon.setImageResource(R.drawable.ic_plus);
            label.setText(R.string.empty_slot);
        } else {
            PackageManager pm = c.getPackageManager();
            try {
                ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                icon.setImageDrawable(pm.getApplicationIcon(ai));
                label.setText(pm.getApplicationLabel(ai));
            } catch (Exception e) {
                icon.setImageResource(R.drawable.ic_plus);
                label.setText(pkg);
            }
        }
        slot.setOnClickListener(v -> click.onClick(index, false));
        slot.setOnLongClickListener(v -> {
            click.onClick(index, true);
            return true;
        });
    }

    static void fillDefaults(Context c) {
        if (Prefs.hasAny(c)) return;
        String dial = resolve(c, new Intent(Intent.ACTION_DIAL));
        Intent sms = new Intent(Intent.ACTION_SENDTO);
        sms.setData(Uri.parse("smsto:"));
        String msg = resolve(c, sms);
        Intent web = new Intent(Intent.ACTION_VIEW, Uri.parse("https://"));
        String br = resolve(c, web);
        if (dial != null) Prefs.setSlot(c, 0, dial);
        if (msg != null) Prefs.setSlot(c, 1, msg);
        if (br != null) Prefs.setSlot(c, 2, br);
    }

    static String resolve(Context c, Intent intent) {
        try {
            ResolveInfo ri = c.getPackageManager().resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY);
            if (ri != null && ri.activityInfo != null) {
                String pkg = ri.activityInfo.packageName;
                if ("android".equals(pkg)) return null;
                return pkg;
            }
        } catch (Exception ignored) {}
        return null;
    }

    /**
     * Apps a user can put in a slot.
     *
     * This used to ask only for activities that answer MAIN/LAUNCHER, which is
     * how a launcher draws its drawer - and it left out exactly the apps that
     * matter most here. A hidden root manager, or any app whose launcher entry
     * has been disabled, has no such activity, so it simply was not offered: the
     * user could not allow the app they use to get out of trouble. Root managers
     * are also the apps most likely to be hidden deliberately.
     *
     * So the list is built from what is installed rather than from what is in
     * the drawer: every app that has a launcher entry, plus every user-installed
     * app, plus the known root managers. Disabled components are matched
     * explicitly, and each package appears once no matter how many activities it
     * has.
     */
    static List<Item> launchable(Context c) {
        PackageManager pm = c.getPackageManager();
        List<ApplicationInfo> installed;
        try {
            installed = pm.getInstalledApplications(PackageManager.MATCH_DISABLED_COMPONENTS);
        } catch (Throwable t) {
            installed = pm.getInstalledApplications(0);
        }
        List<Item> out = new ArrayList<>();
        if (installed == null) return out;
        for (ApplicationInfo ai : installed) {
            if (ai == null || ai.packageName == null) continue;
            String pkg = ai.packageName;
            if ("dev.axion.spsm".equals(pkg)) continue;
            boolean hasLauncher;
            try {
                hasLauncher = pm.getLaunchIntentForPackage(pkg) != null;
            } catch (Throwable t) {
                hasLauncher = false;
            }
            boolean systemApp = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
            // A system app with no launcher entry is an internal component, not
            // something to put on a home screen; a user app is kept either way.
            if (!hasLauncher && systemApp && !isRootManager(pkg)) continue;
            CharSequence lab = null;
            Drawable ic = null;
            try { lab = pm.getApplicationLabel(ai); } catch (Throwable ignored) {}
            try { ic = pm.getApplicationIcon(ai); } catch (Throwable ignored) {}
            out.add(new Item(pkg, lab == null ? pkg : lab.toString(), ic));
        }
        Collections.sort(out, new Comparator<Item>() {
            @Override public int compare(Item a, Item b) {
                return a.label.compareToIgnoreCase(b.label);
            }
        });
        return out;
    }

    /** Root/kernel managers: never hidden from the list, never restricted. */
    static boolean isRootManager(String pkg) {
        for (String p : ROOT_MANAGERS) {
            if (p.equals(pkg)) return true;
        }
        return false;
    }

    static final String[] ROOT_MANAGERS = {
            "com.resukisu.resukisu", "me.resukisu.resukisu", "com.resukisu.manager",
            "com.topjohnwu.magisk", "me.weishu.kernelsu", "com.rifsxd.ksunext",
            "com.sukisu.ultra", "com.dergoogler.mmrl", "com.franco.kernel",
            "eu.chainfire.supersu"
    };

    static void launch(Context c, String pkg) {
        if (pkg == null || pkg.length() == 0) return;
        PackageManager pm = c.getPackageManager();
        Intent i = pm.getLaunchIntentForPackage(pkg);
        if (i == null) {
            i = new Intent(Intent.ACTION_MAIN);
            i.addCategory(Intent.CATEGORY_LAUNCHER);
            i.setPackage(pkg);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        } else {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        }
        try {
            c.startActivity(i);
        } catch (Exception ignored) {}
    }

    interface SlotClick {
        void onClick(int index, boolean longPress);
    }
}
