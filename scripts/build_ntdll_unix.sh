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

CFLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN"
    -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing
    -Wno-implicit-function-declaration -Wno-int-conversion
    -include "$BUILD/include/config.h"
    -include "$SHIMS/shims/wine_ios_exit.h"
    -I"$SHIMS/shims" -DHAVE_LINUX_NTSYNC_H=1
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

for e in "$OUT"/*.err; do
    if [ -s "$e" ]; then
        echo ""
        echo "### $(basename "$e")"
        grep -m 3 -E "error:|fatal error:" "$e" || head -3 "$e"
    fi
done
exit 0
