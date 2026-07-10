# micboost

A utility that boosts your microphone volume when it's too quiet.

Technically it is a headless Core Audio bridge: **mic → high-pass → noise suppression → gain → compressor → limiter → BlackHole 2ch** that runs as an always-on `launchd` agent. To use the boosted mic, you need to pick **BlackHole 2ch** as your input device in e.g. Google Meet or Teams.

Latency added: **1.5 ms** normally, **17.5 ms** with noise suppression on.

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

## Noise suppression

Optional, off until you record a noise profile: stay silent for ~6 seconds while micboost averages the spectrum of your room (fans, laptop, street), then it subtracts that from every frame.

```sh
micboostctl nr capture    # stay silent; also switches NR on
micboostctl nr off        # back to raw
```

Or press **Capture noise profile** in the menu-bar app. Adds 16 ms of latency while active. Turn `NR_ALPHA` up (or `NR_FLOOR` down) in the config for more aggressive removal, at the cost of a watery/warbly artifact on speech.


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
swiftc -O -framework AudioToolbox -framework CoreAudio -framework Accelerate -framework Foundation micboost.swift -o micboost
swiftc -O -framework CoreAudio -framework Foundation micboostctl.swift -o micboostctl   # the TUI/CLI
swiftc -O -framework Cocoa -framework SwiftUI -framework CoreAudio -framework Foundation micboostmenu.swift -o micboostmenu   # the menu-bar app
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboost          # restart the bridge
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboostmenu      # restart the menu-bar app
```
