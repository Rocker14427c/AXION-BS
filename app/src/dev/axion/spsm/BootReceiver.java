package dev.axion.spsm;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        // Module service.sh re-applies CPU/suspend. If the mode was on,
        // bring the 6-app home up after unlock.
        // Start listening for screen changes for as long as this process lives.
        ScreenReceiver.install(context);

        // The precision readout comes back after a reboot like everything else
        // the owner left on. It is zero-cost while the screen is off (see the
        // service), so there is no reason it should need a manual start.
        if (PrecisionService.enabled(context)) PrecisionService.start(context);
        new Thread(() -> {
            if (!Root.available() || !Root.isActive()) return;
            try {
                Intent i = new Intent(context, SpsmHomeActivity.class);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(i);
            } catch (Throwable ignored) {
                // A boot that cannot show the power-saving home must still boot:
                // the mode puts everything back on its own, with or without the
                // app, and a crash in a boot receiver is a much worse phone than
                // a missing home screen.
            }
        }).start();
    }
}
