package dev.axion.spsm;

import android.app.Activity;
import android.content.Context;
import android.provider.Settings;
import android.view.View;

/**
 * The three buttons, drawn by this mode itself when the phone is not showing
 * its own.
 *
 * <p>The owner's instruction: stop using a swipe for recents and use
 * three-button navigation instead - "back will back, home button will take to
 * the home of spsm and recent button will open recents". The <em>nav_buttons</em>
 * option switches the phone's own navigation to three buttons while the mode is
 * on, which is what puts buttons at the bottom of <em>every</em> screen,
 * including inside other apps. This class is the fallback for the case where the
 * ROM refuses that switch: rather than a mode with no way to reach its own
 * recents, this mode draws its own three.
 *
 * <p>The two never appear together - {@link #draw} answers "is the phone showing
 * its own three buttons right now?", and the bar is hidden when the answer is
 * yes.
 *
 * <p>Nothing here can throw: this class is used from the power-saving home,
 * which is the phone's home screen while the mode is on, and a home that dies
 * takes the phone's UI with it.
 */
final class NavBar {

    /** secure setting: 0 = three-button, 1 = two-button, 2 = gesture navigation. */
    private static final String KEY = "navigation_mode";

    private NavBar() {}

    /**
     * Whether this mode must draw the buttons. True when the phone is not in
     * three-button mode - either because the ROM refused the switch, or because
     * the mode is running with the option switched off.
     */
    static boolean draw(Context c) {
        try {
            return Settings.Secure.getInt(c.getContentResolver(), KEY, 2) != 0;
        } catch (Throwable t) {
            // Unreadable: assuming the phone has buttons would be assuming the
            // user can reach the recents list, which is the one thing this is
            // here to guarantee.
            return true;
        }
    }

    /** Binds the three buttons, if this screen has them, and shows or hides the bar. */
    static void wire(Activity a, View.OnClickListener back, View.OnClickListener home,
                     View.OnClickListener recents) {
        try {
            View b = a.findViewById(R.id.nav_back);
            if (b != null) b.setOnClickListener(back);
            View h = a.findViewById(R.id.nav_home);
            if (h != null) h.setOnClickListener(home);
            View r = a.findViewById(R.id.nav_recents);
            if (r != null) r.setOnClickListener(recents);
        } catch (Throwable ignored) {
        }
        refresh(a);
    }

    /**
     * Shows the bar only when the phone is not showing its own.
     *
     * <p>Called again on every resume: the mode switches the phone's navigation
     * over at the start of a session, so a screen that came up before the switch
     * landed must not keep a second set of buttons on it.
     */
    static void refresh(Activity a) {
        try {
            View bar = a.findViewById(R.id.nav_bar);
            if (bar != null) bar.setVisibility(draw(a) ? View.VISIBLE : View.GONE);
        } catch (Throwable ignored) {
        }
    }
}
