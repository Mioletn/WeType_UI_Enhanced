#!/bin/bash
# extract_java_runtime.sh <vda.qcow2> -- the payload Husk's Dalvik runtime boots
# from, taken out of the Android guest disk instead of an Android system tree.
#
# scripts/build_java_runtime.sh does the same job with a Lineage checkout's
# /apex directory on hand. No CI runner has one, and the app already downloads a
# guest disk (GuestImage.swift, releases/lineage-v2), so this reads the payload
# out of that disk instead: super partition -> system -> the four APEXes that
# carry libcore, ICU, conscrypt and the time zones -> the platform's resources.
#
# Output is build/java-runtime, in the layout build_java_runtime.sh documents,
# which package_ipa.sh copies into the app as java-runtime/.
#
#   scripts/extract_java_runtime.sh build/vda-v12.qcow2
#
# Needs qemu-img (qemu), debugfs (brew install e2fsprogs), unzip, python3, and a
# JDK plus R8 for Husk's Java framework dex.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:?usage: extract_java_runtime.sh <vda.qcow2|vda.raw>}"
OUT_BUILD="$HUSK_ROOT/build/java-runtime"
DEBUGFS="${DEBUGFS:-$(command -v debugfs || echo /opt/homebrew/opt/e2fsprogs/sbin/debugfs)}"
R8_JAR="${HUSK_D8:-$HUSK_ROOT/build/tools/r8.jar}"
R8_URL="${R8_URL:-https://dl.google.com/dl/android/maven2/com/android/tools/r8/8.5.35/r8-8.5.35.jar}"

[ -x "$DEBUGFS" ] || { echo "no debugfs at $DEBUGFS (brew install e2fsprogs)" >&2; exit 1; }
[ -f "$IMG" ] || { echo "no image at $IMG" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Assembled under WORK and moved into place at the end: package_ipa.sh copies
# whatever it finds in build/java-runtime into the app, so a half-extracted
# payload would be shipped as a runtime that cannot boot.
OUT="$WORK/java-runtime"

RAW="$IMG"
case "$IMG" in
    *.qcow2) echo "==> converting the image"; qemu-img convert -O raw "$IMG" "$WORK/vda.raw"; RAW="$WORK/vda.raw" ;;
esac

# ------------------------------------------------------------------ system.img
#
# The disk is GPT with a "super" partition, and super holds logical partitions
# (Android's dynamic partitions) as extents. Same walk as
# build_android_system.sh, with the metadata header located by its magic rather
# than at a fixed offset, because the geometry differs between super versions.
echo "==> super -> system"
python3 - "$RAW" "$WORK/system.img" <<'EOF'
import os, struct, sys

raw, out = sys.argv[1], sys.argv[2]
SECTOR = 512
f = open(raw, 'rb')

# GPT: header at LBA1, entries at LBA2 (128 entries of 128 bytes by default).
f.seek(SECTOR)
hdr = f.read(92)
assert hdr[:8] == b'EFI PART', 'no GPT header'
entry_lba, count, esize = struct.unpack_from('<QII', hdr, 72)
f.seek(entry_lba * SECTOR)
entries = f.read(count * esize)
super_lba = None
for i in range(count):
    e = entries[i * esize:(i + 1) * esize]
    if e[:16] == b'\0' * 16:
        continue
    first, last = struct.unpack_from('<QQ', e, 32)
    name = e[56:128].decode('utf-16-le', 'replace').split('\0')[0]
    if name == 'super':
        super_lba = first
assert super_lba is not None, 'no super partition'

base = super_lba * SECTOR
MAGIC = 0x414C5030

# The logical-partition metadata sits at a 4096-byte offset inside super whose
# value differs between super versions, so find it by its magic rather than
# trusting one number.
meta = None
for off in range(0, 128 << 10, 4096):
    f.seek(base + off)
    h = f.read(4096)
    if len(h) >= 256 and struct.unpack_from('<I', h, 0)[0] == MAGIC:
        meta = (off, h)
        break
assert meta, 'no logical partition metadata in super'
off, h = meta
hsize = struct.unpack_from('<I', h, 8)[0]

