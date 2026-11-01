# HDMI-CEC for Home Assistant

A Home Assistant app that owns the Raspberry Pi's HDMI-CEC adapter (`/dev/cec0`).
The Pi's CEC adapter has a single logical address, so one client should hold it;
this app is that client.

- Registers as an **Audio System** (default) or a **Playback** device.
- Turns the TV remote's volume keys into Home Assistant events:
  `hdmi_cec_command` with `action: volume_up | volume_down | mute_toggle`
  (the event type is an option).
- Serves an HTTP API on `127.0.0.1:8686`, reachable from Home Assistant Core and
  other host-network apps (such as the AirPlay Video Receiver):

  | Request | Effect |
  |---|---|
  | `GET /status` | adapter state |
  | `POST /tv/on` | `<Image View On>` |
  | `POST /tv/off` | `<Standby>` |
  | `POST /active_source` | wake the TV and switch it to the Pi's input |

  Some TVs ignore `<Active Source>` unless it comes from a playback address; as an
  Audio System the app briefly re-registers as Playback to send it.

From Home Assistant, use a `rest_command`:

```yaml
rest_command:
  tv_on:
    url: http://127.0.0.1:8686/tv/on
    method: post
  tv_off:
    url: http://127.0.0.1:8686/tv/off
    method: post
```

Example automation for the volume keys:

```yaml
- alias: TV volume keys
  trigger:
    - platform: event
      event_type: hdmi_cec_command
  action:
    - choose:
        - conditions: "{{ trigger.event.data.action == 'volume_up' }}"
          sequence:
            - action: media_player.volume_up
              target: { entity_id: media_player.living_room }
```
