package dev.axion.spsm;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;

/**
 * Publishes screen state to the engine the instant the screen changes.
 *
 * Without this the daemon has to poll, and polling is exactly the kind of
 * background wakeup a power saving mode should not be adding. The daemon still
 * polls the backlight node as a fallback, but while the app is installed this
 * makes the screen-off transition immediate - which is what makes entering and
 * leaving the mode feel instant instead of laggy.
 */
public class ScreenReceiver extends BroadcastReceiver {
    /**
     * Registers this receiver for real.
     *
     * The manifest entry alone never worked: SCREEN_ON and SCREEN_OFF are
     * broadcasts that the framework only delivers to receivers registered at
     * runtime, so a manifest-declared one is dead weight and every transition
     * went unnoticed. Nothing here depends on the app being alive - the module
     * polls the backlight node itself - but while the app is running this makes
     * the change instant instead of a poll away.
     *
     * Registering also republishes the state as it is right now, so a
     * transition missed while the app was not running cannot leave the engine
     * believing something stale.
     */
    public static void install(Context context) {
        try {
            ScreenReceiver receiver = new ScreenReceiver();
            IntentFilter filter = new IntentFilter();
            filter.addAction(Intent.ACTION_SCREEN_ON);
            filter.addAction(Intent.ACTION_SCREEN_OFF);
            // The receiver feeds a root shell, which is not cheap: it has no
            // business running on the main thread, and it must not hold the app
            // up either.
            context.getApplicationContext().registerReceiver(receiver, filter);
            publishCurrent(context);
        } catch (Throwable ignored) {
            // Nothing here is worth failing a boot or an activity over.
        }
    }

    /** Tells the engine where things stand right now, without waiting for an event. */
    private static void publishCurrent(Context context) {
        boolean interactive = true;
        try {
            android.os.PowerManager pm =
                    (android.os.PowerManager) context.getSystemService(Context.POWER_SERVICE);
            if (pm != null) interactive = pm.isInteractive();
        } catch (Throwable ignored) {
        }
        final String state = interactive ? "on" : "off";
        new Thread(() -> Root.writeScreenState(state)).start();
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || intent.getAction() == null) return;
        final String action = intent.getAction();
        final String state;
        if (Intent.ACTION_SCREEN_ON.equals(action)) {
            state = "on";
        } else if (Intent.ACTION_SCREEN_OFF.equals(action)) {
            state = "off";
        } else {
            return;
        }
        new Thread(() -> Root.writeScreenState(state)).start();
    }
}
