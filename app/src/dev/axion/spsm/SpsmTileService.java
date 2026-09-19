package dev.axion.spsm;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/**
 * The Quick Settings tile.
 *
 * <p>Tap = enter or leave the mode, right there - the tile runs the same
 * scripts the app's door does, and the app does not open. Long-press opens the
 * app's own options screen (declared in the manifest with the QS tile
 * preferences action, which is the system's own hook for long-press). The tile
 * shows what the mode actually is - coloured while it is on, plain while it is
 * off - read from the marker file on the phone, the same fact the door reads,
 * so it can never disagree with the log.
 */
public class SpsmTileService extends TileService {
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onStartListening() {
        super.onStartListening();
        refresh();
    }

    private void refresh() {
        new Thread(() -> {
            final State s = readState();
            main.post(() -> {
                Tile t = getQsTile();
                if (t == null) return;
                paint(t, s);
            });
        }).start();
    }

    private static final class State {
        boolean on;
        boolean busy;
    }

    private State readState() {
        State s = new State();
        String out = Root.exec("[ -f " + Root.ACTIVE + " ] && echo on || echo off; "
                + "[ -f " + Root.DIR + "/state/progress ] && echo busy");
        if (out == null) return s;
        if (out.contains("on")) s.on = true;
        if (out.contains("busy")) s.busy = true;
        return s;
    }

    private void paint(Tile t, State s) {
        t.setLabel(getString(R.string.tile_label));
        t.setState(s.on ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        if (s.busy) {
            t.setSubtitle(getString(R.string.tile_busy));
        } else {
            t.setSubtitle(null);
        }
        t.updateTile();
    }

    @Override
    public void onClick() {
        // Toggle in place. The work takes about half a minute (twenty knobs,
        // every one of them journalled), so the tile says it is working and
        // then paints the truth once the scripts have finished.
        final Tile t = getQsTile();
        if (t != null) {
            t.setSubtitle(getString(R.string.tile_busy));
            t.updateTile();
        }
        new Thread(() -> {
            boolean on = false;
            String out = Root.exec("[ -f " + Root.ACTIVE + " ] && echo on || echo off");
            if (out != null && out.contains("on")) on = true;
            if (on) {
                Root.exit();
            } else {
                Root.enter();
            }
            final State s = readState();
            main.post(() -> {
                Tile t2 = getQsTile();
                if (t2 == null) return;
                paint(t2, s);
            });
        }).start();
    }
}
