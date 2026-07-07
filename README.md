# micboost

Headless Core Audio bridge: **RODE Wireless Micro → gain + compressor → BlackHole 2ch**.
Runs as an always-on `launchd` agent (no GUI, ~0% CPU). Pick **BlackHole 2ch** as your mic
in Zoom/Meet/Teams/etc. — that's the only manual step.

macOS greys out the input-gain slider for the RODE Wireless Micro (it reports a fixed USB
output level), so there's no native way to make it louder. This inserts a gain + compressor
stage between the mic and your call app via a virtual device, with none of the
Audio-Hijack/Loopback ceremony.

## Install
Requires [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole): `brew install blackhole-2ch` (then log out/in).

```sh
git clone https://gitlab.com/alexander-pecheny/micboost.git
cd micboost && ./install.sh
```

## Tune it — menu bar or terminal
Two front-ends, same job (edit `~/.config/micboost/config` and hot-restart the agent). Pick either.

### `micboostmenu` — menu-bar app
A 🎙 icon sits in the menu bar (installed as a login agent, so it comes back after reboot).
Click it for a panel: pick the input mic / output device from the ones currently connected,
drag the gain slider, toggle the compressor, expand **Advanced** for threshold / ratio / makeup
/ attack / release, then hit **Apply** to save + restart the bridge. **Restart** re-applies
without changes, **Log…** opens the log in Console.

### `micboostctl` — terminal TUI/CLI
Run it with **no arguments** for an interactive TUI: arrow keys to move, `enter` to pick the
input mic / output device from the ones currently connected, `←/→` to nudge gain, `space` to
toggle the compressor, `a` to apply (hot-restarts the agent), `q` to quit.

```
  micboost  · device routing & tuning

   ▸ Input  (mic to boost)  Wireless MICRO
     Output (virtual mic)   BlackHole 2ch
     Gain                   12 dB
     Compressor             on
```

Every CLI subcommand still works for scripting; each hot-restarts the agent immediately:

```sh
micboostctl                    # launch the TUI
micboostctl devices            # list live input/output devices
micboostctl show               # current settings
micboostctl input "Wireless"   # pick input mic  (substring match)
micboostctl output BlackHole   # pick output device
micboostctl gain 15            # absolute pre-boost, dB
micboostctl gain +3            # nudge relative
micboostctl comp off           # pure boost, no compression
micboostctl ratio 3            # gentler compression
micboostctl threshold -20      # compress sooner/later
micboostctl makeup 8           # post-compressor makeup gain
micboostctl set KEY VALUE      # any raw key
micboostctl status | log       # launchd status / tail log
```

Too quiet still? Raise `gain`. Voice pumping/uneven? Lower `ratio` or raise `threshold`.
Or edit `~/.config/micboost/config` by hand and `micboostctl restart`.

## Control
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

## How it works
Two AUHAL units (RODE in, BlackHole out) linked by a lock-free ring buffer; gain +
soft-knee compressor + safety limiter run per-sample in the input render callback.
CPU cost is a fraction of a percent. Config precedence: env var > config file > default.
