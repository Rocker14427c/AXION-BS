/*
 * spsm-gesturemon - the phone's own gestures, while SPSM's home is the home.
 *
 * WHY THIS EXISTS
 * ---------------
 * With gesture navigation (navigation_mode=2) the bottom edge of the screen
 * belongs to the launcher's TouchInteractionService: swipe up is Home, swipe
 * up and hold is Recents. SPSM suspends and stops the launcher - that is the
 * point of the mode - and the gestures die with it: the user is stranded in
 * whatever app was open, with no way home but the notification shade.
 * Bringing the launcher back costs its whole process (~99MB PSS on this
 * phone, and the wakeups of its service), which is exactly what the mode
 * exists to avoid.
 *
 * So the edge is watched here instead, the way the kernel sees it: this
 * process blocks in poll() on the touchscreen's evdev node and on a timerfd,
 * costing no CPU at all between touches, and recognizes the two gestures the
 * platform's own detector recognizes:
 *
 *   swipe up from the bottom band, released quickly   -> HOME command
 *   swipe up from the bottom band, held past the edge -> RECENTS command
 *                                                       (fires finger-down,
 *                                                        as the system's does)
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 * --------------------------------
 * It never consumes or grabs events - no EVIOCGRAB, no uinput. The screen
 * sees every touch exactly as it would without this process; an app that
 * draws its own bottom-edge UI keeps working, and whatever this fires, it
 * fires alongside - the same relationship the system gesture detector has
 * with the display. (The kernel-side remap ideas were measured and rejected:
 * see docs/ARCH-PERF-PLAN.md, 4e.)
 *
 * The commands it runs are given by the caller (the engine), so the module
 * decides WHAT a gesture means and this process only decides THAT one
 * happened. Defaults answer to the platform's own semantics: HOME is the
 * home keyevent (which the role swap points at SPSM's home), RECENTS starts
 * SPSM's own recents activity.
 *
 * USAGE
 *   spsm-gesturemon [--device /dev/input/eventN] [--script FILE]
 *                   [--screen-h PX] [--band PX] [--min-dy PX] [--hold-dy PX]
 *                   [--hold-ms MS] [--cooldown-ms MS]
 *                   [--home-cmd CMD] [--recents-cmd CMD] [--quiet]
 *
 *   --script FILE  synthetic event source for the test suite: lines of
 *                  "<t_ms> <x> <y> down|move|up", monotonic in t_ms. The
 *                  recognizer, the hold timer and the cooldown are the real
 *                  ones; only the kernel is replaced. Requires --screen-h.
 *   Sizes default from the panel's own reported maximums; 0 means "derive".
 *
 * Exit: 0 on SIGTERM/SIGINT or at the end of a --script file; 1 when no
 * usable touch device was found; 2 on bad arguments.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>

/* app_process wrappers, not the native cmd binary: from this process's
 * nohup'd root context on RMX3430, cmd's binder call dies ("Failure calling
 * service input: Failed transaction"), while input/am work everywhere else
 * in this module from the same context. lib.sh passes these explicitly from
 * cfg anyway; the defaults are for standalone runs. */
#define HOME_CMD_DEFAULT    "input keyevent 3"
#define RECENTS_CMD_DEFAULT "am start --user 0 -f 268435456 -n dev.axion.spsm/.SpsmRecentsActivity"

static int   opt_quiet = 0;
static const char *opt_device   = NULL;   /* NULL: discover */
static const char *opt_script   = NULL;   /* NULL: real evdev */
static const char *opt_home_cmd = HOME_CMD_DEFAULT;
static const char *opt_recents_cmd = RECENTS_CMD_DEFAULT;
static int opt_screen_h   = 0;            /* 0: derive from absinfo (or fail in script mode) */
static int opt_band       = 0;            /* 0: screen_h * 6 / 100 */
static int opt_min_dy     = 0;            /* 0: screen_h * 5 / 100 */
static int opt_hold_dy    = 40;
static int opt_hold_ms    = 350;
static int opt_cooldown_ms = 500;

static void logf_(const char *fmt, ...) {
	va_list ap;
	if (opt_quiet) return;
	va_start(ap, fmt);
	fprintf(stderr, "gesturemon: ");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	fflush(stderr);
	va_end(ap);
}

static long long now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ------------------------------------------------------------- recognizer */
/* One gesture at a time, first finger only. The state machine is fed
 * (t_ms, x, y, kind) events and answers by running the caller's commands;
 * device mode and --script mode share it byte for byte, so what the suite
 * proves is what the phone runs. */
