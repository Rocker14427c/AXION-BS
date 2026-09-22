package dev.axion.spsm;

import android.app.Activity;
import android.app.AlertDialog;
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
    /** knob id -> the human label from knobs.list, so toasts speak the option's name. */
    private final Map<String, String> labels = new HashMap<>();
    /** knob id -> "works"/"inert"/"partial"/"unknown", from the last probe. */
    private final Map<String, String> verdicts = new HashMap<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_knobs);
        list = findViewById(R.id.knob_list);
        status = findViewById(R.id.knob_status);
        ((Button) findViewById(R.id.btn_reload)).setOnClickListener(v -> load());
        // Top right, small: a maintenance action, not part of using the mode.
        findViewById(R.id.btn_check).setOnClickListener(v -> confirmProbe());
        load();
    }

    private void load() {
        status.setText(R.string.knobs_loading);
        list.removeAllViews();
 switches.clear();
        labels.clear();

        new Thread(() -> {
            // Regenerate from the scripts first, so the list always matches the
            // installed engine, then read it together with the saved config.
            String out = Root.exec(
                    "sh " + Root.DIR + "/scripts/engine.sh dump-knobs >/dev/null 2>&1; "
                  + "cat " + Root.DIR + "/knobs.list 2>/dev/null; "
                  + "echo '--CONFIG--'; cat " + Root.DIR + "/config 2>/dev/null; "
                  + "echo '--PROBE--'; cat " + Root.DIR + "/state/probe.tsv 2>/dev/null; "
                  + "echo '--END--'");
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
        verdicts.clear();

        for (String line : lines) {
            line = line.trim();
            if (line.equals("--END--")) { inConfig = false; continue; }
            if (line.equals("--PROBE--")) { inConfig = false; continue; }
            if (line.equals("--CONFIG--")) { inConfig = true; continue; }
            if (inConfig) {
                int eq = line.indexOf('=');
                if (eq > 0) config.put(line.substring(0, eq), line.substring(eq + 1));
                continue;
            }
            if (line.isEmpty()) continue;
            // knob<TAB>verdict<TAB>detail - the result of the last on-device check.
            String[] tab = line.split("\t", 3);
            if (tab.length >= 2 && !line.contains("|")) {
                String v = tab[1];
                if (v.equals("works") || v.equals("inert") || v.equals("partial") || v.equals("unknown")) {
                    verdicts.put(tab[0], v);
                    continue;
                }
            }
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
                labels.put(id, f[2]);

                StringBuilder b = new StringBuilder();
                // What this option did the last time it was tried on this phone -
                // the point being that a switch which toggles but does nothing is
                // worth knowing about before you rely on it.
                final String verdict = verdicts.get(id);
                if (verdict != null) {
                    if (verdict.equals("works")) b.append(getString(R.string.badge_works));
                    else if (verdict.equals("inert")) b.append(getString(R.string.badge_inert));
                    else if (verdict.equals("partial")) b.append(getString(R.string.badge_partial));
                    else if (verdict.equals("preference")) b.append(getString(R.string.badge_preference));
                    else b.append(getString(R.string.badge_unknown));
                }
                if ("deep".equals(f[5])) b.append(b.length() > 0 ? " · " : "").append(getString(R.string.badge_sleep));
                String tags = f.length > 6 ? f[6] : "";
                if (tags.contains("experimental")) b.append(b.length() > 0 ? " · " : "").append(getString(R.string.badge_experimental));
                if (tags.contains("breaks-features")) b.append(b.length() > 0 ? " · " : "").append(getString(R.string.badge_tradeoff));
                if (b.length() == 0) {
                    badge.setVisibility(View.GONE);
                } else {
                    badge.setText(b.toString());
                    int colour = tags.contains("breaks-features") ? 0xFFFFC915 : 0xFF8AB4F8;
                    if ("inert".equals(verdict)) colour = 0xFF9E9E9E;
                    if ("partial".equals(verdict)) colour = 0xFFFF6B6B;
                    badge.setTextColor(colour);
                }

 sw.setChecked(on);
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
        status.setTextColor(0xFFFFC915);
    }

    /**
     * Ask the phone which options do something here.
     *
     * This runs the engine's probe: for each option it records the value,
     * applies the change, reads the phone back, undoes it and reads again. The
     * verdict is shown next to the option afterwards. It is the answer to "this
     * switch toggles but nothing happens" - and it only ever runs with the mode
     * off, because it writes its own journal while it checks.
     */
    /**
     * Check every option against the phone.
     *
     * The engine refuses while the mode is on - it writes and undoes each option,
     * which is not a thing to do to a live session - so rather than reporting a
     * refusal, ask whether to switch SPSM off and do it. The first version just
     * printed nothing useful and looked like a button that did nothing.
     */
    private void confirmProbe() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.probe_title)
                .setMessage(R.string.probe_explain)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.probe_start, (d, w) -> {
                    status.setTextColor(0xFFFFC915);
                    status.setText(R.string.knobs_probing);
                    new Thread(() -> {
                        if (Root.isActive()) Root.exit();
                        doProbe();
                    }).start();
                })
                .show();
    }

    private volatile boolean probing = false;

    private void doProbe() {
        runOnUiThread(() -> {
            findViewById(R.id.btn_check).setEnabled(false);
            status.setTextColor(0xFFFFC915);
            status.setText(R.string.knobs_probing);
        });
        // A heartbeat for the wait. The whole check is ONE engine call that
        // takes minutes at this phone's speed, and a static line for five
        // minutes is what "the button does nothing" looks like from a chair.
        // The engine names each option in its progress file as it starts it;
        // this side thread reads that name through su and puts it up, with a
        // running count of the verdicts already written.
        probing = true;
        final int[] lastCount = {0};
        new Thread(() -> {
            while (probing) {
                // Two short reads every 2 s for the length of a probe; both
                // go down the shared shell rather than spawning two su.
                String n = Root.read("wc -l < " + Root.DIR + "/state/probe.tsv 2>/dev/null");
                String p = Root.progress();
                final int count = (n == null) ? 0 : parseIntOr(n.trim(), -1);
                if (count > lastCount[0]) {
                    lastCount[0] = count;
                    runOnUiThread(() -> status.setText(
                            getString(R.string.knobs_probing_n, String.valueOf(count))));
                } else if (p != null && p.trim().startsWith("Checking:")) {
                    final String label = p.trim();
                    runOnUiThread(() -> status.setText(label));
                }
                try { Thread.sleep(2000); } catch (InterruptedException e) { return; }
            }
        }).start();
        String out = Root.exec("sh " + Root.DIR + "/scripts/engine.sh probe 2>&1");
        probing = false;
        runOnUiThread(() -> {
            findViewById(R.id.btn_check).setEnabled(true);
            if (out == null) {
                status.setText(R.string.knobs_unavailable);
            } else {
                status.setText(summarise(out));
            }
            load();
        });
    }

    private static int parseIntOr(String s, int def) {
        try { return Integer.parseInt(s); } catch (NumberFormatException e) { return def; }
    }

    /** The totals line, turned into something readable. */
    private String summarise(String out) {
        for (String line : out.trim().split("\n")) {
            String l = line.trim();
            if (l.startsWith("works=")) {
                java.util.Map<String, String> v = new java.util.HashMap<>();
                for (String part : l.split(" ")) {
                    int eq = part.indexOf('=');
                    if (eq > 0) v.put(part.substring(0, eq), part.substring(eq + 1));
                }
                return getString(R.string.probe_done,
                        v.getOrDefault("works", "0"),
                        v.getOrDefault("inert", "0"),
                        v.getOrDefault("unknown", "0"));
            }
            if (l.startsWith("SPSM is ")) return l;   // the reason it declined
        }
        return getString(R.string.knobs_unavailable);
    }

    private void apply(final String id, final boolean on, final Switch sw) {
        sw.setEnabled(false);
        new Thread(() -> {
            String res = Root.exec("sh " + Root.DIR + "/scripts/engine.sh set " + id + " " + (on ? "1" : "0"));
            runOnUiThread(() -> {
 sw.setEnabled(true);
                boolean live = Root.isActive();
                // The option's own name, never the internal id: "Wi-Fi off
                // enabled", not "wifi_off enabled".
                String name = labels.get(id);
                if (name == null) name = id;
                String msg = getString(on ? R.string.knob_on : R.string.knob_off, name);
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
