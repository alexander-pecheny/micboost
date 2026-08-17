#!/usr/bin/env bash
# micboost installer: build, install config, put micboostctl on PATH, load the launchd agent.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="me.pecheny.micboost"
MENU_LABEL="me.pecheny.micboostmenu"
DIR="$(pwd)"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/micboost"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MENU_PLIST="$HOME/Library/LaunchAgents/$MENU_LABEL.plist"
BINDIR="${BINDIR:-/opt/homebrew/bin}"
APP="/Applications/micboost.app"
APP_ID="me.pecheny.micboost.menu"

echo "==> checking BlackHole (virtual audio device)"
if ! ls /Library/Audio/Plug-Ins/HAL/ 2>/dev/null | grep -qi blackhole; then
  echo "!! BlackHole not found. Install it first:  brew install blackhole-2ch  (then log out/in)"
  exit 1
fi

echo "==> building micboost + micboostctl + micboostmenu + micrec"
swiftc -O -framework AudioToolbox -framework CoreAudio -framework Accelerate -framework Foundation micboost.swift -o micboost
swiftc -O -framework CoreAudio -framework Foundation micboostctl.swift -o micboostctl
swiftc -O -framework Cocoa -framework SwiftUI -framework CoreAudio -framework Foundation micboostmenu.swift -o micboostmenu
swiftc -O -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework AppKit -framework Foundation micrec.swift -o micrec

echo "==> installing config to $CFG_DIR/config (kept if it already exists)"
mkdir -p "$CFG_DIR"
[ -f "$CFG_DIR/config" ] || cp config.example "$CFG_DIR/config"

echo "==> installing $APP"
if [ -d "$APP" ] && [ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$APP_ID" ]; then
  echo "!! $APP exists and is not ours — leaving it alone"
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp micboostmenu micrec "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>micboost</string>
    <key>CFBundleIdentifier</key><string>$APP_ID</string>
    <key>CFBundleExecutable</key><string>micboostmenu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>micboost records the microphone you select.</string>
</dict>
</plist>
EOF
touch "$APP"

echo "==> linking micboostctl + micrec into $BINDIR"
ln -sf "$DIR/micboostctl" "$BINDIR/micboostctl"
ln -sf "$DIR/micrec" "$BINDIR/micrec"

echo "==> recordings go to $HOME/Documents/MicboostRecordings"
mkdir -p "$HOME/Documents/MicboostRecordings"

echo "==> writing launchd agent $PLIST"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DIR/micboost</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/tmp/micboost.log</string>
    <key>StandardErrorPath</key><string>/tmp/micboost.log</string>
</dict>
</plist>
EOF

echo "==> writing menu-bar login agent $MENU_PLIST"
# KeepAlive is deliberately off: Quit should quit. It still starts at login, and the app sits in
# /Applications so it can be started again by hand.
cat > "$MENU_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$MENU_LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/micboostmenu</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>/tmp/micboostmenu.log</string>
    <key>StandardErrorPath</key><string>/tmp/micboostmenu.log</string>
</dict>
</plist>
EOF

echo "==> loading agents"
# launchd reports EIO if we bootstrap while the old job is still winding down, so retry briefly
reload() {
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    launchctl bootstrap "gui/$(id -u)" "$2" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "!! could not load $1"
}
reload "$LABEL" "$PLIST"
reload "$MENU_LABEL" "$MENU_PLIST"

echo "==> done. Select 'BlackHole 2ch' as your mic in call apps — micboost switches itself on."
echo "    A 🎙 icon is now in your menu bar: micboost settings and Recording."
echo "    Quit really quits; start it again from $APP."
echo "    (Prefer the terminal? micboostctl show / micrec --help)"
