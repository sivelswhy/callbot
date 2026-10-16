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
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>PhoneBT se connecte à ton téléphone en Bluetooth (profil mains-libres) pour passer et recevoir des appels.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>PhoneBT capte le son de l'appel joué par le Mac pour que l'agent IA entende l'interlocuteur.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>PhoneBT écoute l'audio de l'appel pour que l'agent IA entende l'interlocuteur.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>PhoneBT transcrit localement ce que dit l'interlocuteur pour l'agent IA.</string>
</dict>
</plist>
PLIST

# Files under ~/Documents carry extended attributes that break codesign
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "✅ $APP prête — lance-la avec : open $APP"
