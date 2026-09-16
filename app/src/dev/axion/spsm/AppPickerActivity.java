package dev.axion.spsm;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.ListView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

public class AppPickerActivity extends Activity {
    static final String EXTRA_SLOT = "slot";

    static void open(Activity a, int slot) {
        Intent i = new Intent(a, AppPickerActivity.class);
        i.putExtra(EXTRA_SLOT, slot);
        a.startActivity(i);
    }

    private int slot;
    private List<Apps.Item> all = new ArrayList<>();
    private List<Apps.Item> shown = new ArrayList<>();
    private Adapter adapter;
    private TextView hint;
    private boolean showSystem;
    private long stamp;   // so a slow background listing cannot overwrite a newer one

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(0xFF000000);
        setContentView(R.layout.activity_picker);
        slot = getIntent().getIntExtra(EXTRA_SLOT, 0);
        ListView list = findViewById(R.id.list);
        EditText search = findViewById(R.id.search);
        adapter = new Adapter();
        list.setAdapter(adapter);
        list.setOnItemClickListener((p, v, pos, id) -> {
            Apps.Item it = shown.get(pos);
            Prefs.setSlot(this, slot, it.pkg);   // this also frees it in the module
            finish();
        });
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int st, int c, int a) {}
            @Override public void onTextChanged(CharSequence s, int st, int b, int c) {
                searchText = s == null ? "" : s.toString();
                filter(searchText);
                addTyped(searchText);
            }
            @Override public void afterTextChanged(Editable s) {}
        });
        hint = findViewById(R.id.pick_hint);
        android.widget.CheckBox sys = findViewById(R.id.show_system);
        sys.setChecked(showSystem);
        sys.setOnCheckedChangeListener((v, checked) -> {
            showSystem = checked;
            reload();
        });
        reload();
    }

    /**
     * The list, read fresh each time - so an app installed five minutes ago is
     * already here - and filtered: system apps are hidden unless asked for.
     */
    private void reload() {
        final long mine = ++stamp;
        final boolean withSystem = showSystem;
        new Thread(() -> {
            final List<Apps.Item> items = Apps.launchable(AppPickerActivity.this, withSystem);
            runOnUiThread(() -> {
                if (mine != stamp) return;
                all = items;
                filter(searchText);
                if (hint != null) {
                    hint.setText(getString(R.string.pick_count, all.size()));
                }
            });
        }).start();
    }

    private String searchText = "";

    /**
     * A package name typed by hand is added as-is.
     *
     * The list comes from the package manager and from `pm list packages`, which
     * between them should be everything - but "should be" is what the last two
     * attempts at this screen said, and the user still had apps that were not
     * offered. This is the way out that cannot fail: if it is installed, typing
     * its package name adds it.
     */
    private void addTyped(String q) {
        String pkg = q == null ? "" : q.trim();
        if (pkg.indexOf('.') < 0 || pkg.indexOf(' ') >= 0) return;
        for (Apps.Item it : all) {
            if (it.pkg.equals(pkg)) return;
        }
        shown.add(0, new Apps.Item(pkg, pkg + "  (typed by hand)", null, "typed"));
        adapter.notifyDataSetChanged();
    }

    private void filter(String q) {
        String n = q == null ? "" : q.toLowerCase();
        shown = new ArrayList<>();
        for (Apps.Item it : all) {
            if (n.length() == 0
                    || it.label.toLowerCase().contains(n)
                    || it.pkg.toLowerCase().contains(n)) {
                shown.add(it);
            }
        }
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
            ImageView icon = convertView.findViewById(R.id.icon);
            // An app with no icon of its own still has to be pickable.
            if (it.icon != null) {
                icon.setImageDrawable(it.icon);
            } else {
                icon.setImageResource(R.drawable.ic_plus);
            }
            ((TextView) convertView.findViewById(R.id.label)).setText(it.label);
            String sub = it.pkg;
            // Only say something when it is worth saying: every user app is a
            // user app, but "root manager", "no launcher icon" and a system app
            // shown on purpose are worth a word.
            if (it.tag != null && it.tag.length() > 0 && !"user".equals(it.tag)) {
                sub = sub + "   · " + it.tag;
            }
            ((TextView) convertView.findViewById(R.id.pkg)).setText(sub);
            return convertView;
        }
    }
}
