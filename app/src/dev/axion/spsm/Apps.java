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
        /** "user", "system", "root" or "hidden" - shown under the name. */
        String tag = "";
        Item(String pkg, String label, Drawable icon) {
            this.pkg = pkg;
            this.label = label;
            this.icon = icon;
        }
        Item(String pkg, String label, Drawable icon, String tag) {
            this.pkg = pkg;
            this.label = label;
            this.icon = icon;
            this.tag = tag;
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
            Resolved r = resolveFast(c, pkg);
            if (r != null) {
                show(icon, label, pkg, r);
            } else {
                // Not visible to this app: show what we can now, and fill in the
                // real name and icon from a background thread.
                icon.setImageResource(R.drawable.ic_plus);
                label.setText(pkg);
                final LinearLayout fSlot = slot;
                final String fPkg = pkg;
                new Thread(() -> {
                    final Resolved slow = resolve(c, fPkg);
                    fSlot.post(() -> {
                        ImageView i2 = fSlot.findViewById(R.id.icon);
                        TextView l2 = fSlot.findViewById(R.id.label);
                        show(i2, l2, fPkg, slow);
                    });
                }).start();
            }
        }
        slot.setOnClickListener(v -> click.onClick(index, false));
        slot.setOnLongClickListener(v -> {
            click.onClick(index, true);
            return true;
        });
    }

    private static void show(ImageView icon, TextView label, String pkg, Resolved r) {
        if (r != null && r.icon != null) {
            icon.setImageDrawable(r.icon);
            label.setText(r.label == null ? pkg : r.label);
        } else if (r != null && r.label != null) {
            icon.setImageResource(R.drawable.ic_plus);
            label.setText(r.label);
        } else {
            icon.setImageResource(R.drawable.ic_plus);
            label.setText(pkg);
        }
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
    /**
     * Every package the user could possibly want in a slot. Nothing is filtered
     * out except SPSM itself.
     *
     * The history here is worth keeping: the first version asked the launcher
     * which activities answer MAIN/LAUNCHER and offered only those, which is not
     * the same question as "what is installed" - hidden root managers and apps
     * with a disabled launcher entry were missing. The second version asked the
     * package manager for installed applications, and the user still had apps
     * that did not appear. So now the list is built from two independent
     * sources and merged:
     *
     *   1. PackageManager.getInstalledApplications (labels and icons),
     *   2. `pm list packages` through root, which reports packages regardless of
     *      what this app is allowed to see.
     *
     * Anything only the second source knows about is still offered, by package
     * name, with a placeholder icon. A package the user can see in Settings can
     * therefore always be added here.
     */
    static List<Item> launchable(Context c) {
        PackageManager pm = c.getPackageManager();
        List<Item> out = new ArrayList<>();
        java.util.Set<String> seen = new java.util.HashSet<>();

        List<ApplicationInfo> installed = null;
        try {
            installed = pm.getInstalledApplications(PackageManager.MATCH_DISABLED_COMPONENTS);
        } catch (Throwable t) {
            try { installed = pm.getInstalledApplications(0); } catch (Throwable ignored) {}
        }
        if (installed != null) {
            for (ApplicationInfo ai : installed) {
                if (ai == null || ai.packageName == null) continue;
                String pkg = ai.packageName;
                if ("dev.axion.spsm".equals(pkg)) continue;
                if (!seen.add(pkg)) continue;
                CharSequence lab = null;
                Drawable ic = null;
                try { lab = pm.getApplicationLabel(ai); } catch (Throwable ignored) {}
                try { ic = pm.getApplicationIcon(ai); } catch (Throwable ignored) {}
                out.add(new Item(pkg, lab == null ? pkg : lab.toString(), ic, tagFor(pm, pkg, ai)));
            }
        }

        // Through root, so a package this app cannot see still appears. It is
        // cheap (one shell call) and it is what makes "every app" true rather
        // than "every app the package manager felt like mentioning".
        String listing = Root.exec("pm list packages 2>/dev/null");
        if (listing != null) {
            for (String line : listing.split("\n")) {
                line = line.trim();
                if (!line.startsWith("package:")) continue;
                String pkg = line.substring("package:".length()).trim();
                if (pkg.isEmpty() || "dev.axion.spsm".equals(pkg)) continue;
                if (!seen.add(pkg)) continue;
                // Label and icon through root, so a package this app cannot
                // query still looks like an app instead of a package name with a
                // placeholder.
                Resolved rr = resolve(c, pkg);
                out.add(new Item(pkg,
                        rr.label == null ? pkg : rr.label,
                        rr.icon,
                        isRootManager(pkg) ? "root" : "other"));
            }
        }

        Collections.sort(out, new Comparator<Item>() {
            @Override public int compare(Item a, Item b) {
                return a.label.compareToIgnoreCase(b.label);
            }
        });
        return out;
    }

    private static String tagFor(PackageManager pm, String pkg, ApplicationInfo ai) {
        if (isRootManager(pkg)) return "root";
        boolean systemApp = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
        boolean hasLauncher;
        try {
            hasLauncher = pm.getLaunchIntentForPackage(pkg) != null;
        } catch (Throwable t) {
            hasLauncher = false;
        }
        if (!hasLauncher) return systemApp ? "system" : "hidden";
        return systemApp ? "system" : "user";
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
        Intent i = null;
        try {
            i = pm.getLaunchIntentForPackage(pkg);
        } catch (Throwable ignored) {}
        if (i != null) {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                c.startActivity(i);
                return;
            } catch (Exception ignored) {}
        }
        // The app is not visible to this one (a hidden root manager, most often,
        // which is exactly the app someone needs here). Its launcher component is
        // asked for through root, and started explicitly.
        Resolved r = resolve(c, pkg);
        if (r != null && r.component != null) {
            try {
                Intent ex = new Intent(Intent.ACTION_MAIN);
                ex.addCategory(Intent.CATEGORY_LAUNCHER);
                ex.setComponent(android.content.ComponentName.unflattenFromString(r.component));
                ex.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                c.startActivity(ex);
                return;
            } catch (Exception ignored) {}
            // Still refused: start it as root, off the UI thread. A hidden app
            // cannot always be started on another app's behalf, and this is the
            // phone's own owner asking for their own app.
            final String comp = r.component;
            new Thread(() -> Root.exec("am start -n " + comp + " >/dev/null 2>&1")).start();
            return;
        }
        final String p = pkg;
        new Thread(() -> Root.exec(
                "monkey -p " + p + " -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1")).start();
    }

    /** What we know about a package: name, icon, launcher component. */
    static class Resolved {
        String label;
        Drawable icon;
        String component;
    }

    /** Resolved packages, so the root fallback is paid for once per package. */
    private static final java.util.Map<String, Resolved> CACHE = new java.util.HashMap<>();

    /**
     * Everything needed to show and start an app, including apps this one is not
     * allowed to see.
     *
     * The report that led here was exact: root apps appeared in the list (they
     * come from `pm list packages` through root) but with a placeholder icon, the
     * package name instead of a label, and tapping them did nothing - because
     * every question was asked of this app's PackageManager, which cannot see
     * them. So when the PackageManager says no, the answers are fetched through
     * root instead:
     *
     *   - the APK path (pm path), parsed with getPackageArchiveInfo for the label
     *     and icon - the standard way to read a package the app cannot query;
     *   - the launcher component (cmd package resolve-activity --brief), which is
     *     what makes it startable.
     */
    static Resolved resolve(Context c, String pkg) {
        Resolved cached;
        synchronized (CACHE) { cached = CACHE.get(pkg); }
        if (cached != null) return cached;
        PackageManager pm = c.getPackageManager();
        Resolved r = new Resolved();
        try {
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            try { r.label = pm.getApplicationLabel(ai).toString(); } catch (Throwable ignored) {}
            try { r.icon = pm.getApplicationIcon(ai); } catch (Throwable ignored) {}
        } catch (Throwable ignored) {}
        if (r.icon == null || r.label == null) {
            fillFromArchive(pm, pkg, r);
        }
        if (r.component == null) {
            String out = Root.exec(
                    "cmd package resolve-activity --brief -a android.intent.action.MAIN "
                  + "-c android.intent.category.LAUNCHER " + pkg + " 2>/dev/null | tail -1");
            if (out != null) {
                String line = out.trim();
                int slash = line.indexOf('/');
                if (slash > 0 && line.startsWith(pkg)) {
                    r.component = line;
                }
            }
        }
        synchronized (CACHE) { CACHE.put(pkg, r); }
        return r;
    }

    /**
     * What the PackageManager answers on its own, or null.
     *
     * The home screen calls this on the UI thread: resolve() shells out to root
     * for packages this app cannot query, and a couple of su round trips on the
     * main thread is an ANR. So the fast path is tried first and the slow one is
     * sent to a background thread by the caller.
     */
    static Resolved resolveFast(Context c, String pkg) {
        Resolved cached;
        synchronized (CACHE) { cached = CACHE.get(pkg); }
        if (cached != null) return cached;
        Resolved r = new Resolved();
        PackageManager pm = c.getPackageManager();
        boolean any = false;
        try {
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            any = true;
            try { r.label = pm.getApplicationLabel(ai).toString(); } catch (Throwable ignored) {}
            try { r.icon = pm.getApplicationIcon(ai); } catch (Throwable ignored) {}
        } catch (Throwable ignored) {}
        if (!any) return null;
        synchronized (CACHE) { CACHE.put(pkg, r); }
        return r;
    }

    /** Label and icon read straight out of the APK, for a package we cannot query. */
    private static void fillFromArchive(PackageManager pm, String pkg, Resolved r) {
        String path = Root.exec("pm path " + pkg + " 2>/dev/null | head -1");
        if (path == null) return;
        path = path.trim();
        if (path.startsWith("package:")) path = path.substring("package:".length()).trim();
        if (path.isEmpty()) return;
        try {
            android.content.pm.PackageInfo pi = pm.getPackageArchiveInfo(path, 0);
            ApplicationInfo ai = pi == null ? null : pi.applicationInfo;
            if (ai == null) return;
            // Both paths have to be set or loadIcon/loadLabel throw - the
            // archive info knows nothing about where its resources live.
            ai.sourceDir = path;
            ai.publicSourceDir = path;
            if (r.label == null) {
                try { r.label = pm.getApplicationLabel(ai).toString(); } catch (Throwable ignored) {}
            }
            if (r.icon == null) {
                try { r.icon = pm.getApplicationIcon(ai); } catch (Throwable ignored) {}
            }
        } catch (Throwable ignored) {}
    }

    interface SlotClick {
        void onClick(int index, boolean longPress);
    }
}
