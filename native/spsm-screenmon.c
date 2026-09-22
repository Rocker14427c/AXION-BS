/*
 * spsm-screenmon - tell the daemon when the panel changes, without polling.
 *
 * WHY THIS IS NATIVE, AND WHY ONLY THIS PART
 * ------------------------------------------
 * The rest of SPSM is shell because the work it does IS shell work: running
 * `pm`, `settings` and `cmd`, and writing sysfs nodes. Rewriting that in C++
 * would buy nothing - the cost is the binder round trip, not the interpreter -
 * and would throw away the thing that makes the module auditable.
 *
 * This one piece is different, and it is different for a reason a language
 * benchmark cannot show: a shell cannot WAIT on a kernel event. It has `sleep`,
 * and so the daemon's only way to notice the screen was to wake up, read a
 * number, and go back to sleep - once a second, about 86,000 times a day. Each
 * of those was a fork of /system/bin/sleep in the original, and every one of
 * them is a timer that stops the SoC reaching its deeper idle states. A module
 * whose entire purpose is to stop the phone waking up was itself the thing
 * waking it up.
 *
 * So this process does what the shell cannot:
 *
 *   - it BLOCKS in epoll_wait, using no CPU at all while nothing happens;
 *   - it listens on the kernel's uevent netlink socket, so a real panel change
 *     arrives as an event in microseconds rather than at the next poll;
 *   - it asks the sysfs attribute itself to wake it (EPOLLPRI), which the
 *     backlight drivers that call sysfs_notify() support, and which costs
 *     nothing on the ones that do not;
 *   - it keeps a timer as the guarantee - so a phone whose kernel is silent
 *     still behaves exactly as the old poll did.
 *
 * THE TIMER EARNS ITS LENGTH - IT IS NOT ASSUMED
 * ----------------------------------------------
 * Whether a backlight announces itself is a property of the kernel, and not one
 * that can be known in advance: it differs between SoCs, between ROMs, and
 * between the leds and backlight classes on the same phone. So the interval is
 * not a constant chosen by hope.
 *
 * It starts FAST - one second, exactly the poll it replaces - and only
 * lengthens once an event source has PROVEN itself by delivering a real panel
 * change that the timer had not already found. If the kernel never announces
 * anything, the interval simply stays at one second and the module behaves as
 * it always did. And if a change is ever discovered by the timer after events
 * had been trusted, the interval drops back to fast and stays there.
 *
 * The result: on a phone that announces, ~86,400 timer wakeups a day become
 * ~2,880 and the response to the power button gets FASTER (an event, not a
 * poll). On a phone that does not, nothing gets worse. There is no device on
 * which this is a downgrade, which is the only way to ship a change like this
 * to hardware nobody can test on.
 *
 * WHAT IT PROMISES ITS CALLER
 * ---------------------------
 * One line per event on stdout, flushed immediately:
 *
 *   state on        the panel is lit
 *   state off       the panel is dark
 *   tick            the slow timer fired; nothing has changed
 *
 * The first line is always a `state`, so the daemon learns where things stand
 * without asking. Reading a value it cannot parse is NOT reported as a state -
 * it is reported as a tick, so the shell falls through to its own rules
 * (screen_decide) exactly as it does today when a read fails. This process
 * decides nothing about the mode; it only says when to look.
 *
 * Usage: spsm-screenmon <brightness-node> [slow-tick] [asleep-tick]
 *   slow-tick-seconds is the interval used ONLY once events have proven
 *   themselves; until then, and again after any miss, the tick is 1 second.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include <sys/signalfd.h>
#include <linux/netlink.h>

#define TICK_DEFAULT 30      /* the safety net once events have proven themselves */
#define TICK_FAST     1      /* what the poll used to be: the starting point */
#define UEVENT_BUF   4096

/* -1 unreadable, 0 dark, 1 lit. "Unreadable" is a real answer and must not be
 * confused with dark: reporting a failed read as "off" is how a module drops a
 * phone into its deep phase while somebody is using it. */
