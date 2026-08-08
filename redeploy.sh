#!/usr/bin/env sh
set -e

cd "$(dirname "$0")"

PKG="org.koreader.launcher.debug"
DEST="/data/user/0/$PKG/files/plugins/stylus-annotations.koplugin"

if ! command -v adb >/dev/null 2>&1; then
    if [ -x "$HOME/Projects/koreader/koreader/base/toolchain/android-sdk-linux/platform-tools/adb" ]; then
        ADB="$HOME/Projects/koreader/koreader/base/toolchain/android-sdk-linux/platform-tools/adb"
    else
        echo "adb not found on PATH (and no local KOReader toolchain fallback). Aborting." >&2
        exit 1
    fi
else
    ADB=adb
fi

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    else
        md5 -q "$1"
    fi
}

FILES=$(find main.lua _meta.lua lib -type f)

echo "Using adb: $ADB"
echo "Stopping $PKG"
"$ADB" shell "am force-stop $PKG"

echo "Pushing plugin files"
"$ADB" shell "run-as $PKG sh -c 'rm -rf $DEST && mkdir -p $DEST'" 
tar -cf - $FILES 2>/dev/null | "$ADB" shell "run-as $PKG sh -c 'cd $DEST && tar -xf -'" >/dev/null 2>&1 || true 

echo "Verifying checksums"
FAIL=0
for f in $FILES; do
    L=$(md5_of "$f")
    R=$("$ADB" shell "run-as $PKG md5sum $DEST/$f" | tr -d '\r' | cut -d' ' -f1)
    if [ -n "$R" ] && [ "$L" = "$R" ]; then
        echo "  ok $f"
    else
        echo "  MISMATCH $f (local=$L remote=$R)" >&2
        FAIL=1
    fi
done
if [ "$FAIL" != "0" ]; then exit 1; fi

"$ADB" logcat -c
"$ADB" shell "am start -n $PKG/org.koreader.launcher.MainActivity"
sleep 16
"$ADB" logcat -d | grep -iE "Plugin loaded stylus|error|nil value" | tail -4