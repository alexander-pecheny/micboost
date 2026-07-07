#!/usr/bin/env bash
# micboost installer: build, install config, put micboostctl on PATH, load the launchd agent.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="me.pecheny.micboost"
DIR="$(pwd)"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/micboost"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINDIR="${BINDIR:-/opt/homebrew/bin}"

echo "==> checking BlackHole (virtual audio device)"
if ! ls /Library/Audio/Plug-Ins/HAL/ 2>/dev/null | grep -qi blackhole; then
  echo "!! BlackHole not found. Install it first:  brew install blackhole-2ch  (then log out/in)"
  exit 1
fi

echo "==> building micboost + micboostctl"
swiftc -O -framework AudioToolbox -framework CoreAudio -framework Foundation micboost.swift -o micboost
swiftc -O -framework CoreAudio -framework Foundation micboostctl.swift -o micboostctl

echo "==> installing config to $CFG_DIR/config (kept if it already exists)"
mkdir -p "$CFG_DIR"
[ -f "$CFG_DIR/config" ] || cp config.example "$CFG_DIR/config"

echo "==> linking micboostctl into $BINDIR"
ln -sf "$DIR/micboostctl" "$BINDIR/micboostctl"

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

echo "==> loading agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "==> done. Select 'BlackHole 2ch' as your mic in call apps. Tune with: micboostctl show"
