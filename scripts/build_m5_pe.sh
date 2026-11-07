#!/bin/bash
# M5 spike: can the macOS runner produce Windows PE binaries at all?
#
# Report-only, never fails the job. Two independent questions:
#   1. A minimal freestanding x86-64 PE (hello.exe / hello.dll) via brew's
#      x86_64-w64-mingw32-gcc. This is the format FEX would execute.
#   2. Wine's PE-side ntdll.dll (x86_64-windows/ntdll.dll), which is what
#      wine-ios/ntdll/loader_ios.c opens from <bundle>/x86_64-windows/.
#      Best effort: if configure/make cannot run here, report exactly where.
#
# Everything lands in build/m1/pe/ so m5-pe.yml can upload it as an artifact.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/m1/pe"
mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

WINE_SHA="9129e9684daaeae70da9435e7c6060e59392634e"
SRC="$ROOT/build/wine/src"
PE="$SRC/build-pe"

# ---------------------------------------------------------------- toolchain
log "== toolchain =="
for p in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin; do
    [ -x "$p/bison" ] && PATH="$p:$PATH"
done
export PATH
log "bison: $(bison --version 2>/dev/null | head -1 || echo none)"
XCC="$(command -v x86_64-w64-mingw32-gcc || true)"
log "x86_64 PE cc: ${XCC:-none}"
[ -n "$XCC" ] && log "$("$XCC" --version | head -1)"
log "wine configure: $([ -f "$SRC/configure" ] && echo present || echo absent)"
log ""

# ------------------------------------------------------- 1. minimal PE image
log "== minimal x86-64 PE =="
cat > "$OUT/hello.c" <<'EOF'
/* Freestanding: no CRT, no imports. husk_entry returns 42 in %eax. */
int husk_m5_answer(void) { return 4242; }
int husk_entry(void) { return husk_m5_answer() - 4200; }
EOF

if [ -n "$XCC" ]; then
    "$XCC" -O2 -fno-stack-protector -nostdlib \
        -Wl,-e,husk_entry -Wl,--subsystem,console -Wl,--no-seh \
        -o "$OUT/hello.exe" "$OUT/hello.c" > "$OUT/hello-exe.log" 2>&1
    log "hello.exe link rc=$? size=$(wc -c < "$OUT/hello.exe" 2>/dev/null || echo 0)"

    "$XCC" -O2 -fno-stack-protector -nostdlib -shared \
        -Wl,--dll -Wl,-e,husk_entry -Wl,--export-all-symbols \
        -o "$OUT/hello.dll" "$OUT/hello.c" > "$OUT/hello-dll.log" 2>&1
    log "hello.dll link rc=$? size=$(wc -c < "$OUT/hello.dll" 2>/dev/null || echo 0)"
else
    log "SKIPPED: no x86_64-w64-mingw32-gcc"
fi

# Parse the PE headers without any Windows tooling.
python3 - "$OUT" <<'PY' | tee -a "$REPORT"
import os, struct, sys
out = sys.argv[1]
for name in ("hello.exe", "hello.dll"):
    p = os.path.join(out, name)
    if not os.path.isfile(p):
        print(name, "MISSING"); continue
    d = open(p, "rb").read()
    if d[:2] != b"MZ":
        print(name, "not MZ"); continue
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    if d[pe:pe+4] != b"PE\0\0":
        print(name, "no PE signature"); continue
    machine, nsec = struct.unpack_from("<HH", d, pe+4)
    optsz = struct.unpack_from("<H", d, pe+20)[0]
    o = pe + 24
    magic, = struct.unpack_from("<H", d, o)
    entry = struct.unpack_from("<I", d, o+16)[0]
    imagebase = struct.unpack_from("<Q", d, o+24)[0] if magic == 0x20b else 0
    sizeimg = struct.unpack_from("<I", d, o+56)[0]
    subsystem = struct.unpack_from("<H", d, o+68)[0]
    secs = []
    so = o + optsz
    for i in range(nsec):
        nm, vsz, va, rawsz = struct.unpack_from("<8sIII", d, so + i*40)[:4]
        secs.append(nm.rstrip(b"\0").decode("ascii", "replace"))
    print("%s: size=%d machine=0x%04x magic=0x%03x entry=0x%x imagebase=0x%x "
          "sizeofimage=0x%x subsystem=%d sections=%s"
          % (name, len(d), machine, magic, entry, imagebase, sizeimg,
             subsystem, ",".join(secs)))
PY
log ""

