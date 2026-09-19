package dev.axion.spsm;

import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/**
 * The Quick Settings tile - "Super Battery Saver".
 *
 * <p>Tap = enter or leave the mode, right there; the app never opens. The long
 * work is handed to root and DETACHED from this process (nohup), so even if
 * the system unbinds this tile service mid-way, the scripts finish and the
 * phone is fully restored - a tap during a transition is ignored until the
 * mode is idle again, which is why the tile can never be pressing two
 * transitions into each other. The tile repaints itself every couple of
 * seconds while a transition runs, and shows what the phone itself says:
 * coloured while the mode is on, plain while it is off, exactly like the
 * system's own tiles. Long-press opens the options (the manifest points the
 * system's QS tile-preferences action at KnobsActivity).
 */
public class SpsmTileService extends TileService {
    private final Handler main = new Handler(Looper.getMainLooper());
    private boolean watching = false;

    @Override
    public void onStartListening() {
        super.onStartListening();
        refresh();
    }

    @Override
    public void onTileRemoved() {
        super.onTileRemoved();
        watching = false;
    }

    private void refresh() {
        new Thread(() -> {
            final State s = readState();
            main.post(() -> {
                Tile t = getQsTile();
                if (t != null) paint(t, s);
            });
        }).start();
    }

    private static final class State {
        boolean on;
        boolean busy;
    }

    private State readState() {
        State s = new State();
        // Busy is what the progress file SAYS, not whether it exists: the
        // engine writes "Applying…"/"Restoring…" while a transition runs and
        // removes the file when the mode settles, and a boot clears it. A file
        // that merely exists must never read as "working" - that is exactly
        // the stuck tile this round is deleting.
        String out = Root.exec("[ -f " + Root.ACTIVE + " ] && echo on || echo off; "
                + "p=" + Root.DIR + "/state/progress; "
                + "case $(cat $p 2>/dev/null) in Applying*|Restoring*|Starting*) echo busy ;; esac", 10);
        if (out == null) return s;
        if (out.contains("on")) s.on = true;
        if (out.contains("busy")) s.busy = true;
        return s;
    }

    private void paint(Tile t, State s) {
        t.setLabel(getString(R.string.tile_label));
        t.setState(s.on ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        t.setSubtitle(s.busy ? getString(R.string.tile_busy) : null);
        t.updateTile();
    }

    @Override
    public void onClick() {
        final State s = readState();
        if (s.busy) {
            // A transition is already running: pressing again must not start a
            // second one on top of it. Say so, and keep watching until the
            // phone is idle - then the tile shows the truth.
            watch();
            return;
        }
        final boolean turnOn = !s.on;
        // Detached from this process on purpose: su forks the script with
        // nohup and returns at once, so the work survives this service being
        // unbound, and nothing here can sit "waiting" on a pipe for a minute.
        if (turnOn) {
            Root.execDetached("nohup sh " + Root.ENTER + " >/dev/null 2>&1 &");
        } else {
            Root.execDetached("nohup sh " + Root.EXIT + " >/dev/null 2>&1 &");
        }
        final Tile t = getQsTile();
        if (t != null) {
            t.setSubtitle(getString(R.string.tile_busy));
            t.updateTile();
        }
        watch();
    }

    /** Repaint the tile every couple of seconds until the phone is idle. */
    private void watch() {
        if (watching) return;
        watching = true;
        watchTick(0);
    }

    private void watchTick(final int n) {
        main.postDelayed(() -> {
            final State s = readState();
            Tile t = getQsTile();
            if (t != null) paint(t, s);
            if (s.busy && n < 100) {
                watchTick(n + 1);
            } else {
                watching = false;
            }
        }, 2500);
    }
}
