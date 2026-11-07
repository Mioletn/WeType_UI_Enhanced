/*
 * Wine runtime probe (Madeira-lite M1e).
 *
 * M1a/M1b proved Wine's unix side compiles and links for iOS 12.0. This proves
 * it *runs*: wineserver is started on a background thread (server/main.c is
 * compiled with -Dmain=wineserver_main so it can be called in-process), and the
 * probe waits for it to publish its socket, then connects to it.
 *
 * A 0 return means: wineserver initialised, created its listening socket inside
 * the prefix, accepted a connection, and its thread was still in main_loop
 * after a settling delay. -1 is a setup failure, -2 means the server never
 * published a socket, -3 means the socket refused the connection, -4 means
 * the wineserver thread exited right after the connection.
 *
 * M2 adds a real Wine server request/reply round trip on that same connection
 * (SCM_RIGHTS fd handshake + REQ_init_first_thread). It is an add-on
 * diagnostic: the outcome is appended to the result line as "proto=..." and
 * never changes the A-route return code. The detail line goes to
 * Documents/husk-wine-probe.log.
 */
#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include "WineProbe.h"

/* M2 wire constants, mirrored from include/wine/server_protocol.h in the
 * willfaust/wine fork. scripts/build_ntdll_unix.sh asserts all four against
 * the fork source at build time, so a protocol bump cannot silently break
 * this probe (it fails the build instead of lying on-device). */
#define HUSK_SERVER_PROTOCOL_VERSION 930
#define HUSK_REQ_INIT_FIRST_THREAD   5
#define HUSK_GENERIC_REQUEST_SIZE   64  /* struct request_max_size = int[16] */

struct husk_request_header { int req; unsigned int request_size; unsigned int reply_size; };
struct husk_init_first_thread_request {
    struct husk_request_header h;
    int unix_pid, unix_tid, debug_level, reply_fd, wait_fd;
};
struct husk_send_fd { unsigned int tid; int fd; };
struct husk_reply_prefix { unsigned int error, reply_size, pid, tid; };

/* extern "C": the archive defines this as a C symbol (_wineserver_main), and
 * this file is Objective-C++, which would otherwise look for the mangled name.
 * The linker says so itself when it is missing. */
extern "C" int wineserver_main(int argc, char **argv);

static volatile int g_ws_returned;
static volatile int g_ws_result;
static int g_nls_bundled;
static char g_error[512];

/* In-process lifetime diagnostics. wineserver was written to own a whole
 * process: several shutdown paths call exit(). Running it on a thread inside
 * Husk makes any of those calls terminate the app. These markers go straight
 * to fd 2 (captured into husk.log) so a probe run can distinguish a
 * process-level exit() -- which runs atexit handlers -- from a signal or
 * SIGKILL, which does not. stdio buffering is unreliable during teardown. */
static void husk_lifetime_mark(const char *tag, int value)
{
    char buf[192];
    int n = snprintf(buf, sizeof(buf),
                     "[husk] %s (ws_returned=%d ws_result=%d value=%d)\n",
                     tag, g_ws_returned, g_ws_result, value);
    if (n > 0) write(2, buf, (size_t)n);
}

static void husk_atexit_diag(void)
{
    husk_lifetime_mark("atexit: process-level exit", 0);
}

static void set_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void set_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error, sizeof(g_error), fmt, ap);
    va_end(ap);
}

static double now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

/* fatal_error() in the Husk build ends the wineserver thread with
 * pthread_exit() instead of exit(1). Cleanup handlers still run on
 * pthread_exit, so this lets the probe distinguish "the server thread died
 * early" (2) from "it returned normally" (1) and "running in main_loop" (0). */
static void ws_thread_cleanup(void *unused)
{
    g_ws_returned = 2;
    husk_lifetime_mark("wineserver thread pthread_exit (early)", 0);
}

static void *wineserver_thread(void *unused)
{
    /* -f stays in the foreground (do not fork), -p persists (no idle-exit
     * timeout), -d (no argument) bumps debug_level so wineserver prints its
     * "starting" line, the on-device proof that it reached main(). */
    static char a0[] = "wineserver", a1[] = "-f", a2[] = "-p", a3[] = "-d";
    char *argv[] = { a0, a1, a2, a3, NULL };

    pthread_cleanup_push(ws_thread_cleanup, NULL);
    g_ws_result = wineserver_main(4, argv);
    pthread_cleanup_pop(0);
    g_ws_returned = 1;
    husk_lifetime_mark("wineserver thread returned normally", g_ws_result);
    return NULL;
}

