<!--
Copyright (c) 2026 Basil Innovations LLC.
SPDX-License-Identifier: Apache-2.0
-->

# HDMI-CEC

Lets the Raspberry Pi talk to the TV over HDMI-CEC. The Pi's CEC adapter has a single
logical address, so one program should own it; this app is that owner, and other
apps and Home Assistant go through it.

It:

- registers with the TV as an **Audio System** (default) or a **Playback** device;
- turns the TV remote's **volume up / down / mute** keys into Home Assistant events;
- serves a small local API that can turn the TV on and off and switch it to the
  Pi's input; the AirPlay Video Receiver app uses it.

Only one program can use the adapter at a time. Turn off Home Assistant's built-in
`hdmi_cec` integration, or any other CEC integration, before starting this app;
otherwise the app logs `can't take /dev/cec0` and keeps retrying.

## Setup

1. Make sure HDMI-CEC is enabled in the TV's settings (brands call it Anynet+,
   Bravia Sync, SimpLink, CEC and so on).
2. Install and start the app. The log shows the address it got, for example
   `/dev/cec0: audio_system "Home Assistant", logical address 5, physical address 1.0.0.0`.
3. To use the volume keys, set the TV's sound output to the external audio system
   (often called ARC, HDMI audio or receiver), then add an automation like the one
   below.

## Volume keys

As an Audio System, the TV sends its volume keys to the Pi. Each press fires an event
on Home Assistant's bus:

```yaml
event_type: hdmi_cec_command
data:
  action: volume_up    # or volume_down, mute_toggle
```

Example automation that forwards them to a media player:

```yaml
alias: TV remote volume
triggers:
  - trigger: event
    event_type: hdmi_cec_command
actions:
  - choose:
      - conditions: "{{ trigger.event.data.action == 'volume_up' }}"
        sequence:
          - action: media_player.volume_up
            target:
              entity_id: media_player.living_room
      - conditions: "{{ trigger.event.data.action == 'volume_down' }}"
        sequence:
          - action: media_player.volume_down
            target:
              entity_id: media_player.living_room
      - conditions: "{{ trigger.event.data.action == 'mute_toggle' }}"
        sequence:
          - action: media_player.volume_mute
            target:
              entity_id: media_player.living_room
            data:
              is_volume_muted: "{{ not state_attr('media_player.living_room', 'is_volume_muted') }}"
mode: queued
```

The TV shows a volume bar that the app keeps moving on its own, in steps of 5; it
doesn't know the real volume of whatever the automation controls.

## Options

| Option | Default | Notes |
|---|---|---|
| `device` | `/dev/cec0` | CEC adapter of the HDMI port the TV is on (`/dev/cec1` for the second port of a Pi 4 or 5) |
| `device_type` | `audio_system` | `audio_system`: receives the volume keys. `playback`: a plain source device, no volume keys |
| `osd_name` | `Home Assistant` | Name the TV shows for the Pi (up to 14 characters) |
| `event_type` | `hdmi_cec_command` | Event type fired for the volume keys |
| `debug` | `false` | Log every CEC message sent and received |

## Local API

The app listens on `127.0.0.1:8686`, which only Home Assistant and other apps on the
host network can reach. Responses are JSON.

| Request | Effect |
|---|---|
| `GET /status` | adapter, device type, logical and physical address |
| `POST /tv/on` | wake the TV (`<Image View On>`) |
| `POST /tv/off` | put the TV in standby (`<Standby>`) |
| `POST /active_source` | wake the TV and switch it to the Pi's input |

`/active_source` waits (up to 20 s) for a TV that was off to finish starting, since
TVs ignore an input switch while they boot. Many TVs also ignore it unless it comes
from a playback device, so as an Audio System the app briefly registers as Playback
to send it, then registers as an Audio System again.

To call the API from Home Assistant, use a
[`rest_command`](https://www.home-assistant.io/integrations/rest_command/):

```yaml
rest_command:
  tv_on:
    url: http://127.0.0.1:8686/tv/on
    method: post
```

## Troubleshooting

- **`can't take /dev/cec0 ... Resource busy`:** another program holds the adapter,
  usually a CEC integration in Home Assistant. Remove it and restart Home Assistant.
- **The volume keys do nothing:** the TV only sends them to an audio system when its
  sound output is set to one. Set `debug: true` to see what the TV sends.
- **No physical address (`f.f.f.f`):** the TV is off or on a port without CEC; the
  app picks the address up as soon as the TV reports it.
