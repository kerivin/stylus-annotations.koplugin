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

get_wifi_ip() {
    serial=$1
    for iface in wlan0 eth0 wlan1; do
        ip=$("$ADB" -s "$serial" shell ip addr show "$iface" 2>/dev/null | tr -d '\r' | awk '/inet /{print $2; exit}' | cut -d/ -f1) || true
        if [ -n "$ip" ]; then
            echo "$ip"
            return
        fi
    done
    ip=$("$ADB" -s "$serial" shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r') || true
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi
    "$ADB" -s "$serial" shell ip addr 2>/dev/null | tr -d '\r' | awk '/inet / && !/127.0.0.1/{print $2; exit}' | cut -d/ -f1 || true
}

switch_to_wireless() {
    serial=$1
    ip=$(get_wifi_ip "$serial")
    if [ -z "$ip" ]; then
        echo "Could not determine the device IP address over USB." >&2
        return 1
    fi
    echo "Restarting adbd on $serial over TCP (port 5555)..." >&2
    "$ADB" -s "$serial" tcpip 5555 >/dev/null 2>&1 || true
    sleep 2
    echo "Connecting to $ip:5555..." >&2
    "$ADB" connect "$ip:5555" >/dev/null 2>&1 || true
    sleep 1
    "$ADB" devices 2>/dev/null | awk '/:[0-9]+\s+device/{print $1; exit}'
}

if [ -z "$WIRELESS_SERIAL" ]; then
    USB_SERIAL=$("$ADB" devices 2>/dev/null | awk '$2 == "device" && $1 !~ /:[0-9]+$/{print $1; exit}')
    if [ -z "$USB_SERIAL" ]; then
        echo "No wireless adb device connected." >&2
        echo "To switch this device to wireless adb, connect it via USB and re-run redeploy.sh." >&2
        exit 1
    fi
    echo "No wireless adb device connected; found $USB_SERIAL over USB, switching it to wireless adb..."
    WIRELESS_SERIAL=$(switch_to_wireless "$USB_SERIAL")
    if [ -z "$WIRELESS_SERIAL" ]; then
        echo "Failed to switch $USB_SERIAL to wireless adb." >&2
        echo "Connect the device via USB and re-run redeploy.sh." >&2
        exit 1
    fi
    echo "Switched to wireless adb: $WIRELESS_SERIAL"
fi

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
        if [ ! -f \"\$f\" ]; then
            printf \"return {\\n    [\\\"extra_plugin_paths\\\"] = {\\n        [1] = \\\"$EXTRA_DIR/\\\",\\n    },\\n}\\n\" > \"\$f\"
            return
        fi
        if ! grep -q \"$EXTRA_DIR\" \"\$f\"; then
            sed -i \"s|^}|    [\\\"extra_plugin_paths\\\"] = {\\n        [1] = \\\"$EXTRA_DIR/\\\",\\n    },\\n}|g\" \"\$f\"
        fi
    '"
}

echo "Using adb: $ADB $ADB_ARGS"
echo "Stopping $PKG"
"$ADB" $ADB_ARGS shell "am force-stop $PKG"

echo "-> $EXTRA_DEST"
"$ADB" $ADB_ARGS shell "run-as $PKG sh -c 'rm -rf $EXTRA_DEST && mkdir -p $EXTRA_DEST'"
tar -cf - -C "$PLUGIN_DIR" $FILES 2>/dev/null | "$ADB" $ADB_ARGS shell "run-as $PKG sh -c 'cd $EXTRA_DEST && tar -xf -'" >/dev/null 2>&1 || true

echo "Verifying checksums"
if ! verify_plugin "$EXTRA_DEST"; then
    echo "Checksum verification failed" >&2
    exit 1
fi

if [ "$ASSET_PLUGINS/stylus-annotations.koplugin" != "$EXTRA_DEST" ]; then
    "$ADB" $ADB_ARGS shell "run-as $PKG sh -c 'rm -rf $ASSET_DEST'" 2>/dev/null || true
fi

ensure_extra_plugin_paths

"$ADB" $ADB_ARGS logcat -c
"$ADB" $ADB_ARGS shell "am start -n $PKG/org.koreader.launcher.MainActivity"
sleep 16
"$ADB" $ADB_ARGS logcat -d | grep -iE "Looking for plugins|stylus|error|nil value" | tail -8 || true
echo "done"
