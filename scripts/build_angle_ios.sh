#!/bin/bash
# Build ANGLE (EGL + GLES over Metal) for iOS arm64.
#
# This is the host-side GPU stack Husk needs. virglrenderer turns the guest's
# GL calls into real draw calls, but it needs an EGL/GLES implementation to make
# them against -- and iOS has no EGL at all. ANGLE supplies one on top of Metal.
# UTM does the same thing, which is what makes GPU acceleration inside a QEMU
# guest on iOS a solved problem rather than a hope.
#
# ANGLE is taken from WebKit rather than upstream because WebKit carries an
# Xcode project for it, which avoids needing depot_tools and gn. A blob-filtered
# sparse checkout keeps that to ~260 MB instead of cloning all of WebKit.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPU="$HUSK_ROOT/third_party/gpu"
WK="$GPU/webkit"
PREFIX="$HUSK_ROOT/build/ios-arm64/sysroot"
LOG="$HUSK_ROOT/build/logs/angle-build.log"
mkdir -p "$GPU" "$(dirname "$LOG")"

if [ ! -d "$WK" ]; then
    echo "==> sparse-cloning WebKit for its ANGLE tree"
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/WebKit/WebKit.git "$WK"
fi

# Configurations and Tools/ccache are not optional: the ANGLE xcconfigs include
# ../../../../Tools/ccache/ccache.xcconfig, and the build fails to even start
# without it.
( cd "$WK" && git sparse-checkout set \
    Source/ThirdParty/ANGLE Configurations Tools/Scripts Tools/ccache )

cd "$WK/Source/ThirdParty/ANGLE"

# Xcode 16.4's clang (the toolchain the iOS 12.2 backport must use -- see
# .github/workflows/build-ipa.yml) rejects ANGLE's thread-safety capability
# annotations: std::mutex cannot carry the 'capability' attribute, so every
# ANGLE_ACQUIRE_CAPABILITY(mutex) / ANGLE_RELEASE_CAPABILITY(mutex) use --
# SimpleMutex.h's MutexOnStd::lock/unlock -- fails under ANGLE's -Werror with
# "'acquire_capability' attribute requires arguments whose type is annotated
# with 'capability' attribute; type here is 'std::mutex'". The annotations are
# static analysis only: emptying the macros compiles identical code, which is
# the direction upstream ANGLE moved in anyway. WebKit HEAD is cloned fresh on
# every build, so patch by content rather than line number and stay idempotent;
# the -Wno-thread-safety* flags in angle_build() are the second layer in case
# another annotation use surfaces first. (sed writes to a temp file and mv,
# rather than -i, so the same line works under both BSD and GNU sed.)
if grep -q '^#if defined(__clang__) && __has_attribute(acquire_capability)$' \
        src/common/angleutils.h; then
    sed 's|^#if defined(__clang__) && __has_attribute(acquire_capability)$|#if 0  /* husk: std::mutex cannot carry capability annotations (Xcode 16.4 clang) */|' \
        src/common/angleutils.h > src/common/angleutils.h.tmp
    mv src/common/angleutils.h.tmp src/common/angleutils.h
    echo "==> patched ANGLE thread-safety annotations (angleutils.h)"
else
    echo "==> ANGLE thread-safety annotations already neutralized"
fi

# The Metal backend's capability probes, for 12.2 (patch_angle_ios12.py explains
# what each one is and why it aborts the process when it is not guarded).
echo "==> patching ANGLE's Metal capability probes for iOS 12.2"
python3 "$HUSK_ROOT/scripts/patch_angle_ios12.py" "$PWD"

# Two overrides worth explaining.
#
# WK_AVAILABILITY_OVERLAY_FLAGS points at a clang VFS overlay that WebKit
# generates to defuse availability annotations. Nothing in this subset of the
# tree generates it, so the build dies looking for availability-overlay.yaml.
# Clearing the flag drops the overlay -- which then surfaces the errors it was
# hiding, all of the form "MTLPixelFormatBC1_RGBA is only available on iOS
# 16.4". Those are enum constants, harmless to compile in; the one call that
# matters, supportsBCTextureCompression, sits behind @available, so the warning
# is turned off rather than the target raised. Husk now deploys to 12.2 (the
# iOS 12.2 backport), and ANGLE is built to match -- but if WebKit's current
# revision will not build for 12.2, ANGLE_MINVER=15.5 is an acceptable fallback
# (ci_build.sh): the dylib is embedded, never linked, and dlopened only by the
# guest GL path, which is iOS 15+ on this backport.
ALIASES="$GPU/angle-aliases.txt"

