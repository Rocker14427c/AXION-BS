package dev.axion.spsm;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public class SpsmHomeActivity extends Activity {
    private final Handler handler = new Handler();
    private TextView battery;
    private TextView remaining;
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
        // setContentView first: it is what creates the window's decor view, and
        // asking for the insets controller before that throws
        // NullPointerException inside PhoneWindow - which, on a home activity,
        // means the phone loses its home screen in a crash loop. This activity
        // must be the last thing on the phone that can fail.
        // A home screen that fails to inflate leaves the phone with no home at
        // all - a black screen and no way back except reinstalling. So the
        // normal layout is attempted, and a plain one is built in code if it
        // cannot be shown for any reason.
        try {
            setContentView(R.layout.activity_home);
        } catch (Throwable t) {
            setContentView(fallbackHome());
        }
        styleSystemBars();
        battery = findViewById(R.id.battery);
        remaining = findViewById(R.id.remaining);
        View exit = findViewById(R.id.btn_exit);
        if (exit != null) exit.setOnClickListener(v -> confirmExit());
        // A visible way into recents, and a long press on the empty space of the
        // home. The swipe alone is not enough: swiping up from the bottom edge
        // is the SYSTEM's gesture on this phone - Android takes it for its own
        // navigation and opens the launcher's recents before this activity is
        // ever asked, which is the launcher being started all over again.
        View recentsBtn = findViewById(R.id.btn_recents);
        if (recentsBtn != null) recentsBtn.setOnClickListener(v -> openRecents());
        View root = findViewById(R.id.home_root);
        if (root != null) {
            // Only the space the buttons do not use: the six slots take their own
            // long presses first (Apps.bindSlot returns true), so holding an app
            // still means "change this app".
            root.setOnLongClickListener(v -> { openRecents(); return true; });
        }
        Apps.fillDefaults(this);
        bindSlots();
        registerReceiver(batRx, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
    }

    /**
     * The smallest home that still works: the name of the mode and a way out.
     * Only used if the real layout cannot be shown.
     */
    private View fallbackHome() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setBackgroundColor(0xFF000000);
        box.setGravity(android.view.Gravity.CENTER);
        box.setPadding(40, 40, 40, 40);
        TextView t = new TextView(this);
        t.setText(R.string.super_power_saving);
        t.setTextColor(0xFFFFFFFF);
        t.setTextSize(18);
        t.setGravity(android.view.Gravity.CENTER);
        box.addView(t);
        android.widget.Button b = new android.widget.Button(this);
        b.setText(R.string.exit);
        b.setAllCaps(false);
        b.setOnClickListener(v -> confirmExit());
        box.addView(b);
        android.widget.Button r = new android.widget.Button(this);
        r.setText(R.string.recents_button);
        r.setAllCaps(false);
        r.setOnClickListener(v -> openRecents());
        box.addView(r);
        return box;
    }

    @Override
    protected void onResume() {
        super.onResume();
        styleSystemBars();
        try {
            bindSlots();
        } catch (Throwable ignored) {
        }
        handler.post(tick);
    }

    /**
     * Keeps the status bar and the navigation bar where they belong.
     *
     * This used to hide both, full screen and immersive. On this phone that
     * takes away the clock, the battery and the way back to the rest of Android
     * exactly when the user needs them most - and it saves nothing: the bar is
     * drawn by the same compositor either way. So the bars stay visible and only
     * their colour is set, to match the black background.
     */
    private void styleSystemBars() {
        // Cosmetic, and therefore never worth a crash: this is the home screen,
        // and a home that dies takes the whole phone's UI with it. Every step is
        // guarded, and the decor view is obtained explicitly so the insets
        // controller is never asked for before the window has one.
        try {
            Window w = getWindow();
            w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            w.setStatusBarColor(0xFF000000);
            w.setNavigationBarColor(0xFF000000);
            w.getAttributes().layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            View decor = w.getDecorView();
            if (Build.VERSION.SDK_INT >= 30) {
                // Content below the bars, never behind them.
                w.setDecorFitsSystemWindows(true);
                WindowInsetsController c = decor.getWindowInsetsController();
                if (c != null) {
                    // White icons: the bar sits on the black home screen.
                    c.setSystemBarsAppearance(0, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS);
                    // And the bars themselves, asked for by name. The theme used
                    // to request full screen, which hides the status bar and
                    // leaves it hiding again a second after a swipe from the top.
                    // That item is gone; this is the other half of the same fix,
                    // so even a window that came up hidden is asked to show them.
                    c.show(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                }
            } else {
                decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
            }
        } catch (Throwable ignored) {
        }
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

    private float touchStartY;
    private float touchStartX;

    /**
     * A swipe that reaches this activity opens SPSM's own recents.
     *
     * <p>The system's recents belong to the launcher, and using them starts the
     * whole launcher process - which is exactly what this mode can least afford.
     * The gesture is read here and never consumed, so taps and long presses on
     * the six slots keep working normally.
     *
     * <p>An upward swipe from the bottom of the screen does not reach this
     * activity at all on this phone: that edge belongs to Android's gesture
     * navigation, and the system opens the launcher's recents with it. This is
     * why the Recents button and the long press exist - they are the ways in
     * that the system cannot take away.
     */
    @Override
    public boolean dispatchTouchEvent(android.view.MotionEvent ev) {
        try {
            switch (ev.getActionMasked()) {
                case android.view.MotionEvent.ACTION_DOWN:
                    touchStartY = ev.getY();
                    touchStartX = ev.getX();
                    break;
                case android.view.MotionEvent.ACTION_UP:
                    float dy = touchStartY - ev.getY();
                    float dx = ev.getX() - touchStartX;
                    float need = 60 * getResources().getDisplayMetrics().density;
                    // Up, left or right - whichever of them the system leaves to
                    // us. A swipe up from the bottom edge is normally taken by
                    // gesture navigation, which opens the launcher's recents.
                    if (dy > need && Math.abs(dx) < dy) openRecents();
                    else if (Math.abs(dx) > need && Math.abs(dx) > Math.abs(dy)) openRecents();
                    break;
                default:
                    break;
            }
        } catch (Throwable ignored) {
        }
        return super.dispatchTouchEvent(ev);
    }

    private void openRecents() {
        try {
            startActivity(new Intent(this, SpsmRecentsActivity.class));
        } catch (Throwable ignored) {
        }
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
        // Never throws: this runs on the home screen, and the home screen going
        // down takes the phone's interface with it. A missing or odd battery
        // reading is not worth that.
        try {
            updateBatteryText(intent);
        } catch (Throwable ignored) {
        }
    }

    private void updateBatteryText(Intent intent) {
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
        // The way the phone's own power saving screen reads: one big number,
        // one line under it. No build numbers, no badges.
        if (battery != null) battery.setText(pct + "%");
        if (remaining != null) remaining.setText(extra);
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
