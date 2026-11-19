// Host test runner only (hosttest.sh): the bits of libc the runner uses to
// read fixtures and report. Libraries in lib/ never see this header; they
// must build freestanding (hosttest.sh checks with x86_64-unknown-none-elf).
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

// Runaway guard (hosttest/guard.c): a watchdog thread that fails the run
// on a runaway allocation or a hang. Started by the runner's main().
void host_guard_start(void);
void host_guard_label(const char *section);
void host_guard_finish(void);
long host_peak_rss_mb(void);
