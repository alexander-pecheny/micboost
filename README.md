> **The main repository of this project lives at https://code.pecheny.me/pecheny/micboost. All issues should be created there.**

# micboost

Two tools behind one menu-bar icon: a microphone booster and a recorder.

**micboost** boosts your microphone when it's too quiet. Technically it is a headless Core Audio bridge: **mic → high-pass → noise suppression → gain → compressor → limiter → BlackHole 2ch** running as a `launchd` agent. Pick **BlackHole 2ch** as your input device in Meet or Teams and the bridge switches itself on; pick anything else and it switches off.

Latency added: **1.5 ms** normally, **17.5 ms** with noise suppression on.

If the mic disappears, which a USB receiver can do by re-enumerating itself mid-call, micboost quits and launchd starts it again on the device that came back. The gap is a second or two instead of the rest of the call.

**micrec** records your mic together with any app or the whole system, as separate stems that cannot drift apart. See [Recording](#recording).

## Install

1. `brew install blackhole-2ch`
2. Restart
3. 
   ```sh
   git clone https://code.pecheny.me/pecheny/micboost
   cd micboost && ./install.sh
   ```

The installer puts **micboost.app** in `/Applications`. It starts at login and lives in the menu bar with no Dock icon. **Quit** quits it for good — nothing relaunches it — so start it again from `/Applications` when you want it back. Only one copy ever runs.

## Settings

Settings come in two flavors: micboost.app, the menu-bar app, and `micboostctl` – terminal TUI/CLI (useful e.g. for agents).

## Noise suppression

Optional, off until you record a noise profile: stay silent for ~6 seconds while micboost averages the spectrum of your room (fans, laptop, street), then it subtracts that from every frame.

```sh
micboostctl nr capture    # stay silent; also switches NR on
micboostctl nr off        # back to raw
```

Or press **Capture noise profile** in the menu-bar app. Adds 16 ms of latency while active. Turn `NR_ALPHA` up (or `NR_FLOOR` down) in the config for more aggressive removal, at the cost of a watery/warbly artifact on speech.


## Recording

Open the menu-bar icon, expand **Recording**, tick what you want, press Record. Sources are your current mic, the whole system output, and every running app; the search box filters them, and the list refreshes while it is open. An app can only be tapped once it has opened an audio stream, so the ones that never have are listed greyed out — apps that play sound, like a browser or Slack, are selectable even while silent. Recordings land in `~/Documents/MicboostRecordings/<timestamp>/` as one stem per source plus a downmix.

Three design choices do the heavy lifting:

- **Stems cannot drift.** Every source joins a single private aggregate device, so one Core Audio callback delivers all of them and each stem is written from the same buffer. There is no alignment step to get wrong, and none to fix afterwards.
- **The call app keeps the device to itself.** When micboost is bridging your mic into BlackHole, the mic stem is a tap on micboost's own output, not a second opening of BlackHole. Whatever is on the call stays the only client reading that device, and the tap carries the same processed audio.
- **A crash cannot cost you the recording.** Capture writes float32 CAF files whose data chunk is left open-ended, so a half-written file is a valid file. `kill -9` mid-call loses at most one 50 ms writer tick, and everything already on disk plays. A low-priority thread encodes the stems and the mix as the raw files grow, so a take is ready moments after it stops; the raw capture is deleted only once every output has been read back and verified.

The mix is summed at unity gain and soft-clipped above -2.5 dBFS, because normalising it would mean waiting for the whole take. When a take matters enough for an exact mix, the lossless stems are there to re-mix from.

If a recording is ever interrupted, `micrec recover` finishes it. The menu-bar app runs that at login.

```sh
micrec sources                        # what can be recorded right now
micrec start --source mic --source app:org.mozilla.firefox --format flac
micrec status
micrec stop
micrec recover                        # finish anything left half-written
```

The format applies to the mix: `flac` (lossless, 24-bit) or `aac` (variable bit rate, tuned for speech). Stems are always FLAC. Both encode through Apple's frameworks, so there is nothing else to install.

The recorder runs as its own process. Quitting or crashing the menu-bar app does not touch a recording in progress.

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
swiftc -O -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework AppKit -framework Foundation micrec.swift -o micrec   # the recorder
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboost          # restart the bridge
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboostmenu      # restart the menu-bar app
```
