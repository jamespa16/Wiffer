// Runaway guard for the host test runner (ROADMAP 8I). A watchdog thread
// polls the process's peak resident size and wall time; past the limits the
// run is killed and reported as a failure with the current section's name.
// Embedded Swift's allocator comes prebuilt from
// libswiftEmbeddedPlatformPOSIX.a (its _swift_allocate can't be wrapped),
// and RLIMIT_AS isn't enforced on macOS, so the guard watches the resident
// set instead: a runaway allocation that is touched shows up within a few
// milliseconds. Limits (env): WIFFER_HOSTTEST_MAX_MB (default 1024),
// WIFFER_HOSTTEST_MAX_SECS (default 240).
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>

static volatile int guard_stop;
static char guard_where[128];
static long guard_max_mb = 1024, guard_max_secs = 240;

long host_peak_rss_mb(void) {
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
#ifdef __APPLE__
    return (long)(u.ru_maxrss >> 20);
#else
    return (long)(u.ru_maxrss >> 10);
#endif
}

void host_guard_label(const char *s) {
    strncpy(guard_where, s, sizeof guard_where - 1);
}

static void *guard_main(void *arg) {
    (void)arg;
    time_t start = time(NULL);
    while (!guard_stop) {
        usleep(5000);
        long mb = host_peak_rss_mb();
        if (mb > guard_max_mb) {
            printf("FAIL hosttest: runaway allocation: peak %ld MiB over the %ld MiB limit (section \"%s\")\n",
                   mb, guard_max_mb, guard_where);
            fflush(stdout);
            _exit(70);
        }
        if (time(NULL) - start > guard_max_secs) {
            printf("FAIL hosttest: still running after %ld s (section \"%s\")\n", guard_max_secs, guard_where);
            fflush(stdout);
            _exit(71);
        }
    }
    return NULL;
}

void host_guard_start(void) {
    const char *a = getenv("WIFFER_HOSTTEST_MAX_MB"), *b = getenv("WIFFER_HOSTTEST_MAX_SECS");
    if (a && atol(a) > 0) guard_max_mb = atol(a);
    if (b && atol(b) > 0) guard_max_secs = atol(b);
    pthread_t th;
    if (pthread_create(&th, NULL, guard_main, NULL) == 0) pthread_detach(th);
}

void host_guard_finish(void) { guard_stop = 1; }
