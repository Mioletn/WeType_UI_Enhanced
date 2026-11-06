#!/bin/bash
# Build FEXCore (x86/x86-64 -> ARM64 userspace JIT) as an iOS arm64 static
# library, for the Madeira-lite path (see src/app/Husk/FEXBridge.mm).
#
# This is M0 of that path and nothing more: the decisive question is whether
# FEXCore compiles for, and executes code on, iOS 12.2. Nothing here involves
# Wine, DXMT or Metal -- those are later milestones and the expensive part.
#
# Source: willfaust/FEX at the commit Madeira pins in its submodule. FEX's iOS
# build (build/fex-ios/build.sh in Madeira) does NOT define FEX_IOS_HOST: that
# macro gates the Windows/ARM64EC module (xtajit64.dll) path, which needs
# llvm-mingw and is exactly what this route avoids. The plain __APPLE__ path
# only wants a dual-mapped RW/RX region, which Husk's husk-ios-jit.c already
# provides.
#
# Output: build/ios-arm64/lib/libFEXCore_all.a -- every FEX static archive
# merged into one, so the app links -lFEXCore_all instead of tracking the
# External/ archive names by hand.
#
# Adapted from Madeira's build/fex-ios/build.sh (GPL-3.0-or-later + Madeira
# Converter Exception). Only the deployment target differs: 12.0 instead of
# 17.0, because that is the device this runs on.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEX_SHA="f59cab95659e8add0c88f0c76ec1cf483c536dbf"
SRC="$HUSK_ROOT/build/fex/src"
BUILD="$SRC/build-ios"
LIBDIR="$HUSK_ROOT/build/ios-arm64/lib"
OUT="$LIBDIR/libFEXCore_all.a"

mkdir -p "$LIBDIR"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "==> fetching FEX $FEX_SHA (with the submodules FEXCore needs)"
    # A codeload tarball is NOT enough: External/{fmt,vixl,xxhash,unordered_dense,
    # zydis,range-v3,rpmalloc} are git submodules and come out empty, and the
    # build then fails at configure with missing headers. Clone and initialise
    # just the ones the library needs (the test binaries, Catch2, tracy,
    # jemalloc, Vulkan-Headers and drm-headers are not built here).
    rm -rf "$SRC"
    git clone --filter=blob:none https://github.com/willfaust/FEX.git "$SRC"
    git -C "$SRC" checkout "$FEX_SHA"
    git -C "$SRC" submodule update --init --depth 1 \
        External/fmt \
        External/vixl \
        External/xxhash \
        External/unordered_dense \
        External/zydis \
        External/range-v3 \
        External/rpmalloc
fi

if [ ! -f "$BUILD/CMakeCache.txt" ]; then
    echo "==> configuring FEXCore for iOS arm64, deployment target 12.0"
    cmake -S "$SRC" -B "$BUILD" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_SYSTEM_PROCESSOR=arm64 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DBUILD_THUNKS=OFF \
        -DBUILD_FEXCONFIG=OFF \
        -DBUILD_FEX_LINUX_TESTS=OFF \
        -DENABLE_FEX_ALLOCATOR=OFF \
        -DENABLE_ASSERTIONS=OFF
fi

echo "==> building FEXCore FEXCore_Base"
cmake --build "$BUILD" --target FEXCore FEXCore_Base

echo "==> merging archives into $OUT"
rm -f "$OUT"
# Every .a the build produced, in a deterministic order. libtool keeps the
# first definition of a duplicate symbol, so the core archives go first.
LIST="$HUSK_ROOT/build/fex/archives.txt"
: > "$LIST"
for a in "$BUILD/FEXCore/Source/libFEXCore.a" "$BUILD/FEXCore/Source/libFEXCore_Base.a"; do
    [ -f "$a" ] && echo "$a" >> "$LIST"
done
find "$BUILD" -name '*.a' \
    ! -name 'libFEXCore.a' ! -name 'libFEXCore_Base.a' \
    | sort >> "$LIST"
echo "    $(wc -l < "$LIST") archives"
libtool -static -o "$OUT" $(cat "$LIST")

ls -lh "$OUT"
echo "==> FEXCore iOS build done"
