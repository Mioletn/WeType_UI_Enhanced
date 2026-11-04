#!/bin/bash
# Download + unpack every Husk dependency into third_party/sources and third_party/build.
set -u
HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$HUSK_ROOT/scripts/sources.sh"
DL="$HUSK_ROOT/third_party/sources"
SRC="$HUSK_ROOT/third_party/build"
mkdir -p "$DL" "$SRC"

# ftp.gnu.org times out from some runners -- the connect hangs rather than
# refusing, so --retry never gets a second chance at a different host. A GNU
# tarball is therefore tried against the mirror pool before the build gives up on
# it; a run that cannot reach the origin costs two connect timeouts, not a build.
gnu_mirrors() {
    case "$1" in
        https://ftp.gnu.org/gnu/*)
            printf '%s\n%s\n' "${1/ftp.gnu.org\/gnu/ftpmirror.gnu.org}" \
                              "${1/ftp.gnu.org\/gnu/mirrors.kernel.org\/gnu}" ;;
    esac
}

fetch() {
    local url="$1" file="$DL/$(basename "$1")" alt
    if [ -s "$file" ]; then echo "[skip] $(basename "$file")"; return 0; fi
    echo "[get ] $(basename "$file")"
    for alt in "$url" $(gnu_mirrors "$url"); do
        if curl -fL --retry 2 --retry-delay 5 --connect-timeout 25 --max-time 900 \
                -o "$file.part" "$alt"; then
            mv "$file.part" "$file"
            return 0
        fi
        echo "[retry] $alt"
    done
    rm -f "$file.part"
    echo "[FAIL] $url"
    return 1
}

unpack() {
    local file="$DL/$(basename "$1")" stamp
    stamp="$SRC/.unpacked-$(basename "$file")"
    [ -f "$stamp" ] && { echo "[skip] unpack $(basename "$file")"; return 0; }
    echo "[tar ] $(basename "$file")"
    tar -xf "$file" -C "$SRC" || return 1
    touch "$stamp"
}

rc=0
for u in "$FFI_SRC" "$ICONV_SRC" "$GETTEXT_SRC" "$GLIB_SRC" "$PIXMAN_SRC" "$SLIRP_SRC" "$QEMU_SRC"; do
    fetch "$u" || rc=1
done
for u in "$FFI_SRC" "$ICONV_SRC" "$GETTEXT_SRC" "$GLIB_SRC" "$PIXMAN_SRC" "$SLIRP_SRC" "$QEMU_SRC"; do
    unpack "$u" || rc=1
done

if [ ! -d "$SRC/libucontext" ]; then
    echo "[git ] libucontext"
    git clone "$LIBUCONTEXT_REPO" "$SRC/libucontext" >/dev/null 2>&1 \
        && git -C "$SRC/libucontext" checkout -q "$LIBUCONTEXT_COMMIT" \
        || { echo "[FAIL] libucontext"; rc=1; }
else
    echo "[skip] libucontext"
fi

echo "--- result rc=$rc ---"
ls -1 "$SRC" | grep -v '^\.' 
exit $rc
