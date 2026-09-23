package dev.axion.spsm;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.Icon;
import android.os.BatteryManager;
import android.os.Handler;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;

import java.util.Locale;

/**
 * The precision battery readout: 31.63, not 32.
 *
 * The owner's request: a percentage in two decimals that moves smoothly with how
 * hard the phone is working and how fast it charges, in this device's own
 * calibration, and that costs no battery. This is the honest version of that,
 * built on two measurements taken on this phone before a line was written:
 *
 *   1. The gauge charge_counter reports level x 60000 uAh exactly (2 460 000 at
 *      level 41 - the whole number, no remainder). One percent is 60 000 uAh on
 *      this device, and the counter itself only steps at whole percents. So the
 *      hundredths between two gauge steps can only come from integrating the
 *      live current: a coulomb count between the gauge anchors. That is also
 *      what makes the number move at the real pace of use or charge - the
 *      current IS that pace.
 *
 *   2. current_now on this device is signed: +1 326 000 while charging,
 *      -249 000..-429 000 discharging. The sign is still reconciled against the
 *      battery status each tick, so a kernel that reports magnitudes behaves.
 *
 * The owner's acceptance test, given as a correction the first hour: when the
 * phone battery says 43, this readout must say 43.xx - never 42.xx. So the
 * model refines the system percentage instead of replacing it: the whole number
 * is ALWAYS the gauge own level, and the hundredths are the position inside that
 * one-percent bucket, walked by the integrated current (one bucket = 60 000
 * uAh). At every gauge step the number re-seats on the new whole percent - the
 * small snap is the gauge own tick - and a plug or unplug turns the smoothed
 * current over instantly so the number never walks the wrong way while the
 * average catches up. The first build here kept an independent coulomb count
 * and the owner found it showing 42.xx against a system 43; he was right.
 *
 * Zero cost, by construction: no wake locks, no alarms, no timers of any kind.
 * The tick loop is a plain Handler that runs only while the screen is on (the
 * CPU is awake anyway), and SCREEN_OFF removes even that. While the screen is
 * off this service does not execute a single line until the screen comes back.
 * It has to hold a foreground notification to exist - the status bar icon of
 * that notification is the readout, drawn as a bitmap the system tints like any
 * status-bar glyph.
 */
public class PrecisionService extends Service {
    static final String PREF = "precision_battery";
    private static final String CHANNEL = "precision";
    private static final int NOTIF_ID = 4071;
    /** uAh per one percent, measured on this device (level x 60000 == counter). */
    private static final double Q_PCT = 60000.0;
    private static final long TICK_MS = 1500;

    private final Handler h = new Handler();
    private BatteryManager bm;
    private NotificationManager nm;
    private PowerManager pm;

    /**
     * How far through the current 1% bucket, from its top: 0 = just entered (the
     * number sits at level + 0.995), 1 = exhausted (the number sits at level).
     * Signed current walks it. Re-seated at every gauge step so the whole number
     * always equals the system battery percentage.
     */
    private double fill = 0.5;
    /** smoothed current in uA, + = charging */
    private double emaI = 0;
    private long lastCc = Long.MIN_VALUE;
    private long lastMs = 0;
    private boolean ticking;

    public static void start(Context c) {
        try {
            Prefs.sp(c).edit().putBoolean(PREF, true).apply();
            c.startForegroundService(new Intent(c, PrecisionService.class));
        } catch (Throwable ignored) {
        }
    }

    public static void stop(Context c) {
        try {
            Prefs.sp(c).edit().putBoolean(PREF, false).apply();
            c.stopService(new Intent(c, PrecisionService.class));
        } catch (Throwable ignored) {
        }
    }

