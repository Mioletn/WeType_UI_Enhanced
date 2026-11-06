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
if [ ! -f "$BUILD/config.status" ]; then
    echo "==> configuring Wine for macOS (generated headers only)"
    mkdir -p "$BUILD"
    ( cd "$BUILD" && ../configure \
        --without-x --disable-tests --enable-archs=aarch64 \
        --without-freetype --without-gnutls --without-vulkan --without-sdl \
        --without-alsa --without-pulse --without-cups --without-dbus \
        --without-odbc --without-opencl --without-opengl --without-osmesa \
        --without-krb5 --without-netapi --without-pcap --without-usb \
        --without-wayland ) > "$OUT/wine-configure.log" 2>&1
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

# The six TUs Madeira replaces on iOS, plus the two signal/thread ones.
declare -A REPLACED=(
    [loader]="loader_ios.c" [process]="process_ios.c" [server]="server_ios.c"
    [env]="env_ios.c" [cdrom]="cdrom_stub.c" [virtual]="virtual_ios.c"
    [signal_arm64]="signal_arm64_ios.c" [thread]="thread_ios.c"
)

echo "==> compiling ntdll unix for iOS $MIN"
for src in "$SRC"/dlls/ntdll/unix/*.c; do
    name="$(basename "$src" .c)"
    if [ -n "${REPLACED[$name]:-}" ]; then
        compile "$SHIMS/${REPLACED[$name]}" "$name"
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
