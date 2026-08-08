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

echo "Using adb: $ADB"
"$ADB" shell "am force-stop $PKG"
"$ADB" shell "run-as $PKG sh -c 'cat > $DEST/main.lua'" < main.lua

LOCAL=$(md5sum main.lua | cut -d' ' -f1)
REMOTE=$("$ADB" shell "run-as $PKG md5sum $DEST/main.lua" | tr -d '\r' | cut -d' ' -f1)
if [ "$LOCAL" = "$REMOTE" ]; then
    echo "deploy: OK"
else
    echo "deploy: MISMATCH (local=$LOCAL remote=$REMOTE)" >&2
    exit 1
fi

"$ADB" logcat -c
"$ADB" shell "am start -n $PKG/org.koreader.launcher.MainActivity"

sleep 16
"$ADB" logcat -d | grep -iE "Plugin loaded stylus|error|nil value" | tail -4