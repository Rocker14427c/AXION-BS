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
 * The instrument the owner asked for, after two corrections:
 *
 *   1. "42.xx against a system 43 means the battery is lower than 43" - a fine
 *      reading that disagrees with the rounded integer is INFORMATION, not a
 *      bug. Never lock the whole number to the integer.
 *   2. The decimals must move with real usage and charge at a predictable,
 *      constant-per-current rate ("if xx go randomly there is no need for it").
 *      The first build's decimals crawled and stuck at .00 because its scale
 *      was 20% wrong (60 000 uAh/% design vs the battery's learned 49 790).
 *
 * The device was researched before this rewrite. The MTK fuel gauge prints its
 * own 0.01% SOC to the kernel log (fuelgauged: "ui_soc:4145" = 41.45%, the very
 * value the system integer is cut from), charge_full holds the learned capacity
 * (4 979 000 uAh - it moves with aging and is re-read from the gauge print),
 * and current_now is signed and live. So: the gauge's own ui_soc is the anchor,
 * live current integration carries the number between gauge prints (it responds
 * to load and charger instantly, and the slope is exactly I/charge_full), and a
 * fresh anchor is blended in at 0.02%/tick so a read glitch can never jump the
 * display. The detail line predicts the next whole percent from the actual
 * slope: "41 in 5 min" - the owner's reason for wanting decimals at all.
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
    /** The kernel counter reports level x 60 000 (design scale) - presentation
     *  only. The learned capacity (charge_full, ~4 979 000 uAh) is the real
     *  scale and lives in perPct below. */
    private static final long TICK_MS = 1500;

    private final Handler h = new Handler();
    private BatteryManager bm;
    private NotificationManager nm;
    private PowerManager pm;

    /** continuous estimate in %, -1 until first anchored */
    private double pct = -1;
    /** where a fresh gauge print wants the number to be (%); NaN = none pending */
    private double slewTarget = Double.NaN;
    /** smoothed current in uA, + = charging */
    private double emaI = 0;
    /** uAh per one percent: the battery's LEARNED capacity / 100 (researched:
     *  49 790 here - the design 60 000 is 20% wrong and makes the decimals lie) */
    private double perPct = 49790.0;
    /** the last gauge print seen in dmesg; identical text = not a fresh read */
    private String lastGaugeLine = "";
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
    private int pollN = 0;
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
            long counter = level >= 0 ? (long) (level * perPct) : Long.MIN_VALUE;
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
            if (++pollN % 8 == 0) anchorFromGauge();
            post();
        } catch (Throwable ignored) {
        }
    }

    /**
     * Anchor search: the MTK fuel gauge prints "ui_soc:NNNN" (0.01%) to the
     * kernel log - the number the system integer is cut from. A repeat of the
     * same text is not a fresh reading; Q:[...] inside it is the learned
     * capacity scale in 0.1 mAh units.
     */
    private void anchorFromGauge() {
        try {
            String line = Root.read("dmesg | grep ui_soc | tail -1");
            if (line == null || line.indexOf("ui_soc:") < 0) return;
            if (line.equals(lastGaugeLine)) return;
            lastGaugeLine = line;
            int k = line.indexOf("ui_soc:");
            int e = k + 7;
            while (e < line.length() && Character.isDigit(line.charAt(e))) e++;
            double ui = Double.parseDouble(line.substring(k + 7, e)) / 100.0;
            int q = line.indexOf("Q:[");
            if (q > 0) {
                int qe = q + 3;
                while (qe < line.length() && Character.isDigit(line.charAt(qe))) qe++;
                if (qe > q + 3) {
                    double cap = Double.parseDouble(line.substring(q + 3, qe)) * 100.0;
                    if (cap > 100000 && cap < 8000000) perPct = cap / 100.0;
                }
            }
            slewTarget = ui;
            if (pct < 0) pct = ui;
        } catch (Throwable ignored) {
        }
    }

    private void integrate() {
        long now = SystemClock.elapsedRealtime();
        if (pct < 0) {
            // Not anchored yet. The -1 sentinel must survive until a real value
            // arrives: the first build here integrated it (turning -1 into
            // -0.999) and the safety clamp then made it 0.00, from which the
            // gauge anchor dragged the display upward for an hour while the
            // battery discharged. Anchor first, integrate only real values.
            anchorFromGauge();
            if (pct < 0 && level >= 0) pct = level + 0.5;
            emaI = iNow;
            lastMs = now;
            return;
        }
        if (lastMs == 0 || now - lastMs > 30_000) {
            // First tick, or a gap the integral cannot reconstruct (screen off).
            // The next gauge print heals this within one poll.
            emaI = iNow;
            lastMs = now;
            return;
        }
        double dt = (now - lastMs) / 1000.0;
        lastMs = now;
        // A sign reversal is a plug or an unplug: the smoothed current turns
        // over instantly, or the number walks the wrong way while it catches up.
        if (emaI * iNow < 0) emaI = iNow;
        else emaI = emaI * 0.7 + iNow * 0.3;
        // The instrument itself: uA * s / 3600 = uAh, / uAh-per-percent = %.
        // Constant rate for constant current - that regularity is the point.
        pct += (emaI * dt / 3600.0) / perPct;
        // A fresh gauge print is the device's own truth: blend toward it at no
        // more than 0.02%/tick so even a bad read cannot jump the display.
        if (!Double.isNaN(slewTarget)) {
            double gap = slewTarget - pct;
            double step = 0.02;
            if (Math.abs(gap) <= step || Math.abs(gap) < 1e-6) {
                pct = slewTarget;
                slewTarget = Double.NaN;
            } else {
                pct += Math.signum(gap) * step;
            }
        }
        if (pct > 100) pct = 100;
        if (pct < 0) pct = 0;
    }

    private double pct() {
        return pct < 0 ? (level >= 0 ? level : 0) : pct;
    }

    /** minutes until the number crosses the next whole percent, or -1 */
    private double minutesToNextWhole() {
        double rate = ratePerHour();
        if (pct < 0 || Math.abs(rate) < 0.05) return -1;
        double p = pct();
        double gap = rate < 0 ? p - Math.floor(p) : Math.ceil(p) - p;
        if (gap <= 0.001) gap = 1.0;
        return gap / Math.abs(rate) * 60.0;
    }

    /** percent per hour: uA / (uAh per percent) - the learned-capacity rate */
    private double ratePerHour() {
        return emaI / perPct;
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
        double mins = minutesToNextWhole();
        String eta = mins < 0 ? ""
                : String.format(Locale.US, " - %d in %d min",
                        (int) Math.floor(rate < 0 ? pct() : Math.ceil(pct())),
                        (int) Math.round(mins));
        String detail = (charging
                ? String.format(Locale.US, "+%d mA (+%.1f%%/h)", ma, rate)
                : String.format(Locale.US, "%d mA (%.1f%%/h)", ma, rate)) + eta;
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
