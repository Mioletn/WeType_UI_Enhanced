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
 * The detail line goes to Documents/husk-wine-probe.log.
 */
#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
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

/* extern "C": the archive defines this as a C symbol (_wineserver_main), and
 * this file is Objective-C++, which would otherwise look for the mangled name.
 * The linker says so itself when it is missing. */
extern "C" int wineserver_main(int argc, char **argv);

static volatile int g_ws_returned;
static volatile int g_ws_result;
static int g_nls_bundled;
static char g_error[512];

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
    return NULL;
}

static int connect_unix(const char *path)
{
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
    close(fd);
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

int32_t husk_wine_probe(void)
{
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
        int ce = connect_unix(sock_path);
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
            set_error("wineserver %s after connect (rc=%d, %s)",
                      g_ws_returned == 2 ? "thread exited early" : "returned",
                      g_ws_result, nls_state);
            return -4;
        }
        if (![fm fileExistsAtPath:found]) {
            set_error("socket disappeared after connect (%s)", nls_state);
            return -4;
        }

        set_error("ok in %.0fms, socket %s (%lu chars), wineserver %s, %s",
                  waited, found.lastPathComponent.UTF8String,
                  (unsigned long)strlen(sock_path), ws_state, nls_state);
        return 0;
    }
}

const char *husk_wine_last_error(void)
{
    return g_error[0] ? g_error : NULL;
}
