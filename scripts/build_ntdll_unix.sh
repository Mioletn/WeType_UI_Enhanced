#!/bin/bash
# Build Wine's ntdll unix side for iOS 12.2 into libntdll_unix.a.
#
# This is the M1 port: Madeira's iOS shims (wine-ios/ntdll/*.c) compiled at
# -miphoneos-version-min=12.0 against Wine's own dlls/ntdll/unix sources. The
# shims were written for iOS 17 but use nothing newer than mach_vm (iOS 3) and
# os_unfair_lock (iOS 10); the one __builtin_available in thread_ios.c is a
# macOS check, which is vacuously true on iOS.
#
# Deliberately out of scope here: the crypto/network/gstreamer unixlibs
# (gnutls, bcrypt, secur32, crypt32, ws2_32, dwrite, dnsapi, winegstreamer) and
# madsync. Those need GnuTLS/FFmpeg/iOS freetype prefixes and can be added after
# the core boots; leaving them out keeps the first gate to the 6 shims plus the
# 18 stock ntdll/unix translation units.
#
# Like m1_wine_probe.sh this always exits 0 and reports: the point is the table.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/logs/m1"
OBJ="$ROOT/build/m1-obj"
LIBDIR="$ROOT/build/ios-arm64/lib"
SHIMS="$ROOT/wine-ios/ntdll"
mkdir -p "$OUT" "$OBJ" "$LIBDIR"

WINE_SHA="9129e9684daaeae70da9435e7c6060e59392634e"
SRC="$ROOT/build/wine/src"
BUILD="$SRC/build-macos"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN="12.0"

if [ ! -f "$SRC/configure" ]; then
    echo "==> cloning willfaust/wine at $WINE_SHA"
    rm -rf "$SRC"
    git clone --filter=blob:none https://github.com/willfaust/wine.git "$SRC" || exit 1
    git -C "$SRC" checkout "$WINE_SHA" || exit 1
fi
if [ ! -f "$BUILD/include/config.h" ]; then
    echo "==> configuring Wine for macOS (generated headers only)"

    # bison 3+ (macOS ships 2.3) and a PE cross-compiler, because configure
    # refuses to run without one when a PE arch is requested. We only need the
    # unix side, but Wine's configure will not produce config.h otherwise, so a
    # throwaway i386 PE toolchain is the cheapest way past it.
    NEED=""
    bison --version 2>/dev/null | head -1 | grep -qE ' (3|4|5)\.' || NEED="$NEED bison"
    command -v i686-w64-mingw32-gcc >/dev/null 2>&1 || NEED="$NEED mingw-w64"
    if [ -n "$NEED" ]; then
        echo "    installing:$NEED"
        brew install $NEED >/dev/null 2>&1 || true
    fi
    for p in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin; do
        [ -x "$p/bison" ] && PATH="$p:$PATH"
    done
    export PATH
    echo "    bison: $(bison --version 2>/dev/null | head -1)"
    echo "    pe cc: $(command -v i686-w64-mingw32-gcc || echo none)"

    COMMON="--without-x --disable-tests --without-freetype --without-gnutls
            --without-vulkan --without-sdl --without-alsa --without-pulse
            --without-cups --without-dbus --without-odbc --without-opencl
            --without-opengl --without-osmesa --without-krb5 --without-netapi
            --without-pcap --without-usb --without-wayland"

    # First arch spec that yields include/config.h wins. aarch64 needs
    # llvm-mingw, which is not on the runner; i386 only needs brew's mingw-w64,
    # and the PE side is never built here anyway.
    for ARCHS in "--enable-archs=i386" "--enable-archs=x86_64" "--enable-archs=i386,x86_64" ""; do
        echo "    trying ${ARCHS:-<no arch flag>}"
        rm -rf "$BUILD"
        mkdir -p "$BUILD"
        ( cd "$BUILD" && ../configure $ARCHS $COMMON ) > "$OUT/wine-configure.log" 2>&1
        if [ -f "$BUILD/include/config.h" ]; then
            echo "    configure ok with ${ARCHS:-<no arch flag>}"
            break
        fi
        grep -m2 -E "configure: error|error:" "$OUT/wine-configure.log" || tail -3 "$OUT/wine-configure.log"
    done
