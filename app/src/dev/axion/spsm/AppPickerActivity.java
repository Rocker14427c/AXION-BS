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
            Prefs.setSlot(this, slot, it.pkg);
            finish();
        });
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int st, int c, int a) {}
            @Override public void onTextChanged(CharSequence s, int st, int b, int c) { filter(s.toString()); }
            @Override public void afterTextChanged(Editable s) {}
        });
        all = Apps.launchable(this);
        // Clear option at top
        shown = new ArrayList<>(all);
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
            ((ImageView) convertView.findViewById(R.id.icon)).setImageDrawable(it.icon);
            ((TextView) convertView.findViewById(R.id.label)).setText(it.label);
            ((TextView) convertView.findViewById(R.id.pkg)).setText(it.pkg);
            return convertView;
        }
    }
}
