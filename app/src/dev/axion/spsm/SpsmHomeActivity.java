package dev.axion.spsm;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Bundle;
import android.os.Handler;
import android.view.View;
import android.view.Window;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public class SpsmHomeActivity extends Activity {
    private final Handler handler = new Handler();
    private TextView battery;
    private final int[] slotIds = {
            R.id.slot0, R.id.slot1, R.id.slot2, R.id.slot3, R.id.slot4, R.id.slot5
    };

    private final BroadcastReceiver batRx = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            updateBattery(intent);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Window w = getWindow();
        w.setStatusBarColor(0xFF000000);
        w.setNavigationBarColor(0xFF000000);
        setContentView(R.layout.activity_home);
        battery = findViewById(R.id.battery);
        findViewById(R.id.btn_exit).setOnClickListener(v -> confirmExit());
        Apps.fillDefaults(this);
        bindSlots();
        registerReceiver(batRx, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
    }

    @Override
    protected void onResume() {
        super.onResume();
        bindSlots();
        handler.post(tick);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(tick);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        try { unregisterReceiver(batRx); } catch (Exception ignored) {}
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        // Swallow back; this is the home.
    }

    private void bindSlots() {
        for (int i = 0; i < 6; i++) {
            final int index = i;
            LinearLayout slot = findViewById(slotIds[i]);
            Apps.bindSlot(this, slot, i, (idx, longPress) -> {
                if (longPress) {
                    AppPickerActivity.open(SpsmHomeActivity.this, idx);
                } else {
                    String pkg = Prefs.getSlot(SpsmHomeActivity.this, idx);
                    if (pkg == null || pkg.length() == 0) {
                        AppPickerActivity.open(SpsmHomeActivity.this, idx);
                    } else {
                        Apps.launch(SpsmHomeActivity.this, pkg);
                    }
                }
            });
        }
    }

    private void confirmExit() {
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle(R.string.exit_title)
                .setMessage(R.string.exit_msg)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.confirm_exit, (d, w) -> doExit())
                .show();
    }

    private void doExit() {
        Toast.makeText(this, R.string.working, Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            Root.exit();
            runOnUiThread(() -> {
                Toast.makeText(this, R.string.done_off, Toast.LENGTH_SHORT).show();
                Intent i = new Intent(this, SetupActivity.class);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(i);
                finish();
            });
        }).start();
    }

    private void updateBattery(Intent intent) {
        if (intent == null) return;
        int lvl = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        int scl = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
        int st = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
        int pct = scl > 0 ? (int) (lvl * 100f / scl) : lvl;
        boolean charging = st == BatteryManager.BATTERY_STATUS_CHARGING
                || st == BatteryManager.BATTERY_STATUS_FULL;

        String extra;
        if (charging) {
            extra = getString(R.string.charging);
        } else {
            extra = getString(R.string.remaining, estimate(pct));
        }
        battery.setText(pct + "%  |  " + extra);
    }

    private String estimate(int pct) {
        // ColorOS-style optimistic remaining while SPSM is on.
        // ~0.55 hour per 1% on a 6000 mAh cell in this mode.
        float hours = Math.max(pct, 0) * 0.55f;
        int h = (int) hours;
        int m = Math.round((hours - h) * 60);
        if (h <= 0 && m < 1) m = 1;
        if (h >= 24) {
            int d = h / 24;
            int rh = h % 24;
            if (rh == 0) return d + (d == 1 ? " day" : " days");
            return d + (d == 1 ? " day " : " days ") + rh + " hr";
        }
        if (h == 0) return m + " min";
        if (m == 0) return h + (h == 1 ? " hr" : " hrs");
        return h + " hr " + m + " min";
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            handler.postDelayed(this, 30_000);
        }
    };
}