fi

if [ ! -f "$BUILD/include/config.h" ]; then
    echo "configure produced no include/config.h -- see logs/m1/wine-configure.log" \
        | tee -a "$OUT/ntdll-summary.txt"
    tail -5 "$OUT/wine-configure.log" 2>/dev/null
    exit 0
fi

# M2: WineProbe.mm mirrors a few wire constants from server_protocol.h. Verify
# them against the checked-out fork so a protocol bump fails the build instead
# of silently producing a probe that lies on-device.
PROTO="$SRC/include/wine/server_protocol.h"
if [ -f "$PROTO" ] && command -v python3 >/dev/null 2>&1; then
    if ! python3 - "$PROTO" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
ver = int(re.search(r"#define SERVER_PROTOCOL_VERSION\s+(\d+)", t).group(1))
enum = t[t.index("enum request"):]
enum = enum[:enum.index("};")]
names = re.findall(r"^\s*(REQ_\w+)", enum, re.M)
idx = names.index("REQ_init_first_thread")
pad = int(re.search(r"struct request_max_size\s*\{\s*int\s+pad\[(\d+)\]", t, re.S).group(1))
print("==> M2 protocol: version=%d REQ_init_first_thread=%d generic_request=%d"
      % (ver, idx, pad * 4))
assert ver == 930 and idx == 5 and pad * 4 == 64, \
    "WineProbe.mm M2 constants drifted from server_protocol.h"
PY
    then
        echo "M2 protocol constants drifted -- update WineProbe.mm before building" \
            | tee -a "$OUT/ntdll-summary.txt"
        exit 1
    fi
fi

CFLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN"
    -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing
    -Wno-implicit-function-declaration -Wno-int-conversion
    -include "$BUILD/include/config.h"
    -include "$SHIMS/shims/wine_ios_exit.h"
    # No -DHAVE_LINUX_NTSYNC_H: that switches sync.c onto <linux/ntsync.h>,
    # which only exists in Madeira's madsync project. Without it sync.c uses
    # the futex/esync paths, which is what we want until ntsync is built.
    -I"$SHIMS/shims" -I"$SHIMS"
    -I"$BUILD/dlls/ntdll" -I"$SRC/dlls/ntdll" -I"$SRC/dlls/ntdll/unix"
    -I"$BUILD/include" -I"$SRC/include"
    -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_
    -D_ACRTIMP= -DWINBASEAPI=
    -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\"
    -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\"
    -DWINE_UNIX_LIB -DWINE_IOS=1
    -Dget_thread_context=ntdll_get_thread_context
    -Dset_thread_context=ntdll_set_thread_context
)

OK=0
BAD=0
FAILED=""
: > "$OUT/ntdll-summary.txt"

compile() {
    local src="$1" name="$2"; shift 2
    if xcrun --sdk iphoneos clang "${CFLAGS[@]}" "$@" -c "$src" -o "$OBJ/$name.o" \
            2> "$OUT/$name.err"; then
        OK=$((OK + 1)); echo "OK   $name" >> "$OUT/ntdll-summary.txt"
    else
        BAD=$((BAD + 1)); echo "FAIL $name" >> "$OUT/ntdll-summary.txt"; FAILED="$FAILED $name"
    fi
}

# The eight TUs Madeira replaces on iOS. Written as a case, not an associative
# array: /bin/bash on macOS is 3.2 and has no `declare -A`, which silently
# killed this script after it had created an empty summary.
replacement_for() {
    case "$1" in
        loader)       echo loader_ios.c ;;
        process)      echo process_ios.c ;;
        server)       echo server_ios.c ;;
        env)          echo env_ios.c ;;
        cdrom)        echo cdrom_stub.c ;;
        virtual)      echo virtual_ios.c ;;
        signal_arm64) echo signal_arm64_ios.c ;;
        thread)       echo thread_ios.c ;;
        *)            echo "" ;;
    esac
}

