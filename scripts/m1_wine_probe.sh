#!/bin/bash
# M1 gate: can Wine's unix side compile for iOS 12.2 at all?
#
# This is a measurement, not a build. It configures Wine once for macOS (only
# to get the generated config.h and headers every unix TU needs) and then
# compiles every dlls/ntdll/unix/*.c at -miphoneos-version-min=12.0, recording
# each failure. It always exits 0: the report is the product.
#
# Deliberately NOT included here: Madeira's shims (wine_ios_exit.h, the patched
# loader/process/server/env/cdrom/virtual, madsync, the GnuTLS static symtab).
# Those are the delta between "Wine compiles" and "Wine runs"; measuring the
# raw surface first says how much of it is iOS 12 itself versus the port.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# build/logs is what build-ipa's artifact step uploads, so the report rides along
# with the IPA instead of needing a macOS runner of its own (dispatch and rerun
# both need actions:write, which this token does not have).
OUT="$ROOT/build/logs/m1"
mkdir -p "$OUT"
WINE_SHA="9129e9684daaeae70da9435e7c6060e59392634e"
SRC="$ROOT/build/wine/src"

if [ ! -f "$SRC/configure" ]; then
    echo "==> cloning willfaust/wine at $WINE_SHA"
    rm -rf "$SRC"
    git clone --filter=blob:none https://github.com/willfaust/wine.git "$SRC" || exit 1
    git -C "$SRC" checkout "$WINE_SHA" || exit 1
fi

B="$SRC/build-macos"
if [ ! -f "$B/config.status" ]; then
    echo "==> configuring Wine for macOS (headers only)"
    mkdir -p "$B"
    ( cd "$B" && ../configure \
        --without-x --disable-tests --enable-archs=aarch64 \
        --without-freetype --without-gnutls --without-vulkan --without-sdl \
        --without-alsa --without-pulse --without-cups --without-dbus \
        --without-odbc --without-opencl --without-opengl --without-osmesa \
        --without-krb5 --without-netapi --without-pcap --without-usb \
        --without-wayland ) > "$OUT/configure.log" 2>&1
    echo "    configure exit=$?"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN="12.0"
OK=0
BAD=0
: > "$OUT/summary.txt"

for f in "$SRC"/dlls/ntdll/unix/*.c; do
    n="$(basename "$f" .c)"
    xcrun --sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN" \
        -O1 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$B/include/config.h" \
        -I"$B/include" -I"$SRC/include" \
        -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -c "$f" -o "$OUT/$n.o" 2> "$OUT/$n.err"
    if [ $? -eq 0 ]; then
        OK=$((OK + 1)); echo "OK   $n" >> "$OUT/summary.txt"
    else
        BAD=$((BAD + 1)); echo "FAIL $n" >> "$OUT/summary.txt"
    fi
done

echo "== $OK compiled, $BAD failed ==" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"

# The first few error lines per failing TU, grouped so the report is readable.
for e in "$OUT"/*.err; do
    if [ -s "$e" ]; then
        echo ""
        echo "### $(basename "$e")"
        grep -m 4 -E "error:|fatal error:|unavailable" "$e" || head -4 "$e"
    fi
done

exit 0