static int connect_unix(const char *path, int *out_fd)
{
    *out_fd = -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return errno;

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;

    /* An iOS container path is ~150 chars, longer than sockaddr_un.sun_path
     * (104). wineserver chdir()s into its server directory and binds the
     * relative name "socket" (server/request.c), so connect the same way:
     * chdir into the socket's directory, use just the basename, then restore
     * the previous directory with fchdir. strncpy-ing the absolute path used
     * to silently truncate it and fail with ENOENT. */
    int saved = open(".", O_RDONLY);
    int relative = 0;
    const char *slash = strrchr(path, '/');
    if (slash && (size_t)(slash - path) < PATH_MAX) {
        char dir[PATH_MAX];
        size_t len = (size_t)(slash - path);
        memcpy(dir, path, len);
        dir[len] = 0;
        if (chdir(dir) == 0) {
            strncpy(sa.sun_path, slash + 1, sizeof(sa.sun_path) - 1);
            relative = 1;
        }
    }
    if (!relative) strncpy(sa.sun_path, path, sizeof(sa.sun_path) - 1);

    int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    int e = rc == 0 ? 0 : errno;
    if (relative && saved >= 0) fchdir(saved);
    if (saved >= 0) close(saved);
    if (e == 0) *out_fd = fd;   /* M2 keeps this fd for the protocol handshake */
    else close(fd);
    return e;
}

/* wineserver names its socket "socket" inside a per-prefix directory. The exact
 * layout differs between versions, so walk the prefix and the temp dir instead
 * of hard-coding a path. */
static NSString *find_socket(NSString *root, int max_depth)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
    for (NSString *rel in e) {
        NSArray *parts = [rel pathComponents];
        if ((int)parts.count > max_depth) { [e skipDescendants]; continue; }
        if (![[rel lastPathComponent] isEqualToString:@"socket"]) continue;
        NSString *full = [root stringByAppendingPathComponent:rel];
        BOOL is_dir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&is_dir] && !is_dir) return full;
    }
    return nil;
}

/* M2: exercise the real Wine server request/reply path on the connected
 * master socket. This is deliberately an ADD-ON diagnostic: a failure here is
 * reported in the result line but does not change husk_wine_probe()'s return
 * code, so the M1/A-route verdict cannot regress because of an M2 experiment.
 *
 * Handshake (server/request.c, server/thread.c, dlls/ntdll/unix/server.c):
 *   accept() -> create_process() -> create_thread(-1) which pipes a request
 *   fd to the client via SCM_RIGHTS, with SERVER_PROTOCOL_VERSION in the
 *   payload. The client then passes a reply fd and a wait fd back the same
 *   way, and writes a 64-byte union generic_request to the request fd. Only
 *   REQ_init_first_thread installs current->reply_fd; without it
 *   call_req_handler() kills the thread instead of sending a reply. */
