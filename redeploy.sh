#!/usr/bin/env sh
set -e

cd "$(dirname "$0")"

PKG="org.koreader.launcher.debug"
BASE="/data/user/0/$PKG"
ASSET_PLUGINS="$BASE/files/plugins"
ASSET_DEST="$ASSET_PLUGINS/stylus-annotations.koplugin"
EXTRA_DIR="/storage/emulated/0/koreader/plugins"
EXTRA_DEST="$EXTRA_DIR/stylus-annotations.koplugin"
SETTINGS="/storage/emulated/0/koreader/settings.reader.lua"

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

WIRELESS_SERIAL=$("$ADB" devices 2>/dev/null | awk '/:[0-9]+\s+device/{print $1; exit}')
ADB_ARGS=
if [ -n "$WIRELESS_SERIAL" ]; then
    ADB_ARGS="-s $WIRELESS_SERIAL"
fi

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    else
        md5 -q "$1"
    fi
}

PLUGIN_DIR=stylus-annotations.koplugin
if [ ! -d "$PLUGIN_DIR" ]; then
    echo "Missing plugin directory $PLUGIN_DIR. Aborting." >&2
    exit 1
fi
FILES=$(cd "$PLUGIN_DIR" && find . -type f | sed 's|^\./||')

push_plugin() {
    DEST=$1
    echo "-> $DEST"
    "$ADB" $ADB_ARGS shell "run-as $PKG sh -c 'rm -rf $DEST && mkdir -p $DEST'"
    tar -cf - -C "$PLUGIN_DIR" $FILES 2>/dev/null | "$ADB" $ADB_ARGS shell "run-as $PKG sh -c 'cd $DEST && tar -xf -'" >/dev/null 2>&1 || true
}

verify_plugin() {
    DEST=$1
    FAIL=0
    for f in $FILES; do
        L=$(md5_of "$PLUGIN_DIR/$f")
        R=$("$ADB" $ADB_ARGS shell "run-as $PKG md5sum $DEST/$f" | tr -d '\r' | cut -d' ' -f1)
        if [ -n "$R" ] && [ "$L" = "$R" ]; then
            echo "  ok $f"
        else
            echo "  MISMATCH $f (local=$L remote=$R)" >&2
            FAIL=1
        fi
    done
    return $FAIL
}

ensure_extra_plugin_paths() {
    echo "Ensuring extra_plugin_paths includes $EXTRA_DIR in $SETTINGS"
    "$ADB" $ADB_ARGS shell "run-as $PKG sh -c '
        f=$SETTINGS
        if [ ! -f \"\$f\" ]; then return; fi
        if ! grep -q \"$EXTRA_DIR\" \"\$f\"; then
            sed -i \"s|^}|    [\\\"extra_plugin_paths\\\"] = {\\n        [1] = \\\"$EXTRA_DIR/\\\",\\n    },\\n}|g\" \"\$f\"
        fi
    '"
}

echo "Using adb: $ADB $ADB_ARGS"
echo "Stopping $PKG"
"$ADB" $ADB_ARGS shell "am force-stop $PKG"

push_plugin "$ASSET_DEST"
push_plugin "$EXTRA_DEST"

echo "Verifying checksums"
if ! verify_plugin "$ASSET_DEST"; then
    if ! verify_plugin "$EXTRA_DEST"; then
        echo "Checksum verification failed for both destinations" >&2
        exit 1
    fi
fi

ensure_extra_plugin_paths

"$ADB" $ADB_ARGS logcat -c
"$ADB" $ADB_ARGS shell "am start -n $PKG/org.koreader.launcher.MainActivity"
sleep 16
"$ADB" $ADB_ARGS logcat -d | grep -iE "Looking for plugins|stylus|error|nil value" | tail -8 || true
echo "done"
