# Home Assistant apps for the TV

Home Assistant apps (add-ons) for a Raspberry Pi running Home Assistant OS that is
plugged into a TV.

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fbasilinno%2Fha-tv-apps)

| App | What it does |
|---|---|
| [AirPlay Video Receiver](airplay_video/) | Mirror an iPhone, iPad or Mac to the TV over AirPlay. Video goes straight to the Pi's HDMI output; no desktop needed. |
| [HDMI-CEC](hdmi_cec/) | Talks to the TV over HDMI-CEC: turns the TV remote's volume keys into Home Assistant events, and switches the TV to the Pi's input when the AirPlay app starts mirroring. |

The two work on their own. Together, the HDMI-CEC app takes care of the TV and the
AirPlay app asks it to switch inputs.

## Install

1. Click the button above, or go to Settings → Apps → App store → ⋮ → Repositories
   and add `https://github.com/basilinno/ha-tv-apps`.
2. Install the apps you want from the store and start them.

Supported: Raspberry Pi 4 and 5 (`aarch64`) on Home Assistant OS.

## Development

See [CLAUDE.md](CLAUDE.md) for the build, deploy and test loop.