# lp_metadata_header: tables_size at 16, then four descriptors at 24, 36, 48
# and 60 -- but the image this was written against lays them out differently, so
# try both and keep the one whose descriptor sizes are Android's (a partition
# record is 36-byte name + four u32 = 52, an extent is 8+4+8+4 padded = 24).
LAYOUTS = ((16, 24), (44, 80))
f.seek(base + off + hsize)
tables = f.read(1 << 20)
chosen = None
for tsize_at, desc_at in LAYOUTS:
    tsize = struct.unpack_from('<I', h, tsize_at)[0]
    if not (0 < tsize <= len(tables)):
        continue
    po, pn, ps = struct.unpack_from('<III', h, desc_at)
    eo, en, es = struct.unpack_from('<III', h, desc_at + 12)
    if ps == 52 and es == 24 and po + pn * ps <= tsize and eo + en * es <= tsize:
        chosen = (tsize, po, pn, ps, eo, en, es)
        break
assert chosen, 'unrecognised logical partition metadata'
tsize, po, pn, ps, eo, en, es = chosen
T = tables[:tsize]
ext = [struct.unpack_from('<QIQI', T, eo + es * i) for i in range(en)]

found = False
for i in range(pn):
    e = T[po + ps * i:po + ps * (i + 1)]
    name = e[:36].split(b'\0')[0].decode()
    _, fi, ne, _ = struct.unpack_from('<IIII', e, 36)
    if name != 'system':
        continue
    with open(out, 'wb') as w:
        for j in range(fi, fi + ne):
            nsec, _, data, _ = ext[j]
            f.seek(base + data * SECTOR)
            left = nsec * SECTOR
            while left:
                b = f.read(min(left, 64 << 20))
                if not b:
                    raise SystemExit('short read in extent %d' % j)
                w.write(b)
                left -= len(b)
    found = True
    break
assert found, 'no system logical partition'
print('    system.img written: %d bytes' % os.path.getsize(out))
EOF

# Android moved its tree from /system/... to the partition's root between
# releases (system-as-root), and this image and the one next to it disagree, so
# every path is looked up in both shapes instead of trusting one.
in_image() {
    "$DEBUGFS" -R "stat $1" "$WORK/system.img" 2>/dev/null | grep -q 'Inode:'
}

resolve() {  # resolve <path relative to Android's root> -> path inside the image
    local rel="$1" p
    for p in "/system/$rel" "/$rel"; do
        if in_image "$p"; then echo "$p"; return 0; fi
    done
    echo "nothing at /system/$rel or /$rel in system.img" >&2
    echo "  root holds: $("$DEBUGFS" -R "ls -l /" "$WORK/system.img" 2>&1 | head -20 | tr '\n' ' ')" >&2
    return 1
}

dump_file() {  # dump_file <path relative to Android's root> <out>
    local path
    path="$(resolve "$1")" || exit 1
    "$DEBUGFS" -R "dump $path $2" "$WORK/system.img" >/dev/null 2>&1
    [ -s "$2" ] || {
        echo "could not dump $path from system.img" >&2
        "$DEBUGFS" -R "stat $path" "$WORK/system.img" >&2 || true
        exit 1
    }
}