static void husk_protocol_probe(int master, char *out, size_t outlen)
{
    int reqfd = -1;
    int reply_pipe[2] = { -1, -1 };
    int wait_pipe[2] = { -1, -1 };
    unsigned int version = 0;
    /* Objective-C++ forbids a goto from jumping past a variable with an
     * initializer. Every local used below is therefore declared up here,
     * before the first "goto done"; the handshake logic itself is unchanged. */
    unsigned char req[HUSK_GENERIC_REQUEST_SIZE] = { 0 };
    unsigned char rep[HUSK_GENERIC_REQUEST_SIZE] = { 0 };
    struct husk_init_first_thread_request *r =
        (struct husk_init_first_thread_request *)req;
    struct husk_reply_prefix *rp = (struct husk_reply_prefix *)rep;
    struct pollfd pfd;
    int pr = 0;
    ssize_t rn = 0;

    struct timeval tv = { 2, 0 };
    setsockopt(master, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    /* server -> client: 4-byte obj_handle_t payload + SCM_RIGHTS request fd */
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov;
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    iov.iov_base = &version;
    iov.iov_len = sizeof(version);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof(cbuf);
    ssize_t n = recvmsg(master, &msg, 0);
    if (n != (ssize_t)sizeof(version)) {
        snprintf(out, outlen, "proto=recvmsg-failed(%zd:%s)", n, strerror(errno));
        return;
    }
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c))
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS)
            reqfd = *(int *)CMSG_DATA(c);
    if (reqfd < 0) {
        snprintf(out, outlen, "proto=no-request-fd");
        return;
    }
    if (version != HUSK_SERVER_PROTOCOL_VERSION) {
        snprintf(out, outlen, "proto=version-mismatch(got %u want %d)",
                 version, HUSK_SERVER_PROTOCOL_VERSION);
        goto done;
    }

    if (pipe(reply_pipe) || pipe(wait_pipe)) {
        snprintf(out, outlen, "proto=pipe-failed(%s)", strerror(errno));
        goto done;
    }

    /* client -> server: 8-byte struct send_fd (tid=0 selects the process's
     * first thread) + SCM_RIGHTS. data.fd is the CLIENT fd number; the server
     * records it as the inflight key, which is what req->reply_fd refers to. */
    for (int k = 0; k < 2; k++) {
        int fd = k ? wait_pipe[1] : reply_pipe[1];
        struct husk_send_fd data;
        data.tid = 0;
        data.fd = fd;
        char cb[CMSG_SPACE(sizeof(int))];
        struct iovec v;
        struct msghdr m;
        memset(&m, 0, sizeof(m));
        v.iov_base = &data;
        v.iov_len = sizeof(data);
        m.msg_iov = &v;
        m.msg_iovlen = 1;
        m.msg_control = cb;
        m.msg_controllen = sizeof(cb);
        struct cmsghdr *c = CMSG_FIRSTHDR(&m);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        *(int *)CMSG_DATA(c) = fd;
        m.msg_controllen = c->cmsg_len;
        if (sendmsg(master, &m, 0) != (ssize_t)sizeof(data)) {
            snprintf(out, outlen, "proto=sendmsg-failed(%s)", strerror(errno));
            goto done;
        }
    }

    r->h.req = HUSK_REQ_INIT_FIRST_THREAD;
    r->h.request_size = 0;   /* no variable-sized request data */
    r->h.reply_size = 0;     /* no variable-sized reply data expected */
    /* Husk: this Wine "process" IS the host app. Reporting getpid() here made
       thread.c store our own pid on the Wine process; when the probe closed its
       only client, process_killed() -> start_sigkill_timer() -> process_sigkill()
       escalated to kill(unix_pid, SIGKILL) and killed Husk itself. On-device:
       "0020: *process killed*" was the final log line, no crash .ips and no
       atexit marker -- the exact signature of SIGKILL. -1 is Wine's own value
       for "no unix process attached": start_sigkill_timer() then calls
       process_died() directly, with no signal. This is also accurate for a
       protocol probe, which represents no real Windows process. */
    r->unix_pid = -1;
    r->unix_tid = -1;
    r->debug_level = 0;
    r->reply_fd = reply_pipe[1];
    r->wait_fd = wait_pipe[1];
    if (write(reqfd, req, sizeof(req)) != (ssize_t)sizeof(req)) {
        snprintf(out, outlen, "proto=write-failed(%s)", strerror(errno));
        goto done;
    }

    pfd.fd = reply_pipe[0];
    pfd.events = POLLIN;
    pfd.revents = 0;
    pr = poll(&pfd, 1, 3000);
    if (pr <= 0) {
        snprintf(out, outlen, "proto=reply-timeout(poll=%d:%s)", pr,
                 pr < 0 ? strerror(errno) : "no data");
        goto done;
    }
    rn = read(reply_pipe[0], rep, sizeof(rep));
    if (rn < (ssize_t)sizeof(struct husk_reply_prefix)) {
        snprintf(out, outlen, "proto=short-reply(%zd)", rn);
        goto done;
    }
    snprintf(out, outlen, "proto=ok ver=%u error=0x%08x pid=%u tid=%u",
             version, rp->error, rp->pid, rp->tid);

done:
    if (reqfd >= 0) close(reqfd);
    for (int k = 0; k < 2; k++) {
        if (reply_pipe[k] >= 0) close(reply_pipe[k]);
        if (wait_pipe[k] >= 0) close(wait_pipe[k]);
    }
}