echo "==> compiling ntdll unix for iOS $MIN"
for src in "$SRC"/dlls/ntdll/unix/*.c; do
    name="$(basename "$src" .c)"
    repl="$(replacement_for "$name")"
    if [ -n "$repl" ] && [ -f "$SHIMS/$repl" ]; then
        compile "$SHIMS/$repl" "$name"
    elif grep -q 'build/madeira_cfg\.h' "$src" 2>/dev/null; then
        # sync.c and system.c reach for Madeira's config header through a
        # relative path that only exists in their tree. Rewrite that one
        # include to the copy in wine-ios/ntdll and compile the result from
        # the object dir (the include search path covers the rest).
        sed -e 's|"[^"]*build/madeira_cfg\.h"|"madeira_cfg.h"|' \
            -e 's/__builtin_available( macOS 14\.4, \* )/__builtin_available( macOS 14.4, iOS 17.4, * )/' \
            "$src" > "$OBJ/$name.patched.c"
        compile "$OBJ/$name.patched.c" "$name"
    else
        compile "$src" "$name"
    fi
done

echo "== $OK compiled, $BAD failed ==" | tee -a "$OUT/ntdll-summary.txt"
[ -n "$FAILED" ] && echo "failed:$FAILED" | tee -a "$OUT/ntdll-summary.txt"

if ls "$OBJ"/*.o >/dev/null 2>&1; then
    ar rcs "$LIBDIR/libntdll_unix.a" "$OBJ"/*.o
    echo "    libntdll_unix.a $(wc -c < "$LIBDIR/libntdll_unix.a" | tr -d ' ') bytes"
fi

# --- M1b probe: wineserver ---------------------------------------------------
# Madeira patches an existing libwineserver.a, which assumes a full Wine build.
# The question this answers is whether that indirection is actually needed: if
# server/*.c compiles straight against a generated request.h, wineserver is just
# another compile step and the prebuilt archive can be skipped entirely.
if [ -f "$BUILD/include/config.h" ]; then
    echo ""
    echo "==> availability warnings (APIs newer than iOS $MIN)"
    # These compile but would be missing symbols at run time on 12.2 -- the same
    # class of failure as std::pmr. This list is the runtime backfill work.
    grep -h "only available on iOS" "$OUT"/*.err 2>/dev/null \
        | sed "s/.*warning: '//; s/' is only available.*//" \
        | sort | uniq -c | sort -rn | head -20

    echo ""
    # request.h, request_handlers.h and request_trace.h are generated files that
    # this fork commits, so there is nothing to run: server/*.c compiles straight
    # against $SRC/server. (tools/make_requests only writes server_protocol.h,
    # request_trace.h and request_handlers.h -- not request.h.)
    if [ -s "$SRC/server/request.h" ]; then
        echo "==> wineserver: request.h present ($(wc -c < "$SRC/server/request.h" | tr -d ' ') bytes)"
        WS_OK=0
        WS_BAD=0
        : > "$OUT/wineserver-summary.txt"
        for src in "$SRC"/server/*.c; do
            n="$(basename "$src" .c)"
            WS_SRC="$src"
            # server/main.c defines main(); rename it so the app can start
            # wineserver on its own thread instead of a process.
            EXTRA=""
            if [ "$n" = main ]; then
                EXTRA="-Dmain=wineserver_main"
            elif [ "$n" = request ]; then
                # server/request.c puts the server directory in /tmp/.wine-<uid>
                # unless __ANDROID__ is defined. On iOS the sandbox denies mkdir
                # there (EPERM), and wineserver's fatal_error() calls exit(),
                # which kills the whole app -- observed on-device as
                # "wineserver: mkdir /tmp/.wine-501: Operation not permitted".
                # Wine's other branch puts it in $WINEPREFIX/.wineserver, inside
                # the app's Documents, which is writable. Force just that one
                # #ifdef for this TU: defining __ANDROID__ (or WINE_IOS) for all
                # server/*.c changes other TUs and pulls Madeira-private symbols.
                #
                # fatal_error() also lives in this TU, and its exit(1) takes the
                # entire app down when anything inside wineserver goes wrong.
                # Husk starts wineserver on a thread, so end only that thread:
                # the app stays alive and the Wine probe can write its log.
                #
                # Two other process-level exits live in this TU:
                #   - close_socket_timeout() ends with exit(0) when the master
                #     socket idle timeout fires. In a standalone wineserver that
                #     is a clean quit; in-process it terminates Husk itself.
                #   - acquire_lock() uses exit(2) when another server owns the
                #     lock (also an exit, not a thread return).
                # Both become pthread_exit(NULL) so only the server thread ends.
                # The .tmp extension keeps it out of the *.c loop above.
                sed -e 's|^#ifdef __ANDROID__.*$|#if 1  /* Husk: iOS has no writable /tmp */|' \
                    -e '/void fatal_error/,/^}/ s|^    exit(1);$|    pthread_exit(NULL);  /* Husk: do not kill the app */|' \
                    -e '/static void close_socket_timeout/,/^}/ s|^    exit( 0 );$|    pthread_exit(NULL);  /* Husk: end server thread, not the app */|' \
                    -e 's|exit(2); /\* we didn.t get the lock, exit with special status \*/|pthread_exit(NULL);  /* Husk: do not kill the app */|' \
                    "$src" > "$SRC/server/husk_request.tmp"
                WS_SRC="$SRC/server/husk_request.tmp"
                EXTRA="-x c -include pthread.h"
            elif [ "$n" = mach ]; then
                # Wine's macOS tracing branch registers the wineserver with
                # launchd through bootstrap_register2(). An iOS app has no
                # launchd access, so on-device this fails with
                #   wineserver: Can't check in server_mach_port
                # and fatal_error() kills the app. Madeira's WINE_IOS mach.c
                # skips the check-in entirely; do the same here, but keep the
                # allocated port (init_process_tracing() receives on it with a
                # zero timeout). Defining WINE_IOS globally is not an option:
                # it pulls the Madeira-private ios_* symbols back into the link.
                sed -e 's|if (bootstrap_register2( bp, server_dir, server_mach_port, 0 ) != KERN_SUCCESS)|if (0)  /* Husk: no launchd on iOS */|' \
                    -e 's|    assert(0);  /\* should never be called on MacOS \*/|    return;  /* Husk: iOS wineserver has no children */|' \
                    "$src" > "$SRC/server/husk_mach.tmp"
                WS_SRC="$SRC/server/husk_mach.tmp"
                EXTRA="-x c"
            elif [ "$n" = unicode ]; then
                # load_intl_file() searches DATADIR/wine/nls and /usr/share/wine/nls
                # for l_intl.nls. None of those desktop paths exist in an app
                # bundle, and a miss is fatal_error("failed to load l_intl.nls").
                # On __APPLE__ get_nls_dir() derives the path from the main
                # executable, so even argv[0] cannot steer it. Prefer an
                # explicit WINE_NLS_DIR (set by WineProbe.mm to the copy of
                # l_intl.nls bundled with the app) before falling back.
                # stdlib.h is needed for getenv(): unicode.c does not include
                # it, and an implicit declaration would truncate the pointer.
                sed 's|    nls_dirs\[0\] = get_nls_dir();|    nls_dirs[0] = getenv("WINE_NLS_DIR"); if (!nls_dirs[0]) nls_dirs[0] = get_nls_dir();|' \
                    "$src" > "$SRC/server/husk_unicode.tmp"
                WS_SRC="$SRC/server/husk_unicode.tmp"
                EXTRA="-x c -include stdlib.h"
            fi
            if xcrun --sdk iphoneos clang \
                -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN" \
                -O1 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
                -Wno-implicit-function-declaration -Wno-int-conversion \
                -include "$BUILD/include/config.h" \
                -include "$ROOT/wine-ios/wineserver/config_ios.h" \
                -include stdarg.h \
                -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\" \
                -I"$BUILD/include" -I"$SRC/include" -I"$SRC/include/wine" \
                -I"$BUILD" -I"$SRC/server" -I"$SHIMS/shims" -I"$SHIMS" \
                -D__WINESRC__ \
                $EXTRA \
                -c "$WS_SRC" -o "$OBJ/ws-$n.o" 2> "$OUT/ws-$n.err"; then
                WS_OK=$((WS_OK + 1)); echo "OK   $n" >> "$OUT/wineserver-summary.txt"
            else
                WS_BAD=$((WS_BAD + 1)); echo "FAIL $n" >> "$OUT/wineserver-summary.txt"
            fi
        done
        echo "    wineserver: $WS_OK ok, $WS_BAD failed"
        cat "$OUT/wineserver-summary.txt" | grep -c '^OK' > /dev/null || true
        grep '^FAIL' "$OUT/wineserver-summary.txt" || echo "    (no failures)"
        if ls "$OBJ"/ws-*.o >/dev/null 2>&1; then
            ar rcs "$LIBDIR/libwineserver_unix.a" "$OBJ"/ws-*.o
            echo "    libwineserver_unix.a $(wc -c < "$LIBDIR/libwineserver_unix.a" | tr -d ' ') bytes"
        fi
        for e in "$OUT"/ws-*.err; do
            [ -s "$e" ] && { echo "### $(basename "$e")"; grep -m3 "error:" "$e"; }
        done
    fi