enum { EV_DOWN, EV_MOVE, EV_UP, EV_HOLD_TICK };

struct recog {
	int   screen_h, band, min_dy, hold_dy, hold_ms, cooldown_ms;
	int   active;          /* a band touch is in progress */
	int   fired;           /* this touch already fired (hold) */
	int   x0, y0;          /* touchdown */
	int   lx, ly;          /* latest */
	long long t0;          /* touchdown time */
	long long hold_due;    /* t0 + hold_ms, 0 = not armed */
	long long cool_until;  /* ignore downs before this */
};

static void run_cmd(const char *cmd) {
	/* Fire and forget; SIGCHLD is SIG_IGN'd, so no zombies gather. A
	 * gesture is a rare, human-speed event: one fork of /system/bin/sh
	 * per swipe is nothing next to what the swipe itself wakes. */
	pid_t pid = fork();
	if (pid == 0) {
		/* The dispatchers (input/cmd/am - cmd-based on this ROM) hand their
		 * own fd 0/1/2 to the service inside the binder transaction. This
		 * process is a daemon whose inherited stdin can be a dead socket
		 * (an orphaned nohup), and a parcel carrying a closed fd fails the
		 * whole transaction: "Failure calling service input". Give the
		 * child fds that exist, whatever the parent was started from. */
		int nul = open("/dev/null", O_RDONLY);
		if (nul > 0) dup2(nul, STDIN_FILENO);
		else if (nul < 0) { int d = open("/dev/null", O_RDWR); if (d >= 0) dup2(d, STDIN_FILENO); }
		execl("/system/bin/sh", "sh", "-c", cmd, (char *)NULL);
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
}

/* Returns 1 when the hold timer must be (re)armed by the caller's clock. */
static int recog_feed(struct recog *r, long long t, int x, int y, int kind) {
	switch (kind) {
	case EV_DOWN:
		if (t < r->cool_until) return 0;
		if (y < r->screen_h - r->band) return 0;   /* not the edge: none of ours */
		r->active = 1; r->fired = 0;
		r->x0 = x; r->y0 = y; r->lx = x; r->ly = y;
		r->t0 = t; r->hold_due = t + r->hold_ms;
		return 1;
	case EV_MOVE:
		if (!r->active) return 0;
		r->lx = x; r->ly = y;
		return 0;
	case EV_HOLD_TICK: {
		int dy, dx;
		if (!r->active || r->fired) return 0;
		dy = r->y0 - r->ly;
		dx = r->lx - r->x0; if (dx < 0) dx = -dx;
		if (dy >= r->hold_dy && dx <= dy) {
			r->fired = 1;
			r->hold_due = 0;
			r->cool_until = t + r->cooldown_ms;
			logf_("recents (dy=%d held %lldms)", dy, t - r->t0);
			run_cmd(opt_recents_cmd);
		}
		return 0;
	}
	case EV_UP: {
		int dy, dx;
		if (!r->active) return 0;
		/* The release position IS the end of the swipe: latch it
		 * before measuring (device mode passes the SYN_REPORT latch,
		 * script mode the up line's own coordinates). */
		r->lx = x; r->ly = y;
		r->active = 0;
		r->hold_due = 0;
		if (r->fired) return 0;                    /* the hold already answered */
		dy = r->y0 - r->ly;
		dx = r->lx - r->x0; if (dx < 0) dx = -dx;
		/* Up, far enough, and more vertical than horizontal: Home. */
		if (dy >= r->min_dy && dx * 2 <= dy) {
			r->cool_until = t + r->cooldown_ms;
			logf_("home (dy=%d in %lldms)", dy, t - r->t0);
			run_cmd(opt_home_cmd);
		}
		return 0;
	}
	}
	return 0;
}

/* ------------------------------------------------------- script event mode */
static int run_script(struct recog *r) {
	FILE *f = fopen(opt_script, "r");
	char line[256];
	if (!f) { logf_("cannot open script %s: %s", opt_script, strerror(errno)); return 2; }
	while (fgets(line, sizeof line, f)) {
		long long t; int x, y; char kind[16];
		if (sscanf(line, "%lld %d %d %15s", &t, &x, &y, kind) != 4) continue;
		/* The real hold timer would have fired between events; the
		 * script's clock says when. Fire it when its time has come. */
		if (r->active && !r->fired && r->hold_due && t >= r->hold_due)
			recog_feed(r, r->hold_due, r->lx, r->ly, EV_HOLD_TICK);
		if (!strcmp(kind, "down"))     recog_feed(r, t, x, y, EV_DOWN);
		else if (!strcmp(kind, "move")) recog_feed(r, t, x, y, EV_MOVE);
		else if (!strcmp(kind, "up"))   recog_feed(r, t, x, y, EV_UP);
	}
	fclose(f);
	return 0;
}

/* --------------------------------------------------------- device discovery */
static int has_bit(const unsigned long *bits, int bit) {
	return (bits[bit / (sizeof(unsigned long) * 8)] >> (bit % (sizeof(unsigned long) * 8))) & 1UL;
}

struct touchdev {
	int fd, w, h, mt;   /* mt: 1 = protocol B multitouch, 0 = single-touch ABS_X/Y */
	char path[64], name[80];
};

static int open_touch(struct touchdev *td, const char *path) {
	unsigned long keybits[(KEY_MAX + 7) / (sizeof(unsigned long) * 8) + 1];
	unsigned long absbits[(ABS_MAX + 7) / (sizeof(unsigned long) * 8) + 1];
	memset(keybits, 0, sizeof keybits);
	memset(absbits, 0, sizeof absbits);
	td->fd = open(path, O_RDONLY | O_CLOEXEC);
	if (td->fd < 0) return 0;
	if (ioctl(td->fd, EVIOCGBIT(EV_KEY, sizeof keybits), keybits) < 0) goto no;
	if (!has_bit(keybits, BTN_TOUCH)) goto no;
	if (ioctl(td->fd, EVIOCGBIT(EV_ABS, sizeof absbits), absbits) < 0) goto no;
	if (has_bit(absbits, ABS_MT_POSITION_X) && has_bit(absbits, ABS_MT_POSITION_Y)) {
		struct input_absinfo ax, ay;
		if (ioctl(td->fd, EVIOCGABS(ABS_MT_POSITION_X), &ax) < 0) goto no;
		if (ioctl(td->fd, EVIOCGABS(ABS_MT_POSITION_Y), &ay) < 0) goto no;
		td->mt = 1; td->w = ax.maximum; td->h = ay.maximum;
	} else if (has_bit(absbits, ABS_X) && has_bit(absbits, ABS_Y)) {
		struct input_absinfo ax, ay;
		if (ioctl(td->fd, EVIOCGABS(ABS_X), &ax) < 0) goto no;
		if (ioctl(td->fd, EVIOCGABS(ABS_Y), &ay) < 0) goto no;
		td->mt = 0; td->w = ax.maximum; td->h = ay.maximum;
	} else goto no;
	if (td->w <= 0 || td->h <= 0) goto no;
	memset(td->name, 0, sizeof td->name);
	if (ioctl(td->fd, EVIOCGNAME(sizeof td->name), td->name) < 0)
		snprintf(td->name, sizeof td->name, "(unnamed)");
	snprintf(td->path, sizeof td->path, "%s", path);
	return 1;
no:
	close(td->fd); td->fd = -1;
	return 0;
}

static int discover_touch(struct touchdev *td) {
	char path[64];
	int i;
	if (opt_device) return open_touch(td, opt_device);
	for (i = 0; i < 64; i++) {
		snprintf(path, sizeof path, "/dev/input/event%d", i);
		if (open_touch(td, path)) return 1;
	}
	return 0;
}

/* ------------------------------------------------------------ evdev loop */
/* Protocol B, ANY slot: the first finger DOWN owns the gesture, whatever
 * slot the driver assigns it (this panel hands real swipes slots 2, 3, 5,
 * 7 - a slot-0-only filter threw every one of them away, which is what the
 * owner's working swipes proved on 2026-09-25). Every other finger is palm
 * noise until the owner lifts. Positions are latched per SYN_REPORT, exactly
 * as the input dispatcher reads them. */
struct mt_state {
	int slot;            /* current slot in the stream */
	int gslot;           /* slot the gesture finger owns, -1 = unowned */
	int tid0;            /* owning finger's tracking id, -1 = up */
	int x, y;            /* the owner's latest position */
	int x_latch, y_latch, tid_latch;   /* values at last SYN_REPORT */
	int have_x, have_y;
};

static int run_device(struct recog *r) {
	struct touchdev td;
	struct mt_state mt;
	int tfd, sfd, rc;
	sigset_t mask;
	struct pollfd pfds[3];

	if (!discover_touch(&td)) {
		logf_("no touch device with BTN_TOUCH and absolute axes found - the system keeps the edges");
		return 1;
	}
	if (opt_screen_h > 0) td.h = opt_screen_h;
	/* The panel answered how big it is; the derived band and minimum
	 * swipe follow it unless the caller gave numbers. */
	if (r->screen_h <= 0) r->screen_h = td.h;
	if (r->band   <= 0) r->band   = r->screen_h * 6 / 100;
	if (r->min_dy <= 0) r->min_dy = r->screen_h * 5 / 100;

	memset(&mt, 0, sizeof mt);
	mt.tid0 = -1; mt.gslot = -1; mt.tid_latch = -1; mt.x = -1; mt.y = -1;

	tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	if (tfd < 0) { logf_("timerfd: %s", strerror(errno)); close(td.fd); return 1; }

	sigemptyset(&mask);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGINT);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	sfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
	if (sfd < 0) { logf_("signalfd: %s", strerror(errno)); close(td.fd); close(tfd); return 1; }

	logf_("watching %s (%s, %dx%d) band=%d min_dy=%d hold: %dpx/%dms - swipe up is home, hold is recents",
	      td.path, td.name, td.w, td.h, r->band, r->min_dy, r->hold_dy, r->hold_ms);

	for (;;) {
		pfds[0].fd = td.fd;  pfds[0].events = POLLIN; pfds[0].revents = 0;
		pfds[1].fd = tfd;    pfds[1].events = POLLIN; pfds[1].revents = 0;
		pfds[2].fd = sfd;    pfds[2].events = POLLIN; pfds[2].revents = 0;
		rc = poll(pfds, 3, -1);
		if (rc < 0) {
			if (errno == EINTR) continue;
			logf_("poll: %s", strerror(errno));
			break;
		}
		if (pfds[2].revents & POLLIN) {           /* SIGTERM/SIGINT */
			struct signalfd_siginfo si;
			while (read(sfd, &si, sizeof si) == (ssize_t)sizeof si) { }
			logf_("signal - leaving the edge to the system");
			rc = 0;
			goto out;
		}
		if (pfds[1].revents & POLLIN) {           /* the hold timer */
			uint64_t exp;
			while (read(tfd, &exp, sizeof exp) == (ssize_t)sizeof exp) { }
			if (r->active && !r->fired) {
				recog_feed(r, now_ms(), mt.x_latch, mt.y_latch, EV_HOLD_TICK);
			}
			r->hold_due = 0;
		}
		if (pfds[0].revents & POLLIN) {
			struct input_event ev[32];
			ssize_t n = read(td.fd, ev, sizeof ev);
			ssize_t i;
			if (n <= 0) {
				if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
				logf_("touch device went away - exiting");
				rc = 1;
				goto out;
			}
			for (i = 0; i + sizeof(struct input_event) <= (size_t)n; i += sizeof(struct input_event)) {
				struct input_event *e = (struct input_event *)((char *)ev + i);
				if (e->type == EV_ABS) {
					if (e->code == ABS_MT_SLOT) { mt.slot = e->value; continue; }
					if (e->code == ABS_MT_TRACKING_ID) {
						if (e->value >= 0) {
							/* finger down: an unowned stream becomes this
							 * finger's gesture; a second finger while one
							 * is owned is noise and changes nothing */
							if (mt.tid0 < 0) { mt.gslot = mt.slot; mt.tid0 = e->value; }
							else if (mt.slot == mt.gslot) mt.tid0 = e->value;
						} else if (mt.slot == mt.gslot) {
							/* the owner lifted - the stream is unowned again */
							mt.tid0 = -1; mt.gslot = -1;
						}
						continue;
					}
					/* Only the gesture finger's slot moves the gesture. Before an
					 * owner exists there is nothing to move (protocol B sends the
					 * tracking id first in a down frame); a single-touch panel has
					 * no slots at all and always counts. */
					if (td.mt && mt.slot != mt.gslot) continue;
					switch (e->code) {
					case ABS_MT_POSITION_X:  mt.x = e->value; mt.have_x = 1; break;
					case ABS_MT_POSITION_Y:  mt.y = e->value; mt.have_y = 1; break;
					case ABS_X: if (!td.mt) { mt.x = e->value; mt.have_x = 1; } break;
					case ABS_Y: if (!td.mt) { mt.y = e->value; mt.have_y = 1; } break;
					default: break;
					}
				} else if (e->type == EV_KEY && !td.mt && e->code == BTN_TOUCH) {
					mt.tid0 = e->value ? 0 : -1;
				} else if (e->type == EV_SYN && e->code == SYN_REPORT) {
					long long t = now_ms();
					int was = mt.tid_latch;
					mt.tid_latch = mt.tid0;
					if (mt.have_x && mt.have_y) { mt.x_latch = mt.x; mt.y_latch = mt.y; }
					mt.have_x = mt.have_y = 0;
					if (was < 0 && mt.tid_latch >= 0) {
						/* finger down */
						if (recog_feed(r, t, mt.x_latch, mt.y_latch, EV_DOWN)) {
							struct itimerspec its;
							memset(&its, 0, sizeof its);
							its.it_value.tv_sec  = r->hold_ms / 1000;
							its.it_value.tv_nsec = (r->hold_ms % 1000) * 1000000L;
							if (its.it_value.tv_sec == 0 && its.it_value.tv_nsec == 0)
								its.it_value.tv_nsec = 1;
							timerfd_settime(tfd, 0, &its, NULL);
						}
					} else if (was >= 0 && mt.tid_latch < 0) {
						/* finger up */
						struct itimerspec its;
						memset(&its, 0, sizeof its);      /* disarm */
						timerfd_settime(tfd, 0, &its, NULL);
						recog_feed(r, t, mt.x_latch, mt.y_latch, EV_UP);
					} else if (mt.tid_latch >= 0) {
						recog_feed(r, t, mt.x_latch, mt.y_latch, EV_MOVE);
					}
				}
			}
		}
	}
out:
	close(sfd); close(tfd); close(td.fd);
	return rc;
}