static int panel_state(const char *path)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[32];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';

    /* The node holds a decimal number. Anything else is a reading that says
     * nothing, and is passed up as such. */
    int seen_digit = 0;
    long v = 0;
    for (const char *p = buf; *p; p++) {
        if (*p >= '0' && *p <= '9') { seen_digit = 1; v = v * 10 + (*p - '0'); }
        else if (*p == '\n' || *p == '\r' || *p == ' ' || *p == '\t') continue;
        else return -1;
    }
    if (!seen_digit) return -1;
    return v > 0 ? 1 : 0;
}

static void say(const char *line)
{
    /* write(2) rather than stdio: one syscall, no buffering to get wrong, and
     * the reader on the other end is a shell blocked in `read`. */
    size_t n = strlen(line);
    ssize_t w = write(STDOUT_FILENO, line, n);
    (void)w;
}

/* The kernel's uevent broadcast. Every device state change the kernel
 * announces lands here, which includes the backlight and the display on the
 * ROMs that emit them. Failing to open it is not fatal - the timer still
 * guarantees the old behaviour - so this returns -1 and the caller carries on. */
static int uevent_open(void)
{
    int fd = socket(PF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK,
                    NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;

    /* A small receive buffer on purpose: this socket is only used as a
     * doorbell - the payload is never parsed - so a burst must not be allowed
     * to grow the kernel's queue on a phone that is trying to save memory. */
    int sz = 32 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof(sz));

    struct sockaddr_nl addr;
    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = 0;          /* let the kernel assign, so two copies can coexist */
    addr.nl_groups = 1;       /* the kernel broadcast group */
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Does this uevent concern the display at all?
 *
 * Broad on purpose - see the call site. Anything that could plausibly be the
 * panel, the backlight or the display pipeline counts; everything else (the
 * battery, thermal, USB, the network) is ignored so the daemon is not woken
 * for it. */
static int uevent_is_display(const char *payload)
{
    static const char *const words[] = {
        "backlight", "lcd", "leds", "drm", "panel", "display",
        "graphics", "fb", NULL
    };
    for (int i = 0; words[i]; i++)
        if (strstr(payload, words[i])) return 1;
    return 0;
}

/* Set the repeating interval. Called again whenever the monitor changes its
 * mind about how much it trusts this kernel's announcements. */
static void arm_timer(int tfd, int secs)
{
    struct itimerspec its;
    memset(&its, 0, sizeof(its));
    its.it_value.tv_sec = secs;
    its.it_interval.tv_sec = secs;
    timerfd_settime(tfd, 0, &its, NULL);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <brightness-node> [tick-seconds]\n", argv[0]);
        return 2;
    }
    const char *node = argv[1];
    int slow_tick = (argc > 2) ? atoi(argv[2]) : TICK_DEFAULT;
    if (slow_tick < 1) slow_tick = TICK_DEFAULT;
    /* What the shell's own poll would have used with the screen off. Until
     * events have proven themselves this program must not wake MORE often than
     * the poll it replaced - and the poll was slower while asleep, which is
     * where a phone spends its life. Measured before this was added: 30 seconds
     * asleep cost 41 daemon wakeups polling and 150 on the untrusted event
     * path, because a flat one-second fallback is three times the old asleep
     * rate. Being faster than the thing you replaced is not an optimisation if
     * nobody asked for it and it costs battery. */
    int asleep_tick = (argc > 3) ? atoi(argv[3]) : 3;
    if (asleep_tick < 1) asleep_tick = 3;

    /* Begin at the old poll interval and earn the slow one. See the header:
     * whether this kernel announces backlight changes cannot be known until it
     * has actually done so. */
    int tick = TICK_FAST;
    int events_trusted = 0;

    /* A dead reader must end this process rather than leave it broadcasting
     * into a closed pipe forever: the daemon exiting is this monitor's cue to
     * exit too, and SIGPIPE on the write is how that arrives. */
    signal(SIGPIPE, SIG_DFL);

    int ep = epoll_create1(EPOLL_CLOEXEC);
    if (ep < 0) return 1;

    /* --- the slow guarantee ------------------------------------------------
     * Even with no event source working at all, this fires and the daemon
     * re-reads - which is precisely the behaviour of the poll it replaces,
     * only far less often. */
    int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (tfd >= 0) {
        arm_timer(tfd, tick);
        struct epoll_event ev = { .events = EPOLLIN, .data.fd = tfd };
        epoll_ctl(ep, EPOLL_CTL_ADD, tfd, &ev);
    }

    /* --- the kernel's own announcement ------------------------------------- */
    int ufd = uevent_open();
    if (ufd >= 0) {
        struct epoll_event ev = { .events = EPOLLIN, .data.fd = ufd };
        epoll_ctl(ep, EPOLL_CTL_ADD, ufd, &ev);
    }

    /* --- the attribute itself ----------------------------------------------
     * A sysfs attribute whose driver calls sysfs_notify() wakes POLLPRI on
     * exactly the change we care about: this is the fastest and cheapest
     * source there is, when the driver offers it. When it does not, epoll
     * simply never reports it and nothing is lost. */
    int nfd = open(node, O_RDONLY | O_CLOEXEC);
    if (nfd >= 0) {
        char drain[32];
        ssize_t r = read(nfd, drain, sizeof(drain));  /* POLLPRI needs a prior read */
        (void)r;
        struct epoll_event ev = { .events = EPOLLPRI | EPOLLERR, .data.fd = nfd };
        if (epoll_ctl(ep, EPOLL_CTL_ADD, nfd, &ev) < 0) {
            close(nfd);
            nfd = -1;
        }
    }

    /* --- the app's poke -----------------------------------------------------
     * The APK signals the daemon when it hears SCREEN_ON/SCREEN_OFF. Taking
     * the same signal here means the app's instant path stays instant: the
     * signal is delivered as a readable fd rather than interrupting a syscall,
     * so there is no race between the handler and the wait. */
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGUSR1);
    sigprocmask(SIG_BLOCK, &mask, NULL);
    int sfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (sfd >= 0) {
        struct epoll_event ev = { .events = EPOLLIN, .data.fd = sfd };
        epoll_ctl(ep, EPOLL_CTL_ADD, sfd, &ev);
    }

    /* The caller learns the state before anything happens, so it never has to
     * ask and never starts from a guess. */
    int last = panel_state(node);
    if (last == 1) say("state on\n");
    else if (last == 0) say("state off\n");
    else say("tick\n");
    /* A monitor started while the screen is already off must begin at the
     * asleep rate, not spend its first stretch waking once a second. */
    if (last == 0 && tfd >= 0) { tick = asleep_tick; arm_timer(tfd, tick); }

    struct epoll_event events[8];
    for (;;) {
        int n = epoll_wait(ep, events, 8, -1);      /* no CPU is used here */
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int recheck = 0;
        int by_timer = 0, by_event = 0, by_poke = 0;
        for (int i = 0; i < n; i++) {
            int fd = events[i].data.fd;
            if (fd == tfd) {
                by_timer = 1;
                unsigned long long expirations;
                ssize_t r = read(tfd, &expirations, sizeof(expirations));
                (void)r;
                recheck = 1;
            } else if (fd == ufd) {
                /* The payload IS looked at, and this was a correction.
                 *
                 * Treating every uevent as a doorbell sounds safely general,
                 * and on a desk it even looks fine. On a phone it is a bad
                 * mistake: the kernel announces battery levels, charging,
                 * thermal zones, USB, network and wakeup sources constantly,
                 * so "any uevent" means re-reading sysfs and waking the shell
                 * hundreds of times an hour for events that have nothing to do
                 * with the screen. Measured on the host, the event path used
                 * MORE CPU than the poll it replaced, purely from this noise.
                 *
                 * So a message only counts if it mentions something displayish.
                 * The match is deliberately broad (a substring, over the whole
                 * NUL-separated payload) because the naming differs between
                 * kernels - leds/backlight on this phone, drm or panel
                 * elsewhere - and the cost of a false positive is one wasted
                 * read of one small file. The cost of a false negative is
                 * nothing at all: the timer still catches it. */
                char buf[UEVENT_BUF];
                ssize_t got;
                while ((got = recv(ufd, buf, sizeof(buf) - 1, MSG_DONTWAIT)) > 0) {
                    /* The payload is a run of NUL-separated KEY=VALUE strings.
                     * Flattening the separators lets one plain substring search
                     * cover the whole message. */
                    for (ssize_t k = 0; k < got; k++)
                        if (buf[k] == '\0') buf[k] = '\n';
                    buf[got] = '\0';
                    if (uevent_is_display(buf)) {
                        recheck = 1;
                        by_event = 1;
                    }
                }
            } else if (fd == nfd) {
                /* POLLPRI on a sysfs attribute is only cleared by seeking back
                 * and reading; without this the descriptor stays ready and
                 * epoll spins - the exact busy loop this program exists to
                 * remove. */
                char buf[32];
                lseek(nfd, 0, SEEK_SET);
                ssize_t r = read(nfd, buf, sizeof(buf));
                (void)r;
                recheck = 1;
                by_event = 1;
            } else if (fd == sfd) {
                struct signalfd_siginfo si;
                ssize_t r = read(sfd, &si, sizeof(si));
                (void)r;
                recheck = 1;
                by_poke = 1;
                /* The app's poke is not evidence about the KERNEL: it proves
                 * the APK is alive, not that this backlight announces itself.
                 * Counting it as a proven event source would let a phone with
                 * a silent kernel slow its timer on the strength of something
                 * that only happens while the app is running. */
            }
        }
        if (!recheck) continue;

        int now = panel_state(node);
        if (now != last && now >= 0) {
            /* --- calibration ---------------------------------------------
             * Who found this change? If an event source did, this kernel does
             * announce, and the timer can be relaxed to its slow interval. If
             * only the timer found it, then a real screen change went by with
             * no announcement at all - events cannot be trusted here, and the
             * interval must go back to the old poll rate and stay there.
             *
             * `by_timer && !by_event` is the honest test: when both fire in
             * the same wakeup the event is what mattered and the timer merely
             * coincided. */
            if (by_event) {
                events_trusted = 1;
            } else if (by_timer) {
                /* A real change went by with no announcement: this kernel is
                 * silent, and events cannot be relied on here. */
                events_trusted = 0;
            }
            last = now;
            /* The interval that matches what we now know and what the panel is
             * doing: the slow backstop once events are trusted, otherwise
             * exactly the poll this replaced - fast with the screen on, slower
             * with it off. */
            {
                int want = events_trusted ? slow_tick
                                          : (now ? TICK_FAST : asleep_tick);
                if (want != tick) { tick = want; if (tfd >= 0) arm_timer(tfd, tick); }
            }
            say(now ? "state on\n" : "state off\n");
        } else if (now < 0) {
            /* The node would not answer. This is NOT reported as a state - a
             * failed read must never be turned into "off", which is how a
             * module deep-sleeps a phone somebody is using. The shell is told
             * to look and its own fallback chain (marker, dumpsys) decides. */
            say("tick\n");
        } else if (by_poke) {
            /* The APK said the screen changed, and the panel does not agree -
             * usually because the broadcast beats the backlight write by a few
             * milliseconds.
             *
             * A line MUST go out anyway. The daemon spends its wait blocked
             * reading this pipe, and on bash a USR1 trap does not break a
             * blocking read at all - so the pipe is the only thing that can
             * wake it, and staying silent here would swallow the very poke the
             * app sent to make the transition instant. The daemon re-reads the
             * panel itself and applies its own fallback chain, so a tick that
             * turns out to be premature costs one look and nothing else. */
            say("tick\n");
        } else if (by_timer) {
            /* The backstop fired and the panel is exactly as last reported.
             *
             * This still emits a tick, and deliberately so: it is the daemon's
             * periodic turn of its own loop, which is where the heartbeat, the
             * core-sleep timer and the drift checks live. Suppressing it would
             * save a wakeup and quietly stop all of them.
             *
             * What is NOT emitted is a tick for an EVENT that turned out to
             * change nothing - see below. */
            say("tick\n");
        }
        /* An event fired but the panel had not actually moved: say nothing at
         * all. This is the common case for the display uevents that accompany
         * a change we have already reported (the kernel often emits several),
         * and waking the shell to be told "no change" is exactly the cost this
         * program exists to remove. The daemon's own backstop still turns the
         * loop over on schedule. */
    }
    return 0;
}