    static boolean enabled(Context c) {
        try {
            return Prefs.sp(c).getBoolean(PREF, true);
        } catch (Throwable t) {
            return true;
        }
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            step();
            if (interactive()) h.postDelayed(this, TICK_MS);
            else ticking = false;
        }
    };

    private final BroadcastReceiver scr = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            try {
                if (Intent.ACTION_SCREEN_OFF.equals(i.getAction())) {
                    h.removeCallbacks(tick);
                    ticking = false;
                } else if (Intent.ACTION_SCREEN_ON.equals(i.getAction())) {
                    // Coming back from a gap the integral did not see: the fill
                    // is kept so the number does not jump at a screen-on, and a
                    // level change across the gap re-seats it on the next tick.
                    startTicking();
                }
            } catch (Throwable ignored) {
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        bm = (BatteryManager) getSystemService(BATTERY_SERVICE);
        nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        pm = (PowerManager) getSystemService(POWER_SERVICE);
        try {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL, "Precision battery", NotificationManager.IMPORTANCE_LOW);
            ch.setSound(null, null);
            ch.enableVibration(false);
            ch.setShowBadge(false);
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
        } catch (Throwable ignored) {
        }
        try {
            IntentFilter f = new IntentFilter();
            f.addAction(Intent.ACTION_SCREEN_ON);
            f.addAction(Intent.ACTION_SCREEN_OFF);
            registerReceiver(scr, f);
        } catch (Throwable ignored) {
        }
        step();
        try {
            startForeground(NOTIF_ID, build());
        } catch (Throwable ignored) {
        }
        startTicking();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int id) {
        startTicking();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        try { h.removeCallbacks(tick); } catch (Throwable ignored) {}
        try { unregisterReceiver(scr); } catch (Throwable ignored) {}
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private boolean interactive() {
        try {
            return pm != null && pm.isInteractive();
        } catch (Throwable t) {
            return false;
        }
    }

    private void startTicking() {
        if (ticking || !interactive()) return;
        ticking = true;
        h.post(tick);
    }

    // ---------------------------------------------------------------- math

    private long cc = Long.MIN_VALUE;
    private long iNow = 0;
    private int level = -1;
    private boolean charging = false;

    private void step() {
        try {
            Intent b = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (b == null) return;
            level = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int st = b.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
            charging = st == BatteryManager.BATTERY_STATUS_CHARGING
                    || st == BatteryManager.BATTERY_STATUS_FULL;
            long counter = level >= 0 ? (long) (level * Q_PCT) : Long.MIN_VALUE;
            try {
                long v = bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER);
                if (v != Long.MIN_VALUE && v > 0) counter = v;
            } catch (Throwable ignored) {
            }
            try {
                long v = bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW);
                if (v != Long.MIN_VALUE) iNow = v;
            } catch (Throwable ignored) {
            }
            // Sign reconciliation: this device reports + while charging. A kernel
            // that only reports magnitudes is put right by the status.
            if (charging && iNow < 0) iNow = -iNow;
            if (!charging && iNow > 0) iNow = -iNow;
            cc = counter;
            integrate();
            post();
        } catch (Throwable ignored) {
        }
    }

    private void integrate() {
        long now = SystemClock.elapsedRealtime();
        if (lastMs == 0 || now - lastMs > 30_000) {
            // First tick, or a gap the integral cannot reconstruct (screen off).
            // The fill is kept as it is so the number does not jump at a
            // screen-on; a level change across the gap re-seats it below.
            emaI = iNow;
            lastMs = now;
            if (cc != lastCc && lastCc != Long.MIN_VALUE) {
                fill = (cc < lastCc) ? 0.0 : 1.0;
            }
            lastCc = cc;
            return;
        }
        double dt = (now - lastMs) / 1000.0;
        lastMs = now;
        // A sign reversal is a plug or an unplug: the smoothed current turns
        // over instantly, or the number walks the wrong way while it catches up.
        if (emaI * iNow < 0) emaI = iNow;
        else emaI = emaI * 0.7 + iNow * 0.3;
        fill += -emaI * dt / 3600.0 / Q_PCT;
        if (cc != lastCc && lastCc != Long.MIN_VALUE) {
            // The gauge stepped: re-seat on the new whole percent. A step down
            // enters the new bucket at the top, a step up at the bottom. The
            // snap is small when the bucket really held 60 000 uAh (nothing
            // visible) and grows only as far as the gauge own bucket width
            // differs from that - and it always lands the integer on the number
            // the phone itself is showing.
            fill = (cc < lastCc) ? 0.0 : 1.0;
        }
        lastCc = cc;
        if (fill > 1) fill = 1;
        if (fill < 0) fill = 0;
        // Full and still plugged: sit on 100.00 rather than drifting past it.
        if (level == 100 && charging) fill = 0;
    }

    /**
     * level + position inside the bucket. The whole number is the gauge own
     * level, always - 0.995 caps the fraction so two-decimal rounding can never
     * print level+1 ("42.99" must round to 42.99, not 43.00).
     */
    private double pct() {
        if (level < 0) return 0;
        double frac = 1.0 - fill;
        if (frac > 0.995) frac = 0.995;
        if (frac < 0.0) frac = 0.0;
        double p = level + frac;
        return p > 100.0 ? 100.0 : p;
    }

    /** percent per hour, from the smoothed current: uA / (uAh per percent) */
    private double ratePerHour() {
        return emaI / Q_PCT;
    }

    // -------------------------------------------------------- presentation

    private void post() {
        try {
            nm.notify(NOTIF_ID, build());
        } catch (Throwable ignored) {
        }
    }

    private Notification build() {
        String pct = String.format(Locale.US, "%.2f", pct());
        int ma = (int) Math.round(emaI / 1000.0);
        double rate = ratePerHour();
        String detail = charging
                ? String.format(Locale.US, "+%d mA (+%.1f%%/h)", ma, rate)
                : String.format(Locale.US, "%d mA (%.1f%%/h)", ma, rate);
        Intent open = new Intent(this, SetupActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(Icon.createWithBitmap(glyph(pct)))
                .setContentTitle(pct + "%")
                .setContentText(detail)
                .setContentIntent(pi)
                .setOngoing(true)
                .setPriority(Notification.PRIORITY_MIN)
                .setDefaults(0)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build();
    }

    /**
     * The number as a status-bar glyph. The system tints notification icons from
     * their alpha channel, so this draws white-on-transparent text: what survives
     * is the shape of the digits, in the bar colour. Wide bitmaps render wide -
     * the same trick network-speed indicators use to live in the bar.
     */
    private Bitmap glyph(String s) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setTypeface(Typeface.create("sans-serif-condensed", Typeface.BOLD));
        p.setTextSize(52f);
        p.setColor(0xFFFFFFFF);
        float w = p.measureText(s);
        Bitmap b = Bitmap.createBitmap((int) Math.ceil(w) + 10, 64, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        c.drawText(s, 5f, 52f, p);
        return b;
    }
}
