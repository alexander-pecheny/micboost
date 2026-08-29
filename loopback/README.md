# micboost loopback (experiment)

A two-channel virtual audio device: what is played to it comes back on its input. The point is to
find out whether micboost can ship its own loopback device instead of asking people to install
BlackHole. Nothing in micboost uses it yet, and `install.sh` does not touch it.

One sample rate (48 kHz), two channels, no mirrored device, no volume or mute controls, 582 lines.

The difference that matters is in the read path. BlackHole decides once per cycle whether anyone is
writing, from a single `lastOutputSampleTime` shared by every client, and a client that reads ahead
of the writer is served silence and clears the ring for everyone else. Here a reader is served the
overlap between what it asked for and what has actually been written, and zeros for the rest, so two
apps reading the device at once cannot silence each other.

```sh
./build.sh
sudo cp -R build/micboost-loopback.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
```

It appears as **micboost**, alongside BlackHole rather than in place of it. To remove:

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/micboost-loopback.driver && sudo killall coreaudiod
```
