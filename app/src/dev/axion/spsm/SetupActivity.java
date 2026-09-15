package dev.axion.spsm;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public class SetupActivity extends Activity {
    private TextView status;
    private TextView rootStatus;
    private TextView working;
    private Button toggle;
    private boolean busy;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private Runnable progressPoll;
    private final int[] slotIds = {
            R.id.slot0, R.id.slot1, R.id.slot2, R.id.slot3, R.id.slot4, R.id.slot5
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(0xFF000000);
        getWindow().setNavigationBarColor(0xFF000000);
        setContentView(R.layout.activity_setup);
        status = findViewById(R.id.status);
        rootStatus = findViewById(R.id.root_status);
        working = findViewById(R.id.working);
        toggle = findViewById(R.id.btn_toggle);
        Apps.fillDefaults(this);
        // The UI being open is a chance to have the live signal running; it
        // costs nothing and keeps the engine's view of the screen fresh.
        ScreenReceiver.install(this);
        rootStatus.setOnClickListener(v -> checkRoot(true));
        toggle.setOnClickListener(v -> onToggle());
        findViewById(R.id.btn_options).setOnClickListener(v -> {
            Intent i = new Intent(this, KnobsActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        });
        if (getIntent() != null && getIntent().getBooleanExtra("toggle", false)) {
            getIntent().removeExtra("toggle");
            onToggle();
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (intent != null && intent.getBooleanExtra("toggle", false)) {
            intent.removeExtra("toggle");
            onToggle();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        bindSlots();
        refresh();
    }

    @Override
    protected void onPause() {
        stopProgressPoll();
        super.onPause();
    }

    private void bindSlots() {
        for (int i = 0; i < 6; i++) {
            LinearLayout slot = findViewById(slotIds[i]);
            Apps.bindSlot(this, slot, i, (idx, longPress) -> AppPickerActivity.open(SetupActivity.this, idx));
        }
    }

    private void refresh() {
        new Thread(() -> {
            final boolean root = Root.available();
            final boolean active = root && Root.isActive();
            runOnUiThread(() -> {
                if (!root) {
                    rootStatus.setText(R.string.root_need);
                    rootStatus.setTextColor(0xFFFFC915);
                } else {
                    rootStatus.setText(R.string.root_ok);
                    rootStatus.setTextColor(0xFF3DDC84);
                }
                status.setText(active ? R.string.active : R.string.inactive);
                toggle.setText(active ? R.string.exit : R.string.enter);
                toggle.setBackgroundResource(active ? R.drawable.bg_button_off : R.drawable.bg_button);
                toggle.setTextColor(active ? 0xFFFFFFFF : 0xFF000000);
            });
        }).start();
    }

    private void checkRoot(boolean toast) {
        new Thread(() -> {
            final boolean ok = Root.available();
            runOnUiThread(() -> {
                refresh();
                if (toast) {
                    Toast.makeText(this, ok ? R.string.root_ok : R.string.root_fail, Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private void onToggle() {
        if (busy) return;
        new Thread(() -> {
            final boolean root = Root.available();
            final boolean active = root && Root.isActive();
            final boolean module = root && Root.modulePresent();
            runOnUiThread(() -> {
                if (!root) {
                    Toast.makeText(this, R.string.root_fail, Toast.LENGTH_LONG).show();
                    return;
                }
                if (!module && !active) {
                    Toast.makeText(this, R.string.module_missing, Toast.LENGTH_LONG).show();
                    return;
                }
                if (active) {
                    new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                            .setTitle(R.string.exit_title)
                            .setMessage(R.string.exit_msg)
                            .setNegativeButton(R.string.cancel, null)
                            .setPositiveButton(R.string.confirm_exit, (d, w) -> runExit())
                            .show();
                } else {
                    new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                            .setTitle(R.string.enter_title)
                            .setMessage(R.string.enter_msg)
                            .setNegativeButton(R.string.cancel, null)
                            .setPositiveButton(R.string.confirm, (d, w) -> runEnter())
                            .show();
                }
            });
        }).start();
    }

    /**
     * While the engine works, show what it is actually doing - the engine
     * publishes each step to /data/adb/spsm/state/progress. A real step list
     * makes a two second switch feel immediate instead of feeling stuck.
     */
    private void startProgressPoll() {
        stopProgressPoll();
        progressPoll = new Runnable() {
            @Override public void run() {
                new Thread(() -> {
                    final String p = Root.progress();
                    if (p != null && !p.trim().isEmpty()) {
                        runOnUiThread(() -> working.setText(p.trim()));
                    }
                }).start();
                ui.postDelayed(this, 400);
            }
        };
        ui.postDelayed(progressPoll, 400);
    }

    private void stopProgressPoll() {
        if (progressPoll != null) {
            ui.removeCallbacks(progressPoll);
            progressPoll = null;
        }
    }

    private void runEnter() {
        busy = true;
        working.setVisibility(View.VISIBLE);
        working.setText(R.string.working);
        toggle.setEnabled(false);
        startProgressPoll();
        new Thread(() -> {
            Root.writeWhitelist(Prefs.getAll(this));
            Root.enter();
            final boolean ok = Root.isActive();
            runOnUiThread(() -> {
                stopProgressPoll();
                busy = false;
                toggle.setEnabled(true);
                working.setVisibility(View.GONE);
                if (!ok) {
                    Toast.makeText(this, R.string.enter_fail, Toast.LENGTH_LONG).show();
                    refresh();
                    return;
                }
                Toast.makeText(this, R.string.done_on, Toast.LENGTH_SHORT).show();
                try {
                    Intent i = new Intent(this, SpsmHomeActivity.class);
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    startActivity(i);
                } catch (Exception ignored) {}
                refresh();
            });
        }).start();
    }

    private void runExit() {
        busy = true;
        working.setVisibility(View.VISIBLE);
        working.setText(R.string.working);
        toggle.setEnabled(false);
        startProgressPoll();
        new Thread(() -> {
            Root.exit();
            runOnUiThread(() -> {
                stopProgressPoll();
                busy = false;
                toggle.setEnabled(true);
                working.setVisibility(View.GONE);
                Toast.makeText(this, R.string.done_off, Toast.LENGTH_SHORT).show();
                refresh();
            });
        }).start();
    }
}