int32_t husk_wine_probe(void)
{
    /* Register once: if any process-level exit() fires while wineserver runs
     * in-process, husk.log records it before the app disappears. */
    static int diag_once = 0;
    if (!diag_once) {
        diag_once = 1;
        atexit(husk_atexit_diag);
    }

    @autoreleasepool {
        const double t0 = now_ms();
        g_nls_bundled = 0;
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.firstObject;
        NSString *prefix = [docs stringByAppendingPathComponent:@"wineprefix"];
        NSFileManager *fm = [NSFileManager defaultManager];

        NSError *err = nil;
        [fm createDirectoryAtPath:[prefix stringByAppendingPathComponent:@".wine"]
            withIntermediateDirectories:YES attributes:nil error:&err];
        if (err) {
            set_error("mkdir prefix: %s", err.localizedDescription.UTF8String);
            return -1;
        }

        /* server/unicode.c must open l_intl.nls (the Unicode casemap table)
         * before wineserver can start. Desktop Wine looks in DATADIR/wine/nls
         * and /usr/share/wine/nls, neither of which exists in an app bundle.
         * The Husk build of unicode.c prefers WINE_NLS_DIR, so stage the
         * bundled copy inside the prefix and point it there. */
        NSString *nlsDir = [prefix stringByAppendingPathComponent:@"nls"];
        [fm createDirectoryAtPath:nlsDir withIntermediateDirectories:YES
                       attributes:nil error:nil];
        NSString *nlsDst = [nlsDir stringByAppendingPathComponent:@"l_intl.nls"];
        NSString *nlsSrc = [[NSBundle mainBundle] pathForResource:@"l_intl" ofType:@"nls"];
        if (nlsSrc) {
            if ([fm fileExistsAtPath:nlsDst]) [fm removeItemAtPath:nlsDst error:nil];
            if ([fm copyItemAtPath:nlsSrc toPath:nlsDst error:nil]) {
                setenv("WINE_NLS_DIR", nlsDir.fileSystemRepresentation, 1);
                g_nls_bundled = 1;
            }
        }

        /* wineserver reads both; WINEPREFIX decides where the socket goes and
         * TMPDIR is the fallback when it cannot use the prefix. */
        NSString *tmp = NSTemporaryDirectory();
        setenv("WINEPREFIX", prefix.fileSystemRepresentation, 1);
        /* wineserver's server/request.c now uses $WINEPREFIX/.wineserver on
         * iOS; TMPDIR is set too so any Wine code that falls back to getenv
         * lands in the app's own tmp, not the sandbox-denied /tmp. */
        if (tmp) setenv("TMPDIR", tmp.fileSystemRepresentation, 1);
        setenv("WINEDEBUG", "-all", 1);
        setenv("WINEDLLOVERRIDES", "winemenubuilder.exe,mscoree,mshtml=", 1);

        g_ws_returned = 0;
        g_ws_result = 0;

        pthread_t th;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 8 << 20);
        int perr = pthread_create(&th, &attr, wineserver_thread, NULL);
        pthread_attr_destroy(&attr);
        if (perr != 0) {
            set_error("pthread_create: %d", perr);
            return -1;
        }
        pthread_detach(th);

        NSString *found = nil;
        for (int i = 0; i < 100 && !found; i++) {
            usleep(100 * 1000);
            found = find_socket(prefix, 4);
            if (!found && tmp) found = find_socket(tmp, 3);
            if (g_ws_returned && i > 5) break;   /* it exited; no point waiting */
        }

        double waited = now_ms() - t0;
        const char *ws_state = g_ws_returned == 2 ? "thread exited early (fatal_error)"
                             : g_ws_returned == 1 ? "returned before main_loop"
                             : "running in main_loop";
        const char *nls_state = g_nls_bundled ? "nls=bundle" : "nls=system-fallback";

        if (!found) {
            set_error("no socket after %.0fms in %s (wineserver %s rc=%d, %s)",
                      waited, prefix.UTF8String, ws_state, g_ws_result, nls_state);
            return -2;
        }

        const char *sock_path = found.fileSystemRepresentation;
        int master = -1;
        int ce = connect_unix(sock_path, &master);
        if (ce != 0) {
            set_error("socket %s refused: %s (path %lu chars, wineserver %s, %s)",
                      found.lastPathComponent.UTF8String, strerror(ce),
                      (unsigned long)strlen(sock_path), ws_state, nls_state);
            return -3;
        }

        /* connect() alone only proves that something is listening. Give
         * wineserver time to finish init_registry()/main_loop() and verify the
         * server thread is still alive -- a fatal_error() after the socket is
         * published would otherwise be reported as a success. */
        usleep(1500 * 1000);
        waited = now_ms() - t0;
        if (g_ws_returned != 0) {
            close(master);
            set_error("wineserver %s after connect (rc=%d, %s)",
                      g_ws_returned == 2 ? "thread exited early" : "returned",
                      g_ws_result, nls_state);
            return -4;
        }
        if (![fm fileExistsAtPath:found]) {
            close(master);
            set_error("socket disappeared after connect (%s)", nls_state);
            return -4;
        }

        /* M2: on the very same connection, drive a real Wine server request.
         * This is an add-on diagnostic -- its outcome is appended to the
         * result line, never used to fail the already-proven A route. */
        char proto[256] = "proto=skipped";
        husk_protocol_probe(master, proto, sizeof(proto));
        close(master);
        const char *ws_after = g_ws_returned == 0 ? "alive" : "died";

        set_error("ok in %.0fms, socket %s (%lu chars), wineserver %s, %s, %s, ws_after_proto=%s",
                  waited, found.lastPathComponent.UTF8String,
                  (unsigned long)strlen(sock_path), ws_state, nls_state,
                  proto, ws_after);
        return 0;
    }
}

const char *husk_wine_last_error(void)
{
    return g_error[0] ? g_error : NULL;
}
