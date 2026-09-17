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
import android.os.SystemClock;
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
    private TextView remaining;
    private View editButton;
    /** While this is true a tap on a filled slot takes that app out of it. */
    private boolean editing;
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
        remaining = findViewById(R.id.remaining);
        View exit = findViewById(R.id.btn_exit);
        if (exit != null) exit.setOnClickListener(v -> confirmExit());
        // Recents is the swipe up from the bottom, and nothing else: no button
        // and no long press, which is what the owner asked for. The swipe is read
        // in dispatchTouchEvent below, and the same gesture from inside another
        // app arrives as a MAIN/HOME intent (onNewIntent).
        // Editing the six apps from the home screen itself: the pencil turns the
        // slots into something you can take an app out of, and turns into a tick
        // while it is on. Taking an app out empties the slot, so the "+" is there
        // to put another app in - no separate screen, and no way to get stuck in
        // it (the tick, or leaving the screen, ends it).
        editButton = findViewById(R.id.btn_edit);
        if (editButton != null) editButton.setOnClickListener(v -> setEditing(!editing));
        Apps.fillDefaults(this);
        try {
            bindSlots();
        } catch (Throwable ignored) {
            // The clock, the battery and the way out are the parts that must
            // survive; the six slots are the part that must not take them down.
        }
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
        r.setOnClickListener(v -> openRecents("fallback-button"));
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
    /** One list per gesture: the system can also hand us a cancel mid-swipe. */
    private boolean swipeFired;

    /**
     * A swipe up from the bottom of SPSM's own screen opens its recents.
     *
     * <p>The owner's instruction: "only dragging bottom to up open spsm recents,
     * like how Axion recents opens". The swipe is read here and never consumed,
     * so taps and long presses on the six slots keep working exactly as before.
     *
     * <p>It is read on the MOVE, not on the UP, because of what this phone does
     * with the bottom edge. On gesture navigation Android takes that strip for
     * its own "go home" gesture: this activity is given the press and the first
     * centimetre of the drag, and then an ACTION_CANCEL. v3.5.0 waited for the
     * finger to lift, which is an event that gesture never produces - and two
     * hundred swipes opened nothing. The move itself is the signal.
     */
    @Override
    public boolean dispatchTouchEvent(android.view.MotionEvent ev) {
        try {
            float density = getResources().getDisplayMetrics().density;
            float h = getResources().getDisplayMetrics().heightPixels;
            switch (ev.getActionMasked()) {
                case android.view.MotionEvent.ACTION_DOWN:
                    touchStartY = ev.getY();
                    touchStartX = ev.getX();
                    swipeFired = false;
                    break;
                case android.view.MotionEvent.ACTION_MOVE: {
                    if (swipeFired) break;
                    float dy = touchStartY - ev.getY();
                    float dx = Math.abs(ev.getX() - touchStartX);
                    // Bottom third of the screen, upward, mostly vertical. 16dp of
                    // travel is more than a tap wobbles and less than the system
                    // takes to decide the strip is its own.
                    if (dy > 16 * density && dx < dy && touchStartY > h * 0.66f) {
                        swipeFired = true;
                        openRecents("swipe");
                    }
                    break;
                }
                case android.view.MotionEvent.ACTION_UP: {
                    if (swipeFired) break;
                    float dy = touchStartY - ev.getY();
                    float dx = Math.abs(ev.getX() - touchStartX);
                    if (dy > 24 * density && dx < dy && touchStartY > h * 0.66f) {
                        swipeFired = true;
                        openRecents("swipe");
                    }
                    break;
                }
                default:
                    break;
            }
        } catch (Throwable ignored) {
        }
        return super.dispatchTouchEvent(ev);
    }

    /**
     * "Go home" while this activity exists - on a gesture-navigation phone, what
     * a swipe up from inside an app becomes.
     *
     * <p>It opens the recents list for the same reason the swipe on our own
     * screen does: on every other Android that gesture means "show me what I was
     * doing", and redrawing the icons is the one answer nobody wants. The six
     * apps stay one tap away - the list has its own home button. Arriving by
     * pressing Back out of an app does not come through here at all, so Back
     * still lands on the six apps, exactly as before.
     */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        openRecents("go-home");
    }

    /** Opens the recents list, once per gesture, and says in the log how. */
    private void openRecents(String how) {
        long now = SystemClock.uptimeMillis();
        // Already opening: the list stamps openedAt the moment it comes up.
        if (now - SpsmRecentsActivity.openedAt < 700) return;
        // Already open, and has been for a while: a "go home" from inside the
        // list should do nothing rather than reload it.
        if (SpsmRecentsActivity.visible) return;
        SpsmRecentsActivity.openedAt = now;
        noteGesture(how);
        try {
            Intent i = new Intent(this, SpsmRecentsActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            startActivity(i);
        } catch (Throwable ignored) {
        }
    }

    /**
     * One line in the module's log, off the UI thread.
     *
     * <p>The gesture is invisible in every other record. When it does not open
     * the list there is nothing anywhere to say a swipe happened at all, so "did
     * it reach the app?" - the difference between a broken gesture and a phone
     * that keeps the bottom edge for itself - has no answer in the log.
     */
    private void noteGesture(final String how) {
        new Thread(() -> {
            try {
                Root.exec("sh " + Root.DIR + "/scripts/engine.sh gesture " + how);
            } catch (Throwable ignored) {
            }
        }).start();
    }

    /** Edit mode: slots show a badge, and a tap takes the app out. */
    private void setEditing(boolean on) {
        editing = on;
        try {
            if (editButton != null) {
                ((android.widget.ImageButton) editButton)
                        .setImageResource(on ? R.drawable.ic_check : R.drawable.ic_edit);
                editButton.setContentDescription(getString(on ? R.string.edit_done : R.string.edit));
            }
            TextView hint = findViewById(R.id.home_hint);
            if (hint != null) hint.setText(on ? R.string.edit_hint : R.string.swipe_for_recents);
        } catch (Throwable ignored) {
        }
        bindSlots();
    }

    /**
     * Bind the six slots, one at a time, and let none of them cost the screen.
     *
     * In this mode this activity IS the phone's home. A home that cannot be drawn
     * is much worse than a home with five icons in it, so a slot that cannot be
     * bound is skipped - the same reason the setup screen's row is wrapped: this
     * project has already shipped a build that died on opening because a slot was
     * held as the wrong kind of widget, and the phone found it instead of us.
     */
    private void bindSlots() {
        for (int i = 0; i < 6; i++) {
            try {
                bindSlot(i);
            } catch (Throwable ignored) {
            }
        }
    }

    private void bindSlot(final int i) {
        {
            final int index = i;
            // View, never a widget: the layout decides what a slot is.
            View slot = findViewById(slotIds[i]);
            // The fallback layout has no slots. This is the one screen whose
            // failure takes the phone's interface with it, so a missing slot is
            // skipped rather than thrown over.
            if (slot == null) return;
            Apps.bindSlot(this, slot, i, (idx, longPress) -> {
                String pkg = Prefs.getSlot(SpsmHomeActivity.this, idx);
                boolean filled = pkg != null && pkg.length() > 0;
                // Holding an app always means "choose another one for this slot",
                // whether or not the slots are being edited.
                if (longPress) {
                    AppPickerActivity.open(SpsmHomeActivity.this, idx);
                    return;
                }
                if (editing && filled) {
                    // Out of the slot: the module is told at once (Prefs.setSlot
                    // does that), the slot is empty, and "+" is ready for another
                    // app.
                    Prefs.setSlot(SpsmHomeActivity.this, idx, "");
                    Toast.makeText(SpsmHomeActivity.this, R.string.slot_removed,
                            Toast.LENGTH_SHORT).show();
                    bindSlots();
                    return;
                }
                if (!filled) {
                    AppPickerActivity.open(SpsmHomeActivity.this, idx);
                } else {
                    Apps.launch(SpsmHomeActivity.this, pkg);
                }
            });
            // The badge only exists while editing, and only on a slot with an app
            // in it - an empty slot already says "Add".
            View badge = slot.findViewById(R.id.badge);
            if (badge != null) {
                String pk = Prefs.getSlot(this, i);
                boolean has = pk != null && pk.length() > 0;
                badge.setVisibility(editing && has ? View.VISIBLE : View.GONE);
            }
        }
    }

    /**
     * The way out, as a large dark sheet that comes up from the bottom edge:
     * one sentence, Cancel in grey, Exit in red.
     *
     * Still a plain dialog underneath - the same two answers, the same
     * doExit() - so nothing about leaving the mode depends on the skin. A
     * platform that refuses the custom window still gets a working dialog.
     */
    private void confirmExit() {
        try {
            final android.app.Dialog d = new android.app.Dialog(this);
            // No title strip: the sheet draws its own title, and a platform title
            // bar above it would be an empty band of a different colour.
            try {
                d.requestWindowFeature(Window.FEATURE_NO_TITLE);
            } catch (Throwable ignored) {
            }
            View sheet = getLayoutInflater().inflate(R.layout.dialog_exit, null);
            View cancel = sheet.findViewById(R.id.dlg_cancel);
            View exit = sheet.findViewById(R.id.dlg_exit);
            if (cancel != null) cancel.setOnClickListener(v -> d.dismiss());
            if (exit != null) {
                exit.setOnClickListener(v -> {
                    d.dismiss();
                    doExit();
                });
            }
            d.setContentView(sheet);
            Window w = d.getWindow();
            if (w != null) {
                w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(0x00000000));
                w.setLayout(WindowManager.LayoutParams.MATCH_PARENT,
                        WindowManager.LayoutParams.WRAP_CONTENT);
                w.setGravity(android.view.Gravity.BOTTOM);
                w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
                WindowManager.LayoutParams lp = w.getAttributes();
                lp.dimAmount = 0.65f;
                w.setAttributes(lp);
            }
            d.setCanceledOnTouchOutside(true);
            d.show();
            return;
        } catch (Throwable ignored) {
        }
        // Any phone that would not show that: the plain dialog, unchanged.
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
        // One line, and it is the estimate rather than the percentage: how long
        // the phone has left is the number worth showing, and the two said the
        // same thing twice.
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
