#!/bin/bash
# Build PhoneBT.app (SwiftUI Mac app) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PhoneBTApp
BIN="$(swift build -c release --show-bin-path)/PhoneBTApp"

APP="build/PhoneBT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhoneBT"

# App icon: render the PNG if missing, then build the .icns with every required size
[ -f Support/AppIcon.png ] || swift scripts/make-icon.swift Support/AppIcon.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Support/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Support/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Permission prompts in English and French
cp -R Support/en.lproj Support/fr.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.phonebt.app</string>
    <key>CFBundleName</key><string>PhoneBT</string>
    <key>CFBundleDisplayName</key><string>PhoneBT</string>
    <key>CFBundleExecutable</key><string>PhoneBT</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>PhoneBT connects to your phone over Bluetooth (hands-free profile) to place and receive calls.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>PhoneBT captures the call audio played by the Mac so the AI agent can hear the caller.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>PhoneBT listens to the call audio so the AI agent can hear the caller.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>PhoneBT transcribes what the caller says, locally, for the AI agent.</string>
</dict>
</plist>
PLIST

# Files under ~/Documents carry extended attributes that break codesign
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "✅ $APP ready — launch it with: open $APP"
