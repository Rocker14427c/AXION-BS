/*
 * execprofile - which programs a command tree runs, and how many times.
 *
 * The fork counter says how much is spent; this says on what. It interposes
 * execve and appends the basename of every image loaded to a log, so a run can
 * be reduced to "this module spent 900 execs on `date`" - which is the sort of
 * fact that decides where a rewrite is worth doing and where it is not.
 *
 * Build: cc -shared -fPIC -O2 -o execprofile.so execprofile.c -ldl
 * Use:   SPSM_EXECLOG=/path/log LD_PRELOAD=.../execprofile.so cmd
 *        sort /path/log | uniq -c | sort -rn
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void note(const char *path, char *const argv[])
{
    const char *log = getenv("SPSM_EXECLOG");
    if (!log) return;
    /* O_APPEND with one write() per record: concurrent children are all
     * appending to this file, and a single write under the pipe-buffer size is
     * the only thing that keeps their lines from interleaving. */
    int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;

    char line[256];
    size_t n = 0;
    for (const char *p = base; *p && n < 64; p++) line[n++] = *p;
    /* The first argument too: `settings get` and `settings put` are different
     * costs, and a profile that lumps them is not actionable. */
    if (argv && argv[0] && argv[1]) {
        line[n++] = ' ';
        for (const char *p = argv[1]; *p && n < 120; p++) line[n++] = *p;
    }
    line[n++] = '\n';
    ssize_t w = write(fd, line, n);
    (void)w;
    close(fd);
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    static int (*real)(const char *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execve");
    note(path, argv);
    return real(path, argv, envp);
}
