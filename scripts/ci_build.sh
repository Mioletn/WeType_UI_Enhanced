#!/bin/bash
# Husk: build everything from a clean checkout to the IPA, in order.
#
# Runs on macOS with Xcode. Usage: ./scripts/ci_build.sh [output.ipa]
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HUSK_ROOT/build/Husk.ipa}"
cd "$HUSK_ROOT"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

# Preflight: virglrenderer vendors mesa's gallium build files, which parse YAML
# with meson's `python3` at configure time. Missing pyyaml only surfaces as
# "src/gallium/meson.build:72:16: ERROR: ... is missing modules: yaml" minutes
# into the build, so check before anything is compiled.
PY3="$(command -v python3 || true)"
if [ -z "$PY3" ] || ! "$PY3" -c 'import yaml' >/dev/null 2>&1; then
    echo "!! python3 (${PY3:-not found}) cannot import yaml; virglrenderer will not configure." >&2
    echo "   Homebrew python: brew install pyyaml" >&2
    exit 1
fi

step "fetch sources"
./scripts/fetch_sources.sh

step "dependencies: libffi glib pixman libucontext libslirp"
./scripts/build_ios.sh libffi glib pixman libucontext libslirp

# build_gpu_ios.sh asks for cross-ios-darwin.meson, which no script generates.
# build_ios.sh writes cross-darwin.meson, the file it describes (host system
# darwin, subsystem ios), under a different name.
cp build/ios-arm64/cross-darwin.meson build/ios-arm64/cross-ios-darwin.meson

if [ ! -f build/ios-arm64/sysroot/lib/libANGLE-shared.dylib ]; then
    step "ANGLE (EGL/GLES over Metal)"
    # 12.2 first, to match the app. WebKit's ANGLE moves its floor over time,
    # and a revision that will not build for 12.2 is not a reason to fail the
    # IPA: the dylib is embedded but never linked, and the only thing that
    # dlopens it is the guest GL path (virglrenderer), which the iOS 12.2
    # backport never reaches -- its display surface is iOS 13+. So a fallback
    # to 15.5 is harmless here, and a hard failure is not.
    ./scripts/build_angle_ios.sh \
        || { echo "==> ANGLE will not build for 12.2; retrying at 15.5 (embed-only)"; \
             ANGLE_MINVER=15.5 ./scripts/build_angle_ios.sh; }
    # The sparse WebKit checkout (with its ANGLE.xcarchive, gigabytes) is not
    # needed once the dylib and headers are staged; a CI runner has ~14 GB.
    rm -rf "$HUSK_ROOT/third_party/gpu/webkit"
fi

if [ ! -f build/ios-arm64/sysroot/lib/libvirglrenderer.a ]; then
    step "libepoxy + virglrenderer"
    # build_ios.sh's cross environment, which the GPU script assumes is set.
    PKG_CONFIG_LIBDIR="$HUSK_ROOT/build/ios-arm64/sysroot/lib/pkgconfig:$HUSK_ROOT/build/ios-arm64/sysroot/share/pkgconfig" \
        ./scripts/build_gpu_ios.sh
fi

step "QEMU"
./scripts/build_ios.sh qemu

step "integrate Husk sources into QEMU, then rebuild it"
./scripts/integrate_husk.sh
./scripts/build_ios.sh qemurebuild

step "guest kernel + firmware"
./scripts/fetch_phase0_guest.sh

if [ ! -d build/ios-arm64/lib/MoltenVK.xcframework ]; then
    step "MoltenVK (Vulkan over Metal, for Unreal Engine games)"
    ./scripts/build_moltenvk_ios.sh
fi

step "on-device pairing (Rust)"
./scripts/build_rppairing_ios.sh

# The PS4 layer: sources are private trees (Bachata-S4 branch husk, husk-fex
# branch husk-fex) and it is iOS 17.4+ only, so CI cannot build the real one.
# The app embeds it without linking and opens it by path only on iOS 17.4+
# (PS4Store.moduleURL), so a stub keeps the bundle shape identical; on a Mac
# with the trees, scripts/build_ps4_ios.sh writes the real dylib here first and
# this step leaves it alone.
if [ ! -f build/ios-arm64/lib/libhuskps4.dylib ]; then
    step "PS4 layer: stub (private sources; iOS 17.4+ only)"
    printf 'const int husk_ps4_stub = 0;\n' > /tmp/husk_ps4_stub.c
    xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -mios-version-min=17.4 \
        -install_name @rpath/libhuskps4.dylib \
        -o build/ios-arm64/lib/libhuskps4.dylib /tmp/husk_ps4_stub.c
fi

step "app + IPA"
df -h "$HUSK_ROOT" | tail -1
mkdir -p "$(dirname "$OUT")"
./scripts/package_ipa.sh "$OUT"
./scripts/package_ipa.sh --trollstore "${OUT%.ipa}.tipa"
