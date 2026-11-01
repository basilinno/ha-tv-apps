<!--
Copyright (c) 2026 Basil Innovations LLC.
SPDX-License-Identifier: Apache-2.0
-->

# AirPlay Video Receiver

Mirror an iPhone, iPad or Mac to the TV connected to the Raspberry Pi's HDMI port.
The app runs [UxPlay](https://github.com/FDH2/UxPlay) and renders with GStreamer
straight to the display (`kmssink`), so no desktop or X server is needed. While a
mirroring session is open, the Home Assistant console on the HDMI output is hidden;
it comes back when the session ends.

## Requirements

- Raspberry Pi 4 running Home Assistant OS, with the TV on an HDMI port. The Pi 5
  should work but hasn't been tested yet.
- The Apple device on the same network as the Pi (AirPlay is found over mDNS).

| | Pi 4 (tested) | Pi 5 (untested) |
|---|---|---|
| H.264 decode | software by default (~20% CPU); hardware optional | software (the Pi 5 has no H.264 decoder) |
| Video output | `kmssink` on vc4 | `kmssink` on vc4 |

## Setup

1. Install and start the app.
2. **Audio:** on the app's page, open the **Audio** settings and pick the HDMI
   output (on a Pi 4: `alsa_output.platform-fef00700.hdmi.hdmi-stereo`). Home
   Assistant's default is the headphone jack, so without this the TV stays silent.
3. On the iPhone: Control Centre → Screen Mirroring → pick the name you set
   (`AirPlay TV` by default).

## Options

| Option | Default | Notes |
|---|---|---|
| `name` | `AirPlay TV` | Name shown on Apple devices |
| `video_sink` | `kmssink` | `fbdevsink` is a fallback if KMS output misbehaves |
| `decoder` | `software` | `software`: frame-threaded `avdec_h264`, smooth in portrait and landscape. `hardware`: the Pi 4's H.264 decoder; lighter on CPU, but portrait drops most frames |
| `resolution` | `1920x1080` | Requested from the sender |
| `fps` | `30` | Maximum frame rate |
| `audio_sink` | `pulsesink` | `pulsesink` follows the app's Audio setting |
| `extra_args` | | Passed through to `uxplay` |
| `debug` | `false` | UxPlay `-d` plus `GST_DEBUG=2`. Very verbose; it makes the video stutter |
| `gst_debug` | | GStreamer log level on its own, e.g. `2` for warnings |
| `cec_switch_input` | `true` | Wake the TV and switch it to the Pi's input over HDMI-CEC when mirroring starts |
| `cec_device` | `/dev/cec0` | CEC adapter of the HDMI port the TV is on |

## Switching the TV's input (HDMI-CEC)

With `cec_switch_input` on, starting a mirroring session wakes the TV and switches it
to the Pi.

- **With the HDMI-CEC app installed** (recommended), the AirPlay app asks it to do
  the switch. It waits for a TV that was off to finish starting before switching.
- **On its own**, the AirPlay app sends the CEC messages itself. This works when the
  TV is already on; from standby, some TVs ignore the switch.

Many TVs ignore input switching unless it comes from a playback device. The Pi's
CEC adapter has a single address, so if something else registered it (for example
as an Audio System for the volume keys), the switch briefly borrows a playback
address and then restores the original one.

## Limitations

- **DRM-protected video** (the Apple TV app, Netflix and other streaming apps) is
  only sent as **audio** to receivers that aren't Apple-certified. Screen mirroring,
  photos and non-protected video work.
- One mirroring session at a time.
- The TV is driven in the display mode the Home Assistant console set up (on a 4K
  TV this is often 3840x2160 at 30 Hz); the picture is scaled to fit.

## Troubleshooting

- **No sound on the TV:** pick the HDMI output in the app's Audio settings (see
  Setup).
- **The receiver doesn't show up on the iPhone:** check that both are on the same
  network and that mDNS isn't blocked between them (guest networks, VLANs, client
  isolation).
- **Stutter or dropped frames:** leave `debug` off, and use `gst_debug: 2` to see
  GStreamer warnings. Keep `decoder: software` for portrait content.
- **The TV doesn't switch input:** check that HDMI-CEC is enabled in the TV's
  settings (brands call it Anynet+, Bravia Sync, SimpLink, CEC and so on), and look
  for `cec:` lines in the app's log.

## Credits

[UxPlay](https://github.com/FDH2/UxPlay) does the AirPlay work. Earlier projects:
[RPiPlay](https://github.com/FD-/RPiPlay) (needs the legacy OpenMAX stack, which
HA OS doesn't ship), [uxplay-docker](https://github.com/DaCHack/uxplay-docker) and
[ha-uxplay-tv](https://github.com/Korkuttum/ha-uxplay-tv) (re-streams to DLNA TVs).
