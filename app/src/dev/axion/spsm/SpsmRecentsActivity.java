package dev.axion.spsm;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.ImageView;
import android.widget.ListView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * SPSM's own recents.
 *
 * <p>The phone's recents belong to the launcher: swiping up starts
 * com.android.launcher3 and its Quickstep RecentsActivity, which is a task of
 * its own in the list. In a mode meant to run off a nearly empty battery that is
 * an expensive way to switch apps, so this screen reads the task list itself and
 * switches tasks directly - the launcher is never started.
 *
 * <p>It does that work only while it is open: one root call when it appears, one
 * when a task is switched. Nothing is kept running in between, no thumbnails are
 * captured (an app icon and a name is all a switch needs), and the list is capped
 * by the module.
 */
public class SpsmRecentsActivity extends Activity {
    /**
     * Whether the list is on screen right now.
     *
     * <p>The home screen asks this before acting on a MAIN/HOME intent: without
     * it, pressing Home while the list is open would open the list again, and a
     * gesture meant to leave could look like it did nothing.
     */
    static boolean visible;

    private ListView list;
    private View empty;
    private View working;
    private final List<Row> rows = new ArrayList<>();
    private Adapter adapter;

    /** One task, as the module reports it. */
    private static class Row {
        String id;
        String pkg;
        String component;
        long lastActive;      // same clock as SystemClock.uptimeMillis()
        String label;
        Drawable icon;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_recents);
        list = findViewById(R.id.recent_list);
        empty = findViewById(R.id.recent_empty);
        working = findViewById(R.id.recent_working);
        View close = findViewById(R.id.btn_close);
        if (close != null) close.setOnClickListener(v -> finish());
        View home = findViewById(R.id.btn_home);
        if (home != null) home.setOnClickListener(v -> finish());
        adapter = new Adapter();
        try {
            list.setAdapter(adapter);
            list.setOnItemClickListener((p, v, position, id) -> switchTo(rows.get(position)));
            list.setOnItemLongClickListener((p, v, position, id) -> {
                confirmClose(rows.get(position));
                return true;
            });
        } catch (Throwable ignored) {
        }
        load();
    }

    @Override
    protected void onResume() {
        super.onResume();
        visible = true;
    }

    @Override
    protected void onPause() {
        visible = false;
        super.onPause();
    }

    @Override
    public void onBackPressed() {
        finish();
    }

    /** Reads the task list once, through the module, off the UI thread. */
    private void load() {
        working.setVisibility(View.VISIBLE);
        empty.setVisibility(View.GONE);
        new Thread(() -> {
            String out = Root.exec("sh " + Root.DIR + "/scripts/engine.sh recents 2>/dev/null");
            final List<Row> parsed = parse(out);
            for (Row r : parsed) {
                // PackageManager work happens here, never on the UI thread.
                Apps.Resolved res = Apps.resolve(this, r.pkg);
                if (res != null) {
                    r.label = res.label;
                    r.icon = res.icon;
                }
            }
            runOnUiThread(() -> {
                rows.clear();
                rows.addAll(parsed);
                adapter.notifyDataSetChanged();
                working.setVisibility(View.GONE);
                boolean any = !rows.isEmpty();
                empty.setVisibility(any ? View.GONE : View.VISIBLE);
                list.setVisibility(any ? View.VISIBLE : View.GONE);
            });
        }).start();
    }

    /**
     * "id<TAB>package<TAB>component<TAB>lastActive" per line, as the module
     * writes it. Anything that does not have the shape is skipped rather than
     * shown as a mystery row.
     */
    private static List<Row> parse(String out) {
        List<Row> list = new ArrayList<>();
        if (out == null) return list;
        for (String line : out.split("\n")) {
            if (line.isEmpty()) continue;
            String[] f = line.split("\t", -1);
            if (f.length < 2) continue;
            String id = f[0].trim();
            if (id.isEmpty()) continue;
            boolean digits = true;
            for (int i = 0; i < id.length(); i++) {
                if (!Character.isDigit(id.charAt(i))) { digits = false; break; }
            }
            if (!digits) continue;
            Row r = new Row();
            r.id = id;
            r.pkg = f[1].trim();
            r.component = f.length > 2 ? f[2].trim() : "";
            if (f.length > 3) {
                try { r.lastActive = Long.parseLong(f[3].trim()); } catch (Exception ignored) {}
            }
            if (!r.pkg.isEmpty()) list.add(r);
        }
        return list;
    }

    private void switchTo(final Row r) {
        // The switch happens in the background; the screen closes straight away so
        // the app comes up as quickly as the system can manage it.
        new Thread(() -> Root.exec("sh " + Root.DIR + "/scripts/engine.sh recents-switch "
                + r.id + " '" + r.component.replace("'", "") + "' 2>/dev/null")).start();
        finish();
    }

    private void confirmClose(final Row r) {
        String name = r.label == null || r.label.isEmpty() ? r.pkg : r.label;
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle(getString(R.string.recents_close_title, name))
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.recents_close_yes, (d, w) -> {
                    // The package goes with the id: closing a task is done by
                    // asking the system to remove it, and if this ROM's command
                    // takes the request and leaves the task where it is, stopping
                    // the app is what actually closes it. Everything that reaches
                    // a shell is checked first.
                    final String pkg = safePkg(r.pkg);
                    new Thread(() -> {
                        Root.exec("sh " + Root.DIR + "/scripts/engine.sh recents-remove "
                                + r.id + (pkg.isEmpty() ? "" : " '" + pkg + "'"));
                        runOnUiThread(this::load);
                    }).start();
                })
                .show();
    }

    /** A package name that is safe to put in a shell command, or "". */
    private static String safePkg(String pkg) {
        if (pkg == null) return "";
        String p = pkg.trim();
        for (int i = 0; i < p.length(); i++) {
            char ch = p.charAt(i);
            boolean ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
                    || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_';
            if (!ok) return "";
        }
        return p;
    }

    /** "3 min ago" from the same clock the task list uses. */
    private String ago(Row r) {
        if (r.lastActive <= 0) return "";
        long ms = SystemClock.uptimeMillis() - r.lastActive;
        if (ms < 0) ms = 0;
        long min = ms / 60000;
        if (min < 1) return getString(R.string.recents_just_now);
        if (min < 60) return getString(R.string.recents_min_ago, min);
        long hrs = min / 60;
        if (hrs < 24) return getString(R.string.recents_hr_ago, hrs);
        return getString(R.string.recents_day_ago, hrs / 24);
    }

    private class Adapter extends BaseAdapter {
        @Override public int getCount() { return rows.size(); }
        @Override public Object getItem(int position) { return rows.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            if (convertView == null) {
                convertView = LayoutInflater.from(SpsmRecentsActivity.this)
                        .inflate(R.layout.item_recent_row, parent, false);
            }
            Row r = rows.get(position);
            ImageView icon = convertView.findViewById(R.id.icon);
            if (r.icon != null) {
                icon.setImageDrawable(r.icon);
            } else {
                icon.setImageResource(R.drawable.ic_plus);
            }
            String name = r.label == null || r.label.isEmpty() ? r.pkg : r.label;
            ((TextView) convertView.findViewById(R.id.label)).setText(name);
            ((TextView) convertView.findViewById(R.id.pkg)).setText(ago(r));
            return convertView;
        }
    }
}
