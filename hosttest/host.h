// Host test runner only (hosttest.sh): the bits of libc the runner uses to
// read fixtures and report. Libraries in lib/ never see this header; they
// must build freestanding (hosttest.sh checks with x86_64-unknown-none-elf).
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

// Loopback TCP for live tests (lib/tls talks to a local openssl s_server).
// Only the host runner uses these; libraries never do their own I/O.
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

/// Connect to 127.0.0.1:port with 10-second send/receive timeouts; -1 on error.
static inline int host_tcp_connect(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct timeval tv = { 10, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}

static inline long host_send(int fd, const void *p, long n) {
    long done = 0;
    while (done < n) {
        long k = (long)send(fd, (const char *)p + done, (size_t)(n - done), 0);
        if (k <= 0) return -1;
        done += k;
    }
    return done;
}

/// Bytes received (0 at EOF, -1 on error or timeout).
static inline long host_recv(int fd, void *p, long n) { return (long)recv(fd, p, (size_t)n, 0); }

static inline void host_close(int fd) { close(fd); }

// Child processes for live tests (Swift marks these unavailable on Darwin;
// C wrappers are fine in the host runner).
static inline FILE *host_popen(const char *cmd) { return popen(cmd, "r"); }
static inline int host_pclose(FILE *f) { return pclose(f); }
static inline int host_system(const char *cmd) { return system(cmd); }

// Run fn(arg) on a thread with a `bytes` stack and wait for it (tests that
// recursion stays within Wiffer's 512 KB user stack). -1 if it can't start.
#include <pthread.h>
static inline int host_run_with_stack(size_t bytes, void *(*fn)(void *), void *arg) {
    pthread_attr_t a;
    pthread_t t;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, bytes);
    int r = pthread_create(&t, &a, fn, arg);
    pthread_attr_destroy(&a);
    if (r != 0) return -1;
    pthread_join(t, NULL);
    return 0;
}

// Worker processes (the test262 runner forks one per CPU). Workers take the
// next item from a counter shared across fork, so a slow test holds up only
// its own worker.
#include <sys/mman.h>
#include <sys/wait.h>
static inline long *host_shared_counter(void) {
    void *p = mmap(NULL, sizeof(long), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return NULL;
    *(long *)p = 0;
    return (long *)p;
}
static inline void host_shared_counter_free(long *p) { munmap(p, sizeof(long)); }
static inline long host_counter_next(long *p) { return __atomic_fetch_add(p, 1, __ATOMIC_RELAXED); }
static inline long host_counter_load(long *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
/// fork() after flushing stdio, so the child can't repeat buffered output.
static inline int host_fork(void) { fflush(NULL); return (int)fork(); }
/// Leave a forked child without running exit handlers or flushing.
static inline void host_exit_now(int code) { _exit(code); }
/// Wait for any child: its pid (-1 when none are left), and in *code its
/// exit status, or 128 + the signal that killed it.
static inline int host_wait_any(int *code) {
    int st = 0;
    pid_t pid;
    do { pid = waitpid(-1, &st, 0); } while (pid < 0 && errno == EINTR);
    if (pid < 0) return -1;
    *code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    return (int)pid;
}
static inline int host_ncpu(void) { long n = sysconf(_SC_NPROCESSORS_ONLN); return n > 0 ? (int)n : 1; }
/// Wall-clock milliseconds (hostMillis is CPU time, which a parent waiting on
/// workers barely uses).
static inline long host_wall_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Runaway guard (hosttest/guard.c): a watchdog thread that fails the run
// on a runaway allocation or a hang. Started by the runner's main().
void host_guard_start(void);
void host_guard_label(const char *section);
void host_guard_finish(void);
long host_peak_rss_mb(void);
