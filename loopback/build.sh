#!/usr/bin/env bash
# Build micboost-loopback.driver. Installing it needs sudo and a coreaudiod restart:
#   sudo cp -R build/micboost-loopback.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
# Removing it is the same in reverse:
#   sudo rm -rf /Library/Audio/Plug-Ins/HAL/micboost-loopback.driver && sudo killall coreaudiod
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE=build/micboost-loopback.driver
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>micboost loopback</string>
    <key>CFBundleIdentifier</key><string>me.pecheny.micboost.loopback</string>
    <key>CFBundleExecutable</key><string>loopback</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFPlugInFactories</key>
    <dict>
        <key>CB51F60E-B65C-48E6-B909-BDF2E917A61C</key><string>micboostLoopbackCreate</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array><string>CB51F60E-B65C-48E6-B909-BDF2E917A61C</string></array>
    </dict>
</dict>
</plist>
PLIST

clang -O2 -Wall -Wextra -std=gnu11 -bundle \
    -framework CoreFoundation -framework CoreAudio \
    loopback.c -o "$BUNDLE/Contents/MacOS/loopback"
codesign --force --sign - "$BUNDLE"
echo "built $BUNDLE"
