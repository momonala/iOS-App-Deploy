#!/usr/bin/env bash
#
# Build Redeploy.app, sign it, install it to ~/Applications and relaunch it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Redeploy.app"
INSTALLED="$HOME/Applications/Redeploy.app"

cd "$ROOT"
swift build -c release --product Redeploy
BIN="$(swift build -c release --show-bin-path)/Redeploy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Redeploy"

cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Redeploy</string>
    <key>CFBundleIdentifier</key><string>mnalavadi.Redeploy</string>
    <key>CFBundleName</key><string>Redeploy</string>
    <key>CFBundleDisplayName</key><string>iOS App Deploy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>RedeployRoot</key><string>$ROOT</string>
</dict>
</plist>
EOF

# iconutil only accepts a directory whose name ends in exactly ".iconset".
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

# A stable identity keeps the notification permission and the login item across rebuilds; an
# ad-hoc signature changes with every build, so macOS treats each one as a new app.
identity="$(security find-identity -v -p codesigning | grep -v REVOKED | grep -m1 'Apple Development' | awk '{print $2}' || true)"
if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" "$APP"
else
    echo "warning: no Apple Development identity, signing ad-hoc" >&2
    codesign --force --sign - "$APP"
fi

pkill -x Redeploy 2>/dev/null || true
# open fails with -600 while the old instance is still shutting down.
while pgrep -x Redeploy >/dev/null; do sleep 0.2; done
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED" 2>/dev/null || { sleep 1; open "$INSTALLED"; }
echo "installed $INSTALLED"