angle_build () {
    # Everything xcodebuild needs goes through one array, expanded quoted, so
    # each element arrives as exactly one argument. Two traps this avoids:
    #
    # 1. A '#' comment line inside a backslash-continued command ENDS the
    #    command in bash. The previous version had its explanatory comment
    #    between the WK_AVAILABILITY_OVERLAY flags and the deployment target,
    #    so xcodebuild silently ran without IPHONEOS_DEPLOYMENT_TARGET, without
    #    OTHER_CFLAGS, without the alias LDFLAGS, and without the log redirect
    #    (its output went to the step log and $LOG stayed empty -- which is why
    #    the "last errors" filter printed nothing). Keep comments outside the
    #    command.
    # 2. ${ldflags[@]+...} as a bare word is the COMMAND NAME (it does not look
    #    like an assignment before expansion), so in pass 2 bash tried to run
    #    "OTHER_LDFLAGS=..." and died with 127 -- the "ANGLE build failed" with
    #    an empty error list. Building the array explicitly fixes both.
    #
    # $(inherited) is for xcodebuild to expand, not the shell, so it stays
    # backslash-escaped in the LDFLAGS element below.
    local args=(
        env -i PATH="$PATH" HOME="$HOME" xcodebuild archive
        -archivePath "ANGLE" -scheme "ANGLE"
        -sdk iphoneos -arch arm64 -configuration Release
        WEBCORE_LIBRARY_DIR="/usr/local/lib" NORMAL_UMBRELLA_FRAMEWORKS_DIR=""
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
        WK_AVAILABILITY_OVERLAY_FLAGS="" WK_AVAILABILITY_OVERLAY_SWIFT_FLAGS=""
        IPHONEOS_DEPLOYMENT_TARGET="${ANGLE_MINVER:-12.2}"
        OTHER_CFLAGS='$(inherited) -Wno-unguarded-availability-new -Wno-thread-safety -Wno-thread-safety-attributes -Wno-thread-safety-analysis'
        OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-unguarded-availability-new -Wno-thread-safety -Wno-thread-safety-attributes -Wno-thread-safety-analysis'
    )
    if [ -n "${1:-}" ]; then
        args+=("OTHER_LDFLAGS=\$(inherited) -Wl,-alias_list,$1")
    fi
    "${args[@]}" > "$LOG" 2>&1 \
      || { echo "ANGLE build failed; last errors:" >&2
           grep -a "error:\|^ld: " "$LOG" | head -10 >&2; exit 1; }
}

# Two passes, because of a name mismatch.
#
# WebKit builds ANGLE with its entry points renamed -- the dylib exports
# EGL_ChooseConfig, not eglChooseConfig -- since WebCore reaches them through
# ANGLE's own loader. libepoxy and virglrenderer expect the standard names.
# Rather than hand-write ~115 forwarding functions, the second pass relinks with
# ld's -alias_list, which adds the standard name as an alias of each renamed
# symbol. No wrappers, no extra indirection at call time.
#
# EGL only, deliberately. Aliasing the 828 GL_* exports the same way fails with
# "ld: 828 duplicate symbols" -- ANGLE already carries internal gl* symbols that
# the aliases collide with. It is also unnecessary: epoxy resolves GL entry
# points through eglGetProcAddress, so EGL is the only surface that must be
# reachable by its standard name.
echo "==> building ANGLE for iOS arm64, pass 1 (log: $LOG)"
angle_build ""

echo "==> generating EGL symbol aliases"
nm -g "ANGLE.xcarchive/Products/usr/local/lib/libANGLE-shared.dylib" \
  | awk '$2=="T"{print $3}' | grep -E '^_EGL_' \
  | awk '{o=$1; a=$1; sub(/^_EGL_/,"_egl",a); print o, a}' > "$ALIASES"
echo "    $(wc -l < "$ALIASES") aliases"

echo "==> pass 2, relinking with standard EGL names"
angle_build "$ALIASES"

DYLIB="ANGLE.xcarchive/Products/usr/local/lib/libANGLE-shared.dylib"
[ -f "$DYLIB" ] || { echo "no dylib at $DYLIB" >&2; exit 1; }

install -d "$PREFIX/lib" "$PREFIX/include"
cp "$DYLIB" "$PREFIX/lib/"
rsync -a "include/" "$PREFIX/include/"

# WebKit ships it for loading out of WebCore.framework; ours is embedded in the
# app, so the install name has to say so or dyld will not find it at runtime.
install_name_tool -id "@rpath/libANGLE-shared.dylib" "$PREFIX/lib/libANGLE-shared.dylib"

echo "==> staged $(ls -lh "$PREFIX/lib/libANGLE-shared.dylib" | awk '{print $5}') to $PREFIX/lib"
otool -D "$PREFIX/lib/libANGLE-shared.dylib" | tail -1
echo "==> standard EGL entry points exported: $(nm -g "$PREFIX/lib/libANGLE-shared.dylib" | grep -c ' T _egl')"
