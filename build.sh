#!/bin/sh
# Builds Spoco.app (universal: Apple silicon + Intel) and dist/Spoco-macOS.zip.
# Needs only the Xcode command line tools: xcode-select --install
# Set SPOCO_VERSION to stamp a version (default 0.0.0).
set -eu
cd "$(dirname "$0")"

VERSION="${SPOCO_VERSION:-0.0.0}"
APP=Spoco.app
BUILD=build

rm -rf "$APP" "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13" -o "$BUILD/Spoco-$arch" Spoco.swift
done
lipo -create -output "$APP/Contents/MacOS/Spoco" "$BUILD/Spoco-arm64" "$BUILD/Spoco-x86_64"

# App icon from the logo.
ICONSET="$BUILD/Spoco.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256; do
    sips -z $size $size docs/logo.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128; do
    double=$((size * 2))
    sips -z $double $double docs/logo.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/Spoco.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.liekki.spoco</string>
    <key>CFBundleName</key><string>Spoco</string>
    <key>CFBundleDisplayName</key><string>Spoco</string>
    <key>CFBundleExecutable</key><string>Spoco</string>
    <key>CFBundleIconFile</key><string>Spoco</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Spoco sends play/pause, next and previous to Spotify when you press its hotkeys.</string>
</dict>
</plist>
EOF

# Ad-hoc signature: required to run on Apple silicon, and lets the "control Spotify" permission stick.
codesign --force --sign - "$APP"

rm -f dist/Spoco-macOS.zip
ditto -c -k --keepParent "$APP" dist/Spoco-macOS.zip
echo "Built $APP and dist/Spoco-macOS.zip ($VERSION)"
