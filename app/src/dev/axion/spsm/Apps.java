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

    static List<Item> launchable(Context c) {
        PackageManager pm = c.getPackageManager();
        Intent i = new Intent(Intent.ACTION_MAIN);
        i.addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> raw = pm.queryIntentActivities(i, 0);
        List<Item> out = new ArrayList<>();
        for (ResolveInfo ri : raw) {
            if (ri.activityInfo == null) continue;
            String pkg = ri.activityInfo.packageName;
            if ("dev.axion.spsm".equals(pkg)) continue;
            CharSequence lab = ri.loadLabel(pm);
            Drawable ic = ri.loadIcon(pm);
            out.add(new Item(pkg, lab == null ? pkg : lab.toString(), ic));
        }
        Collections.sort(out, new Comparator<Item>() {
            @Override public int compare(Item a, Item b) {
                return a.label.compareToIgnoreCase(b.label);
            }
        });
        return out;
    }

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
