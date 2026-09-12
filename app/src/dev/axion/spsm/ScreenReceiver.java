package dev.axion.spsm;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

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