# ---------------------------------------------------- 2. Wine PE-side ntdll
log "== Wine PE-side ntdll.dll =="
if [ ! -f "$SRC/configure" ]; then
    log "fetching willfaust/wine at $WINE_SHA (single commit)"
    mkdir -p "$SRC"
    ( cd "$SRC" && git init -q && \
      git remote add origin https://github.com/willfaust/wine.git 2>/dev/null; \
      git fetch -q --depth=1 origin "$WINE_SHA" && \
      git checkout -q FETCH_HEAD ) > "$OUT/wine-fetch.log" 2>&1
    log "fetch rc=$?"
fi

COMMON="--without-x --disable-tests --without-freetype --without-gnutls
        --without-vulkan --without-sdl --without-alsa --without-pulse
        --without-cups --without-dbus --without-odbc --without-opencl
        --without-opengl --without-osmesa --without-krb5 --without-netapi
        --without-pcap --without-usb --without-wayland"

if [ -f "$SRC/configure" ]; then
    # Madeira's unix TUs include "../../../../build/madeira_cfg.h", a header
    # generated outside the source tree by their build. config.status/makedep
    # fails on sync.c:29 without it (first spike died exactly there). The file
    # is header-only and already vendored in wine-ios/ntdll; place copies at
    # every plausible root so the relative include resolves.
    CFG="$ROOT/wine-ios/ntdll/madeira_cfg.h"
    if [ -f "$CFG" ]; then
        WINE_TOP="$(dirname "$SRC")"
        for d in "$WINE_TOP/build" "$SRC/build"; do
            mkdir -p "$d" && cp "$CFG" "$d/madeira_cfg.h" \
                && log "placed madeira_cfg.h -> $d"
        done
    else
        log "WARNING: wine-ios/ntdll/madeira_cfg.h not found"
    fi

    rm -rf "$PE"; mkdir -p "$PE"
    mkdir -p "$PE/build" && [ -f "$CFG" ] && cp "$CFG" "$PE/build/madeira_cfg.h"
    log "configure --enable-archs=x86_64 ..."
    python3 - 1800 "$OUT/wine-pe-configure.log" "$PE" "$SRC/configure" \
        --enable-archs=x86_64 $COMMON <<'PY'
import subprocess, sys
secs, logf, cwd = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cmd = sys.argv[4:]
with open(logf, "w") as f:
    f.write("cwd=%s\ncmd=%s\n" % (cwd, " ".join(cmd)))
    try:
        rc = subprocess.call(cmd, cwd=cwd, stdout=f,
                             stderr=subprocess.STDOUT, timeout=secs)
    except subprocess.TimeoutExpired:
        f.write("TIMEOUT\n"); rc = 124
    f.write("\nCONFIGURE_RC=%d\n" % rc)
PY
    if grep -q "CONFIGURE_RC=0" "$OUT/wine-pe-configure.log"; then
        log "configure OK"
    else
        log "configure FAILED; first errors:"
        grep -m8 -E "configure: error|error:|not found|no acceptable" \
            "$OUT/wine-pe-configure.log" | sed 's/^/    /' | tee -a "$REPORT"
    fi
    if [ -f "$PE/Makefile" ]; then
        log "make -j4 (35 min cap) ..."
        python3 - 2100 "$OUT/wine-pe-make.log" "$PE" make -j4 <<'PY'
import subprocess, sys
secs, logf, cwd = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cmd = sys.argv[4:]
with open(logf, "w") as f:
    try:
        rc = subprocess.call(cmd, cwd=cwd, stdout=f,
                             stderr=subprocess.STDOUT, timeout=secs)
    except subprocess.TimeoutExpired:
        f.write("\nTIMEOUT (35 min cap)\n"); rc = 124
    f.write("\nMAKE_RC=%d\n" % rc)
PY
        grep -E "MAKE_RC=|TIMEOUT" "$OUT/wine-pe-make.log" | tee -a "$REPORT"
        tail -12 "$OUT/wine-pe-make.log" | sed 's/^/    /' | tee -a "$REPORT"
    fi
else
    log "SKIPPED: wine source unavailable"
fi

log ""
log "== ntdll.dll artifacts found =="
find "$SRC" -name "ntdll.dll" -type f 2>/dev/null | while read -r f; do
    log "  $f ($(wc -c < "$f") bytes)"
    cp "$f" "$OUT/ntdll.dll" 2>/dev/null && log "  copied to build/m1/pe/ntdll.dll"
done
[ -f "$OUT/ntdll.dll" ] || log "  (none -- PE build did not complete)"

log ""
log "== verdict =="
[ -f "$OUT/hello.exe" ] && log "hello PE: PRODUCED" || log "hello PE: FAILED"
[ -f "$OUT/ntdll.dll" ] && log "Wine PE ntdll: PRODUCED" || log "Wine PE ntdll: NOT PRODUCED (see logs above)"
exit 0
