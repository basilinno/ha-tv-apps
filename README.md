# AirPlay Video Receiver for Home Assistant

A Home Assistant app (add-on) that turns a Raspberry Pi 4 or 5 running Home
Assistant OS into an AirPlay screen-mirroring receiver. Video and audio from an
iPhone, iPad or Mac show up on the TV connected to the Pi's HDMI port.

It wraps [UxPlay](https://github.com/FDH2/UxPlay), with GStreamer rendering
straight to the display (`kmssink`). No desktop or X server is needed.

## Status

Early development. Tested on a Pi 4 (4 GB) running HA OS 2026.6 with an iPhone:
portrait and landscape mirroring, rotation mid-session, letterboxing. The HA
console on the HDMI output is hidden while mirroring and comes back afterwards.

| | Pi 4 | Pi 5 |
|---|---|---|
| H.264 decode | software by default (~20% CPU); hardware optional | software (the Pi 5 has no H.264 block) |
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
| `decoder` | `software` | `software`: frame-threaded `avdec_h264`, smooth in portrait and landscape. `hardware`: the Pi 4's H.264 block; lighter on CPU but portrait drops most frames |
| `resolution` | `1920x1080` | Requested from the sender |
| `fps` | `30` | Maximum frame rate |
| `audio_sink` | `pulsesink` | Pick the HDMI output in the app's Audio settings |
| `extra_args` | | Passed through to `uxplay` |
| `debug` | `false` | UxPlay `-d` plus `GST_DEBUG=2` |
| `cec_switch_input` | `true` | Wake the TV and switch it to the Pi's input over HDMI-CEC when mirroring starts |
| `cec_device` | `/dev/cec0` | CEC adapter of the HDMI port the TV is on |

### HDMI-CEC

The Pi's CEC adapter has a single logical address. If nothing else uses it, the
app registers as a playback device. If another client already registered it
(e.g. an integration acting as an Audio System for the TV's volume keys), the
app leaves it in place and only borrows a playback address for the moment it
switches the TV's input, since many TVs ignore input switching from any other
device type.

## Development

See [CLAUDE.md](CLAUDE.md) for the build/deploy/test loop.

## Prior art

- [FD-/RPiPlay](https://github.com/FD-/RPiPlay): the original. It needs the legacy
  OpenMAX stack (`/opt/vc`), which HA OS doesn't ship.
- [DaCHack/uxplay-docker](https://github.com/DaCHack/uxplay-docker): UxPlay in
  plain Docker, `fbdevsink`, host Avahi.
- [Korkuttum/ha-uxplay-tv](https://github.com/Korkuttum/ha-uxplay-tv): an HA app
  that re-streams to DLNA TVs (not HDMI).
