package dev.axion.spsm;

import android.app.Activity;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * "What gets changed" - the list of every knob SPSM is allowed to touch, with a
 * switch each, so anything can be left alone.
 *
 * The list is NOT hardcoded here: it is read from /data/adb/spsm/knobs.list,
 * which engine.sh generates from the same registry the scripts execute. That
 * way this screen can never offer a switch that does nothing, or miss a change
 * the scripts make.
 */
public class KnobsActivity extends Activity {
    private LinearLayout list;
    private TextView status;
    private final Map<String, Switch> switches = new LinkedHashMap<>();
    private final Map<String, Boolean> original = new HashMap<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_knobs);
        list = findViewById(R.id.knob_list);
        status = findViewById(R.id.knob_status);
        ((Button) findViewById(R.id.btn_reload)).setOnClickListener(v -> load());
        load();
    }

    private void load() {
        status.setText(R.string.knobs_loading);
        list.removeAllViews();
        switches.clear();
        original.clear();

        new Thread(() -> {
            // Regenerate from the scripts first, so the list always matches the
            // installed engine, then read it together with the saved config.
            String out = Root.exec(
                    "sh " + Root.DIR + "/scripts/engine.sh dump-knobs >/dev/null 2>&1; "
                  + "cat " + Root.DIR + "/knobs.list 2>/dev/null; "
                  + "echo '--CONFIG--'; cat " + Root.DIR + "/config 2>/dev/null");
            runOnUiThread(() -> {
                if (out == null || out.trim().isEmpty()) {
                    status.setText(R.string.knobs_unavailable);
                    return;
                }
                render(out);
            });
        }).start();
    }

    private void render(String out) {
        String[] lines = out.split("\n");
        Map<String, String> config = new HashMap<>();
        boolean inConfig = false;
        Map<String, List<String[]>> byCategory = new LinkedHashMap<>();

        for (String line : lines) {
            line = line.trim();
            if (line.equals("--CONFIG--")) { inConfig = true; continue; }
            if (inConfig) {
                int eq = line.indexOf('=');
                if (eq > 0) config.put(line.substring(0, eq), line.substring(eq + 1));
                continue;
            }
            if (line.isEmpty()) continue;
            // id|category|label|description|default|scope|tags
            String[] f = line.split("\\|", 7);
            if (f.length < 6) continue;
            List<String[]> l = byCategory.get(f[1]);
            if (l == null) { l = new ArrayList<>(); byCategory.put(f[1], l); }
            l.add(f);
        }

        if (byCategory.isEmpty()) {
            status.setText(R.string.knobs_unavailable);
            return;
        }

        LayoutInflater inf = LayoutInflater.from(this);
        for (Map.Entry<String, List<String[]>> e : byCategory.entrySet()) {
            TextView head = new TextView(this);
            head.setText(e.getKey().toUpperCase());
            head.setTextColor(0xFF7A7A7A);
            head.setTextSize(12);
            head.setPadding(0, dp(18), 0, dp(6));
            list.addView(head);

            for (final String[] f : e.getValue()) {
                final String id = f[0];
                boolean def = "1".equals(f[4]);
                String cfgVal = config.get("knob." + id);
                final boolean on = cfgVal == null ? def : ("1".equals(cfgVal) || "true".equals(cfgVal));

                View row = inf.inflate(R.layout.item_knob, list, false);
                TextView label = row.findViewById(R.id.knob_label);
                TextView desc = row.findViewById(R.id.knob_desc);
                TextView badge = row.findViewById(R.id.knob_badge);
                Switch sw = row.findViewById(R.id.knob_switch);

                label.setText(f[2]);
                desc.setText(f[3]);

                StringBuilder b = new StringBuilder();
                if ("deep".equals(f[5])) b.append(getString(R.string.badge_sleep));
                String tags = f.length > 6 ? f[6] : "";
                if (tags.contains("experimental")) b.append(b.length() > 0 ? " · " : "").append(getString(R.string.badge_experimental));
                if (tags.contains("breaks-features")) b.append(b.length() > 0 ? " · " : "").append(getString(R.string.badge_tradeoff));
                if (b.length() == 0) {
                    badge.setVisibility(View.GONE);
                } else {
                    badge.setText(b.toString());
                    badge.setTextColor(tags.contains("breaks-features") ? 0xFFFFC915 : 0xFF8AB4F8);
                }

                sw.setChecked(on);
                original.put(id, on);
                sw.setOnCheckedChangeListener((v, checked) -> {
                    // A disabled-looking row still toggles; the write happens on
                    // the listener so the user's intent is never lost.
                    switches.put(id, (Switch) v);
                    apply(id, checked, (Switch) v);
                });
                switches.put(id, sw);
                list.addView(row);
            }
        }
        status.setText("");
    }

    private void apply(final String id, final boolean on, final Switch sw) {
        sw.setEnabled(false);
        new Thread(() -> {
            String res = Root.exec("sh " + Root.DIR + "/scripts/engine.sh set " + id + " " + (on ? "1" : "0"));
            runOnUiThread(() -> {
                sw.setEnabled(true);
                original.put(id, on);
                boolean live = Root.isActive();
                String msg = getString(on ? R.string.knob_on : R.string.knob_off, id);
                if (!live && !on) msg = getString(R.string.knob_saved_off);
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
                if (res != null && res.toLowerCase().contains("unknown knob")) {
                    Toast.makeText(this, R.string.knob_failed, Toast.LENGTH_LONG).show();
                    sw.setChecked(!on);
                }
            });
        }).start();
    }

    private int dp(int v) {
        return Math.round(getResources().getDisplayMetrics().density * v);
    }

    @Override
    public void onBackPressed() {
        finish();
    }
}
