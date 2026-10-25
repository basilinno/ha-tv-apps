# ha-hdmi-cec

A Home Assistant app that is the single owner of the Pi's HDMI-CEC adapter
(issue #6). The repo root is an HA app repository; the app is
`hdmi_cec/`.

## Layout

- `hdmi_cec/config.yaml`: app manifest (host network, `homeassistant_api`, `/dev/cec*`)
- `hdmi_cec/Dockerfile`: Alpine + python3; no other dependencies
- `hdmi_cec/rootfs/hdmi_cec.py`: the daemon (Linux CEC ioctls, HA events, HTTP API on
  127.0.0.1:8686)
- `scripts/deploy.sh`, `scripts/ha.sh`: same as in ha-airplay-video, for `local_hdmi_cec`

## Notes

- Test box, SSH and Supervisor-token details: see ha-airplay-video's CLAUDE.md.
- The adapter is opened in exclusive initiator + follower mode, so `cec-ctl -s` from
  other clients gets EBUSY. The kernel core still answers Give Physical Address,
  OSD name, vendor ID and CEC version.
- The AirPlay app calls `POST /active_source` and falls back to its own `cec-ctl`
  path when the API isn't there.
- It replaces `cec_audio`, the custom integration in `/config/custom_components`,
  which fired `cec_audio_command`. On the test box `event_type` is set to
  `cec_audio_command` so the existing DSP automation keeps working.