flatten() {  # flatten <dir> <name> -- move <dir>/<name>/* up into <dir>
    local dir="$1" nested="$1/$2"
    [ -d "$nested" ] || return 0
    mv "$nested"/* "$dir"/ 2>/dev/null || true
    rm -rf "$nested"
}

echo "==> platform: resources and HttpClient"
dump_file framework/framework-res.apk "$WORK/framework-res.apk"
dump_file framework/org.apache.http.legacy.jar "$WORK/org.apache.http.legacy.jar"

echo "==> APEX payloads"
APEX_DIR="$(resolve apex)" || exit 1
mkdir -p "$WORK/apex"
"$DEBUGFS" -R "rdump $APEX_DIR $WORK/apex" "$WORK/system.img" >/dev/null 2>&1 || true
# rdump puts the source directory's own name under the destination, so the files
# arrive one level deep; everything below reads them flat.
flatten "$WORK/apex" apex
ls "$WORK/apex" >/dev/null 2>&1 || { echo "could not list $APEX_DIR" >&2; exit 1; }

# One APEX at a time: unzip its payload image, then take the directories that
# carry what the runtime loads.
apex() {  # apex <name> -> $WORK/<name>/apex_payload.img
    local name="$1" zip="$WORK/apex/$1.apex" payload
    mkdir -p "$WORK/$name"
    if [ ! -f "$zip" ]; then
        # Images built with compressed APEXes carry <name>.capex, which is a zip
        # holding "original_apex" -- the plain APEX -- alongside its manifest.
        if [ -f "$WORK/apex/$name.capex" ]; then
            unzip -o -q "$WORK/apex/$name.capex" original_apex -d "$WORK/$name" \
                || { echo "$name.capex holds no original_apex" >&2; exit 1; }
            zip="$WORK/$name/original_apex"
        else
            echo "no $name.apex or $name.capex in the image (have: $(ls "$WORK/apex" | tr '\n' ' '))" >&2
            exit 1
        fi
    fi
    payload="$WORK/$name/apex_payload.img"
    unzip -o -q "$zip" apex_payload.img -d "$WORK/$name" \
        || { echo "$(basename "$zip") holds no apex_payload.img" >&2; exit 1; }
    echo "$payload"
}

apex_rdump() {  # apex_rdump <payload.img> <dir-in-payload> <out-dir>
    mkdir -p "$3"
    "$DEBUGFS" -R "rdump $2 $3" "$1" >/dev/null 2>&1 || true
    flatten "$3" "$(basename "$2")"
}

copy() {  # copy <from> <to-relative-in-java-runtime>
    [ -f "$1" ] || { echo "missing $1" >&2; exit 1; }
    mkdir -p "$OUT/$(dirname "$2")"
    cp "$1" "$OUT/$2"
}

mkdir -p "$OUT"

APEX_ART="$(apex com.android.art)"
apex_rdump "$APEX_ART" /javalib "$WORK/art/javalib"
apex_rdump "$APEX_ART" /lib64   "$WORK/art/lib64"
for j in core-oj core-libart okhttp bouncycastle apache-xml; do
    copy "$WORK/art/javalib/$j.jar" "com.android.art/javalib/$j.jar"
done
for l in libandroidio libbase libc++ libexpat libjavacore libnativehelper libopenjdk; do
    copy "$WORK/art/lib64/$l.so" "com.android.art/lib64/$l.so"
done

APEX_I18N="$(apex com.android.i18n)"
apex_rdump "$APEX_I18N" /javalib "$WORK/i18n/javalib"
apex_rdump "$APEX_I18N" /lib64   "$WORK/i18n/lib64"
apex_rdump "$APEX_I18N" /etc     "$WORK/i18n/etc"
copy "$WORK/i18n/javalib/core-icu4j.jar" "com.android.i18n/javalib/core-icu4j.jar"
for l in libicu libicui18n libicuuc libicu_jni libandroidicu; do
    copy "$WORK/i18n/lib64/$l.so" "com.android.i18n/lib64/$l.so"
done
mkdir -p "$OUT/com.android.i18n/etc"
cp -R "$WORK/i18n/etc/icu" "$OUT/com.android.i18n/etc/" \
    || { echo "no ICU data in com.android.i18n" >&2; exit 1; }

APEX_TZ="$(apex com.android.tzdata)"
apex_rdump "$APEX_TZ" /etc "$WORK/tz/etc"
mkdir -p "$OUT/com.android.tzdata"
cp -R "$WORK/tz/etc" "$OUT/com.android.tzdata/" \
    || { echo "no time zone data in com.android.tzdata" >&2; exit 1; }

APEX_CS="$(apex com.android.conscrypt)"
apex_rdump "$APEX_CS" /javalib "$WORK/cs/javalib"
apex_rdump "$APEX_CS" /lib64   "$WORK/cs/lib64"
copy "$WORK/cs/javalib/conscrypt.jar" "com.android.conscrypt/javalib/conscrypt.jar"
for l in libjavacrypto libcrypto libssl; do
    copy "$WORK/cs/lib64/$l.so" "com.android.conscrypt/lib64/$l.so"
done

echo "==> Husk's Java framework (javac + d8)"
if [ -z "${HUSK_JDK:-}" ]; then
    HUSK_JDK="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
[ -n "${HUSK_JDK:-}" ] || { echo "no JDK (set HUSK_JDK)" >&2; exit 1; }
if [ ! -f "$R8_JAR" ]; then
    mkdir -p "$(dirname "$R8_JAR")"
    curl -fsSL "$R8_URL" -o "$R8_JAR"
fi
HUSK_JDK="$HUSK_JDK" HUSK_D8="$R8_JAR" "$HUSK_ROOT/src/java-framework/build.sh" "$OUT/husk-framework.dex"

echo "==> Apache HttpClient and the platform's resources"
copy "$WORK/org.apache.http.legacy.jar" "org.apache.http.legacy.jar"
python3 "$HUSK_ROOT/tools/strip_framework_res.py" "$WORK/framework-res.apk" "$OUT/framework-res.apk"

rm -rf "$OUT_BUILD"
mkdir -p "$(dirname "$OUT_BUILD")"
mv "$OUT" "$OUT_BUILD"
du -sh "$OUT_BUILD"
find "$OUT_BUILD" -type f | wc -l
