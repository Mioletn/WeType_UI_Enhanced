/*
 * Wine runtime probe (Madeira-lite M1e).
 *
 * M1a/M1b proved Wine's unix side compiles and links for iOS 12.0. This proves
 * it *runs*: wineserver is started on a background thread (server/main.c is
 * compiled with -Dmain=wineserver_main so it can be called in-process), and the
 * probe waits for it to publish its socket, then connects to it.
 *
 * A 0 return means: wineserver initialised, created its listening socket inside
 * the prefix, and accepted a connection. -1 is a setup failure, -2 means the
 * server never published a socket, -3 means the socket existed but refused the
 * connection. The detail line goes to Documents/husk-wine-probe.log.
 */
#import <Foundation/Foundation.h>

#include <errno.h>
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

static void *wineserver_thread(void *unused)
{
    /* -f stays in the foreground (do not fork), -p persists, -d suppresses the
     * debug output that would otherwise sit on a socket. */
    static char a0[] = "wineserver", a1[] = "-f", a2[] = "-p", a3[] = "-d";
    char *argv[] = { a0, a1, a2, a3, NULL };

    g_ws_result = wineserver_main(4, argv);
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
    strncpy(sa.sun_path, path, sizeof(sa.sun_path) - 1);

    int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    int e = rc == 0 ? 0 : errno;
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

        /* wineserver reads both; WINEPREFIX decides where the socket goes and
         * TMPDIR is the fallback when it cannot use the prefix. */
        setenv("WINEPREFIX", prefix.fileSystemRepresentation, 1);
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
        NSString *tmp = NSTemporaryDirectory();
        for (int i = 0; i < 60 && !found; i++) {
            usleep(100 * 1000);
            found = find_socket(prefix, 4);
            if (!found && tmp) found = find_socket(tmp, 3);
            if (g_ws_returned && i > 5) break;   /* it exited; no point waiting */
        }

        double waited = now_ms() - t0;

        if (!found) {
            set_error("no socket after %.0fms (wineserver returned=%d rc=%d)",
                      waited, g_ws_returned, g_ws_result);
            return -2;
        }

        int ce = connect_unix(found.fileSystemRepresentation);
        if (ce != 0) {
            set_error("socket %s refused: %s", found.lastPathComponent.UTF8String, strerror(ce));
            return -3;
        }

        set_error("ok in %.0fms, socket %s, wineserver returned=%d",
                  waited, found.lastPathComponent.UTF8String, g_ws_returned);
        return 0;
    }
}

const char *husk_wine_last_error(void)
{
    return g_error[0] ? g_error : NULL;
}
