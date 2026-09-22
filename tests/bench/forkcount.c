/*
 * forkcount - count the processes a command tree actually creates.
 *
 * Why this exists: the obvious counter, /proc/stat's `processes` line, is the
 * whole machine's. On any box that is doing something else (a CI runner, this
 * sandbox, a phone) it is swamped - measured here, the idle background alone
 * was ~2800 forks a second, which is more than a whole SPSM activation makes.
 * A number like that cannot tell you whether a change helped.
 *
 * So the count is taken from inside the tree being measured. fork/vfork/
 * posix_spawn/execve are interposed, each bumps a counter in a shared mapping,
 * and the mapping is inherited across fork and (via the file) across exec. The
 * result is exactly "processes created by this command and its children", with
 * nothing else in it.
 *
 * Two counters, because they cost different things:
 *   forks - a process created. On Android each one is a page-table copy, a
 *           scheduler enqueue and eventually a reap.
 *   execs - an image loaded on top of one. This is the expensive half: the
 *           linker runs, the binary is paged in, and for /system/bin/* on a
 *           phone in a power-saving mode it is where the tenths of a second
 *           the field logs complain about actually go.
 *
 * Build:  cc -shared -fPIC -O2 -o forkcount.so forkcount.c -ldl
 * Use:    SPSM_FORKCOUNT=/path/to/counterfile LD_PRELOAD=.../forkcount.so cmd
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <spawn.h>
#include <stdatomic.h>

struct counters {
    atomic_ullong forks;
    atomic_ullong execs;
};

static struct counters *slot;

/* The mapping is opened lazily and kept for the life of the process: doing it
 * in a constructor would run before the environment is necessarily usable in
 * every exec'd child, and doing it per call would put an open() on the hot
 * path we are trying to measure. */
static struct counters *counters(void)
{
    if (slot) return slot;
    const char *path = getenv("SPSM_FORKCOUNT");
    if (!path) return NULL;
    int fd = open(path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return NULL;
    if (ftruncate(fd, sizeof(struct counters)) != 0) { close(fd); return NULL; }
    void *m = mmap(NULL, sizeof(struct counters), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return NULL;
    slot = (struct counters *)m;
    return slot;
}

static void bump_fork(void)
{
    struct counters *c = counters();
    if (c) atomic_fetch_add_explicit(&c->forks, 1, memory_order_relaxed);
}

static void bump_exec(void)
{
    struct counters *c = counters();
    if (c) atomic_fetch_add_explicit(&c->execs, 1, memory_order_relaxed);
}

pid_t fork(void)
{
    static pid_t (*real)(void);
    if (!real) real = dlsym(RTLD_NEXT, "fork");
    pid_t r = real();
    /* Only the parent counts it, or a child would count its own birth again. */
    if (r > 0) bump_fork();
    return r;
}

/* dash and busybox ash reach for vfork when they can; uncounted, a whole
 * shell's worth of children would be invisible. */
pid_t vfork(void)
{
    /* Deliberately implemented as fork(): returning from an interposed vfork
     * in the child is undefined, and the count is worth more here than the
     * few microseconds vfork saves. */
    return fork();
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    static int (*real)(const char *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execve");
    bump_exec();
    return real(path, argv, envp);
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[])
{
    static int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                       const posix_spawnattr_t *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "posix_spawn");
    int r = real(pid, path, fa, attr, argv, envp);
    if (r == 0) { bump_fork(); bump_exec(); }
    return r;
}

int posix_spawnp(pid_t *pid, const char *file,
                 const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[])
{
    static int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                       const posix_spawnattr_t *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "posix_spawnp");
    int r = real(pid, file, fa, attr, argv, envp);
    if (r == 0) { bump_fork(); bump_exec(); }
    return r;
}