fi

# --- link probe --------------------------------------------------------------
# Compiling proves the sources are portable; linking proves the two archives
# agree with each other and with iOS. Undefined symbols here are the real
# remaining work, listed by name instead of as a crash on the device.
if [ -f "$LIBDIR/libntdll_unix.a" ] && [ -f "$LIBDIR/libwineserver_unix.a" ]; then
    echo ""
    echo "==> link probe (ntdll_unix + wineserver_unix)"
    # Call wineserver_main for real: the object chain pulled in then matches the
    # app's exactly. Without this the probe pulls nothing, and with -all_load it
    # pulls ntdll's virtual.o too, which needs the optional unixlib tables the
    # app never references -- noise that hides the real gap.
    printf 'int wineserver_main(int, char **);\nint husk_link_probe(void){ static char a[] = "wineserver"; char *v[2]; v[0] = a; v[1] = 0; return wineserver_main( 1, v ); }\n' \
        > "$OBJ/linkprobe.c"
    if xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
            -miphoneos-version-min="$MIN" -c "$OBJ/linkprobe.c" -o "$OBJ/linkprobe.o" \
            2> "$OUT/linkprobe.err" && \
       xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
            -miphoneos-version-min="$MIN" -dynamiclib -Wl,-undefined,error \
            -o "$OUT/libhusk-wine-probe.dylib" "$OBJ/linkprobe.o" \
            "$LIBDIR/libntdll_unix.a" "$LIBDIR/libwineserver_unix.a" \
            -framework CoreFoundation -framework Security -framework IOKit \
            2> "$OUT/link.log"; then
        echo "    link OK"
    else
        echo "    link FAILED -- undefined symbols:"
        grep -o '"_[A-Za-z0-9_]*", referenced from' "$OUT/link.log" 2>/dev/null \
            | sed 's/", referenced from//; s/"//' | sort -u | head -25
        grep -c 'referenced from' "$OUT/link.log" 2>/dev/null | sed 's/^/    total refs: /'
        tail -3 "$OUT/link.log"
    fi
fi

for e in "$OUT"/*.err; do
    if [ -s "$e" ]; then
        echo ""
        echo "### $(basename "$e")"
        grep -m 3 -E "error:|fatal error:" "$e" || head -3 "$e"
    fi
done
exit 0
