# micboost

A utility that boosts your microphone volume when it's too quiet.

Technically it is a headless Core Audio bridge: **mic → gain + compressor → BlackHole 2ch** that runs as an always-on `launchd` agent. To use the boosted mic, you need to pick **BlackHole 2ch** as your input device in e.g. Google Meet or Teams.

## Install

1. `brew install blackhole-2ch`
2. Restart
3. 
   ```sh
   git clone https://gitlab.com/alexander-pecheny/micboost.git
   cd micboost && ./install.sh
   ```

## Settings

Settings come in two flavors: `micboostmenu`, a menu-bar app, and `micboostctl` – terminal TUI/CLI (useful e.g. for agents).


## Useful commands
```sh
launchctl print gui/$(id -u)/me.pecheny.micboost   # status
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboost   # restart (after config/rebuild)
launchctl bootout gui/$(id -u)/me.pecheny.micboost        # stop + disable
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/me.pecheny.micboost.plist  # re-enable
tail -f /tmp/micboost.log                          # logs
```

## Rebuild after editing the Swift sources
```sh
cd ~/micboost
swiftc -O -framework AudioToolbox -framework CoreAudio -framework Foundation micboost.swift -o micboost
swiftc -O -framework CoreAudio -framework Foundation micboostctl.swift -o micboostctl   # the TUI/CLI
swiftc -O -framework Cocoa -framework SwiftUI -framework CoreAudio -framework Foundation micboostmenu.swift -o micboostmenu   # the menu-bar app
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboost          # restart the bridge
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboostmenu      # restart the menu-bar app
```
