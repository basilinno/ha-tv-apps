# AirPlay Video Receiver for Home Assistant

A Home Assistant app (add-on) that turns a Raspberry Pi 4 or 5 running Home
Assistant OS into an AirPlay screen-mirroring receiver. Video and audio from an
iPhone, iPad or Mac show up on the TV connected to the Pi's HDMI port.

It wraps [UxPlay](https://github.com/FDH2/UxPlay), with GStreamer rendering
straight to the display (`kmssink`). No desktop or X server is needed.

## Status

Early development. Tested on a Pi 4 (4 GB) running HA OS 2026.6.

| | Pi 4 | Pi 5 |
|---|---|---|
| H.264 decode | hardware (`bcm2835-codec`, `-v4l2`) or software | software only (the Pi 5 has no H.264 block) |
| Video output | `kmssink` on vc4 | `kmssink` on vc4 (untested) |

## Install

1. Settings → Apps → App store → ⋮ → Repositories → add this repository's URL.
2. Install **AirPlay Video Receiver** and start it.
3. On the iPhone: Control Centre → Screen Mirroring → pick the name you set.

## Options

| Option | Default | Notes |
|---|---|---|
| `name` | `AirPlay TV` | Name shown on Apple devices |
| `video_sink` | `kmssink` | `fbdevsink` is a fallback if KMS output misbehaves |
| `hardware_decode` | `true` | Uses the Pi 4's H.264 decoder when present |
| `resolution` | `1920x1080` | Requested from the sender |
| `fps` | `30` | Maximum frame rate |
| `audio_sink` | `pulsesink` | Pick the HDMI output in the app's Audio settings |
| `extra_args` | | Passed through to `uxplay` |
| `debug` | `false` | UxPlay `-d` plus `GST_DEBUG=2` |

## Development

See [CLAUDE.md](CLAUDE.md) for the build/deploy/test loop.

## Prior art

- [FD-/RPiPlay](https://github.com/FD-/RPiPlay): the original. It needs the legacy
  OpenMAX stack (`/opt/vc`), which HA OS doesn't ship.
- [DaCHack/uxplay-docker](https://github.com/DaCHack/uxplay-docker): UxPlay in
  plain Docker, `fbdevsink`, host Avahi.
- [Korkuttum/ha-uxplay-tv](https://github.com/Korkuttum/ha-uxplay-tv): an HA app
  that re-streams to DLNA TVs (not HDMI).
