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

## Tune it — `micboostctl`
Every change hot-restarts the agent so it applies immediately:

```sh
micboostctl show               # current settings
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

## Rebuild after editing micboost.swift
```sh
cd ~/micboost && swiftc -O -framework AudioToolbox -framework CoreAudio -framework Foundation micboost.swift -o micboost
launchctl kickstart -k gui/$(id -u)/me.pecheny.micboost
```

## How it works
Two AUHAL units (RODE in, BlackHole out) linked by a lock-free ring buffer; gain +
soft-knee compressor + safety limiter run per-sample in the input render callback.
CPU cost is a fraction of a percent. Config precedence: env var > config file > default.
