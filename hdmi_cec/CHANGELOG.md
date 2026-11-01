# Changelog

## 0.2.0

- Prebuilt image: installing no longer builds on the Pi.
- Documentation, icon and option descriptions for the app store.

## 0.1.1

- Wait for a TV that was off to finish starting before switching its input, and
  answer its request for the active source afterwards.
- Keep retrying when another program still holds the CEC adapter, instead of
  exiting.

## 0.1.0

- First version: owns the CEC adapter as an Audio System or Playback device, fires
  Home Assistant events for the TV's volume keys, local API for TV on/off and input
  switching.
