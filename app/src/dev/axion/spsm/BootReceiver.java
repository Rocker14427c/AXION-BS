package dev.axion.spsm;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        // Module service.sh re-applies CPU/suspend. If the mode was on,
        // bring the 6-app home up after unlock.
        new Thread(() -> {
            if (!Root.available() || !Root.isActive()) return;
            Intent i = new Intent(context, SpsmHomeActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(i);
        }).start();
    }
}