/* ------------------------------------------------------------------- main */
static int intarg(int argc, char **argv, int *i, int *out) {
	if (*i + 1 >= argc) return 0;
	*out = atoi(argv[++*i]);
	return 1;
}

int main(int argc, char **argv) {
	struct recog r;
	int i;

	signal(SIGCHLD, SIG_IGN);          /* reaped by the kernel */
	signal(SIGPIPE, SIG_IGN);

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--device") && i + 1 < argc)      opt_device = argv[++i];
		else if (!strcmp(argv[i], "--script") && i + 1 < argc) opt_script = argv[++i];
		else if (!strcmp(argv[i], "--home-cmd") && i + 1 < argc)    opt_home_cmd = argv[++i];
		else if (!strcmp(argv[i], "--recents-cmd") && i + 1 < argc) opt_recents_cmd = argv[++i];
		else if (!strcmp(argv[i], "--screen-h"))    { if (!intarg(argc, argv, &i, &opt_screen_h)) return 2; }
		else if (!strcmp(argv[i], "--band"))        { if (!intarg(argc, argv, &i, &opt_band)) return 2; }
		else if (!strcmp(argv[i], "--min-dy"))      { if (!intarg(argc, argv, &i, &opt_min_dy)) return 2; }
		else if (!strcmp(argv[i], "--hold-dy"))     { if (!intarg(argc, argv, &i, &opt_hold_dy)) return 2; }
		else if (!strcmp(argv[i], "--hold-ms"))     { if (!intarg(argc, argv, &i, &opt_hold_ms)) return 2; }
		else if (!strcmp(argv[i], "--cooldown-ms")) { if (!intarg(argc, argv, &i, &opt_cooldown_ms)) return 2; }
		else if (!strcmp(argv[i], "--quiet"))       opt_quiet = 1;
		else { fprintf(stderr, "gesturemon: unknown argument %s\n", argv[i]); return 2; }
	}

	memset(&r, 0, sizeof r);
	r.hold_dy = opt_hold_dy;
	r.hold_ms = opt_hold_ms;
	r.cooldown_ms = opt_cooldown_ms;

	if (opt_script) {
		if (opt_screen_h <= 0) {
			fprintf(stderr, "gesturemon: --script needs --screen-h\n");
			return 2;
		}
		r.screen_h = opt_screen_h;
		r.band     = opt_band   > 0 ? opt_band   : r.screen_h * 6 / 100;
		r.min_dy   = opt_min_dy > 0 ? opt_min_dy : r.screen_h * 5 / 100;
		return run_script(&r);
	}

	/* Device mode: the panel's own maximums are the screen size, and the
	 * derived band and minimum swipe follow them inside run_device. */
	r.screen_h = opt_screen_h;               /* 0: filled from absinfo */
	r.band     = opt_band;
	r.min_dy   = opt_min_dy;
	return run_device(&r);
}
