# Changelog

## 0.5.0

- Prebuilt image: installing no longer builds on the Pi.
- Documentation, icon and option descriptions for the app store.

## 0.4.0

- Switch the TV's input through the HDMI-CEC app when it's installed; fall back to
  sending the CEC messages directly when it isn't.

## 0.3.3

- Switch the TV's input even when another client holds the CEC adapter as an Audio
  System, by briefly borrowing a playback address.

## 0.3.2

- Don't take over a CEC adapter that another client configured.

## 0.3.1

- Log the CEC adapter's driver and how many logical addresses it has.

## 0.3.0

- Wake the TV and switch it to the Pi's HDMI input over CEC when mirroring starts
  (`cec_switch_input`, `cec_device`).

## 0.2.0

- Smooth playback: frame-threaded software H.264 decoding by default,
  `kmssink skip-vsync`, hardware decoding as an option.
- Hide the Home Assistant console while mirroring and restore it afterwards.
- Restart UxPlay if it exits.

## 0.1.9

- First working version: AirPlay mirroring with UxPlay on the Pi's HDMI output.
