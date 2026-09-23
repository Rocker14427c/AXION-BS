package dev.axion.spsm;

import android.app.Activity;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The apps that keep running while SPSM is on.
 *
 * The six slots already do this for six apps. This screen is the open-ended
 * version, and it exists because of a failure the mode actually caused: an app
 * that is suspended while the screen is off misses its pushes, and an app that
 * has been force-stopped misses everything until somebody opens it - a chat app
 * goes quiet with nothing on screen to explain why.
 *
 * Calls and SMS are not in this list and do not need to be: they are protected by
 * the phone's own ROLES (dialer, SMS, emergency), whatever this list holds. This
 * is for everything else the owner does not want silenced.
 *
 * Every change goes through `engine.sh keep add|remove`, so adding an app here
 * releases it the moment it is tapped if the mode has it frozen or stopped.
 */
public class KeepAwakeActivity extends Activity {
    private final List<Apps.Item> all = new ArrayList<>();
    private final List<Apps.Item> shown = new ArrayList<>();
    private final Set<String> kept = new HashSet<>();
    private Adapter adapter;
    private TextView hint;
    private boolean showSystem;
    private String searchText = "";
    private long stamp;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(0xFF000000);
        setContentView(R.layout.activity_picker);

        ((TextView) findViewById(R.id.picker_title)).setText(R.string.keep_title);
        ((TextView) findViewById(R.id.pick_note)).setText(R.string.keep_note);
        ((EditText) findViewById(R.id.search)).setHint(R.string.keep_search);

        ListView list = findViewById(R.id.list);
        adapter = new Adapter();
        list.setAdapter(adapter);
        list.setOnItemClickListener((p, v, pos, id) -> toggle(shown.get(pos).pkg));

        ((EditText) findViewById(R.id.search)).addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int st, int c, int a) {}
            @Override public void onTextChanged(CharSequence s, int st, int b, int c) {
                searchText = s == null ? "" : s.toString();
                filter();
                addTyped(searchText);
            }
            @Override public void afterTextChanged(Editable s) {}
        });
        hint = findViewById(R.id.pick_hint);
        CheckBox sys = findViewById(R.id.show_system);
        sys.setChecked(showSystem);
        sys.setOnCheckedChangeListener((v, checked) -> {
            showSystem = checked;
            reload();
        });
        reload();
    }

    /**
     * Tap to keep, tap again to let it be blocked.
     *
     * The release path is asynchronous (it shells out to the engine), so the list
     * is updated straight away and the work is done off the UI thread: a tap that
     * waited for a root call would feel broken even when it worked.
     */
    private void toggle(final String pkg) {
        final boolean on = !kept.contains(pkg);
        if (on) kept.add(pkg); else kept.remove(pkg);
        adapter.notifyDataSetChanged();
        Toast.makeText(this, getString(on ? R.string.keep_added : R.string.keep_removed,
                label(pkg)), Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            boolean ok = Root.keep(pkg, on);
            if (!ok) {
                // Say so rather than leaving the row looking changed when the
                // engine refused it.
                runOnUiThread(() -> {
                    if (on) kept.remove(pkg); else kept.add(pkg);
                    adapter.notifyDataSetChanged();
                    Toast.makeText(this, R.string.keep_failed, Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private String label(String pkg) {
        for (Apps.Item it : all) {
            if (it.pkg.equals(pkg)) return it.label;
        }
        return pkg;
    }

    private void reload() {
        final long mine = ++stamp;
        final boolean withSystem = showSystem;
        new Thread(() -> {
            final List<Apps.Item> items = Apps.launchable(KeepAwakeActivity.this, withSystem);
            final Set<String> now = new HashSet<>();
            for (String p : Root.keepList()) now.add(p);
            runOnUiThread(() -> {
                if (mine != stamp) return;
                all.clear();
                all.addAll(items);
                kept.clear();
                kept.addAll(now);
                filter();
                if (hint != null) {
                    hint.setText(getString(R.string.keep_count, kept.size(), all.size()));
                }
            });
        }).start();
    }

    /** A package name typed by hand can still be added, as on the slot screen. */
    private void addTyped(String q) {
        String pkg = q == null ? "" : q.trim();
        if (pkg.indexOf('.') < 0 || pkg.indexOf(' ') >= 0) return;
        for (Apps.Item it : all) {
            if (it.pkg.equals(pkg)) return;
        }
        all.add(0, new Apps.Item(pkg, pkg + "  (typed by hand)", null, "typed"));
        filter();
    }

    /** Kept apps first, then everything else: the list answers "what is on it?" first. */
    private void filter() {
        String n = searchText == null ? "" : searchText.toLowerCase();
        shown.clear();
        List<Apps.Item> rest = new ArrayList<>();
        for (Apps.Item it : all) {
            if (n.length() > 0
                    && !it.label.toLowerCase().contains(n)
                    && !it.pkg.toLowerCase().contains(n)) {
                continue;
            }
            if (kept.contains(it.pkg)) shown.add(it); else rest.add(it);
        }
        shown.addAll(rest);
        adapter.notifyDataSetChanged();
    }

    class Adapter extends BaseAdapter {
        @Override public int getCount() { return shown.size(); }
        @Override public Object getItem(int position) { return shown.get(position); }
        @Override public long getItemId(int position) { return position; }
        @Override public View getView(int position, View convertView, ViewGroup parent) {
            if (convertView == null) {
                convertView = getLayoutInflater().inflate(R.layout.item_app_row, parent, false);
            }
            Apps.Item it = shown.get(position);
            boolean on = kept.contains(it.pkg);
            ImageView icon = convertView.findViewById(R.id.icon);
            if (on) {
                icon.setImageResource(R.drawable.ic_check);
            } else if (it.icon != null) {
                icon.setImageDrawable(it.icon);
            } else {
                icon.setImageResource(R.drawable.ic_plus);
            }
            TextView label = convertView.findViewById(R.id.label);
            TextView pkg = convertView.findViewById(R.id.pkg);
            label.setText(it.label);
            label.setAlpha(on ? 1f : 0.75f);
            pkg.setText(pkgLine(it, on));
            return convertView;
        }
    }

    private String pkgLine(Apps.Item it, boolean on) {
        String sub = it.pkg;
        if (on) {
            sub = sub + "   · " + getString(R.string.keep_on);
        } else if (it.tag != null && it.tag.length() > 0 && !"user".equals(it.tag)) {
            sub = sub + "   · " + it.tag;
        }
        return sub;
    }
}
