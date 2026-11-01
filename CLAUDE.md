# ha-tv-apps

Home Assistant apps (add-ons) for a Raspberry Pi connected to a TV. The repo root is
an HA app repository (`repository.yaml`) with two apps:

- `airplay_video/`: AirPlay screen-mirroring receiver (UxPlay) on the Pi's HDMI output
- `hdmi_cec/`: single owner of the Pi's HDMI-CEC adapter (volume keys → HA events,
  input switching for other apps)

Local test-box details (host, SSH user, other devices) are in `CLAUDE.local.md` and
`.env`, both gitignored. Nothing personal (names, IPs, hostnames) goes into tracked files.

## Layout

- `airplay_video/config.yaml`: app manifest (options schema, devices, host network)
- `airplay_video/Dockerfile`: Debian trixie + `uxplay` 1.71 + GStreamer
- `airplay_video/rootfs/run.sh`: starts D-Bus and Avahi, maps options to `uxplay` args
- `airplay_video/rootfs/etc/avahi/avahi-daemon.conf`: in-container mDNS
- `hdmi_cec/config.yaml`: app manifest (host network, `homeassistant_api`, `/dev/cec*`)
- `hdmi_cec/Dockerfile`: Alpine + python3; no other dependencies
- `hdmi_cec/rootfs/hdmi_cec.py`: the daemon (Linux CEC ioctls, HA events, HTTP API on
  127.0.0.1:8686)
- `<app>/DOCS.md`, `<app>/CHANGELOG.md`, `<app>/translations/en.yaml`, `<app>/icon.png`,
  `<app>/logo.png`: what the HA app store shows
- `scripts/deploy.sh <slug>`: copies an app to `/addons/<slug>` on the test box
- `scripts/ha.sh`: `ha` CLI and Supervisor API on the test box
  (`install|rebuild|update|start|stop|restart|logs|info <slug>`, `api METHOD PATH`)
- `.github/workflows/build.yaml`: builds and pushes the aarch64 images to GHCR

## Test box

- Pi 4 (4 GB), Home Assistant OS, kernel `6.12.x-haos-raspi`, HDMI-A-1 → Hisense 4K TV.
  Host in `.env` (`HA_HOST`, `HA_USER`).
- SSH as `$HA_USER` lands in the HA SSH app container (Alpine). It has passwordless sudo
  and `/addons`. The login shell has no Supervisor token (`ha` → unauthorized);
  `scripts/ha.sh` reads it from the app's s6 environment instead.
- Devices seen: `/dev/dri/card0` (v3d), `/dev/dri/card1` (vc4, the HDMI outputs),
  `renderD128`, `/dev/video10` (bcm2835-codec decode), `/dev/snd`, `/dev/cec0`.

## Loop

1. Local smoke test (the Mac's Docker is arm64): `docker build -t <slug>:dev <slug>`.
   For `airplay_video`, run it with a `/data/options.json` that uses `fakesink` for
   both sinks. `hdmi_cec` stops at opening `/dev/cec0` on the Mac.
2. `scripts/deploy.sh <slug>` (drops `image:` so the Supervisor builds locally).
3. `scripts/ha.sh store reload`, then `scripts/ha.sh install <slug>` the first time,
   `scripts/ha.sh rebuild <slug>` after that, or `scripts/ha.sh update <slug>` after a
   version bump. Then `scripts/ha.sh start <slug>` and `scripts/ha.sh logs <slug>`.
   Build errors are in `scripts/ha.sh supervisor logs`.
   (The user OK'd driving the `ha` CLI with the SSH app's Supervisor token.)
4. Mirror from the iPhone and check the TV; press the TV remote's volume keys.

## Gotchas

- `v4l2h264dec` only registers when a decoder device exists, so it's absent on the Mac.
- UxPlay's stdout is block-buffered without a TTY; `run.sh` wraps it in `stdbuf -oL`.
- Don't `grep -v ps` a process list here: `-fps` matches it.
- Supervisor 2026.10 ignores `build.yaml` and passes its Alpine base as `BUILD_FROM`,
  so the Dockerfile pins `FROM debian:trixie-slim` directly.
- The Supervisor must be up to date, or the store reload ("Check for updates") is
  blocked and local apps never appear.
- `ha apps logs` returns 100 lines by default; use `--lines N`. The `ha` CLI can't set
  app options: use `scripts/ha.sh api POST /addons/local_airplay_video/options`.
- Video pipeline lessons (Pi 4, vc4, HA OS 6.12):
  - Default decoder is software: `avdec_h264 thread-type=frame max-threads=$(nproc)`
    (~20% CPU on a Pi 4). Without frame threading avdec uses one core (live pipeline →
    slice threading, iOS sends one slice) and drops frames in complex landscape scenes.
  - The hardware decoder (`decoder: hardware`) is fine in landscape but holds back
    ~16 frames in portrait (no VUI `max_dec_frame_buffering` in iOS streams; DPB
    frame count grows as frames shrink): 300–900 ms late, ~95% of frames QoS-dropped.
  - `kmssink skip-vsync=true`: vc4 is atomic; without it every frame waits two vblanks
    (15 fps on the console's 3840x2160@30 mode).
  - Don't run with UxPlay `-d` when judging smoothness: per-packet logging drops frames.
    Use the `gst_debug` option (e.g. `2`) for GStreamer warnings alone.
  - `-bt709` is required with `v4l2h264dec`; iOS's full-range colorimetry is refused.
  - No `v4l2convert` (`-vc identity`): the ISP can't renegotiate on rotation.
  - No `force-modesetting`: it sets the mode to the frame size and the TV stretches it.
  - kmssink can't use the console's primary plane (page flip EINVAL unless full-screen),
    so `run.sh` blanks the console only while TCP 7100 has an ESTABLISHED socket: it
    zeroes `/dev/fb0` and hides the cursor, then repaints afterwards (DECSCNM toggle).
  - Console escapes go to `/dev/console`. `/dev/tty1` is EPERM even when listed under
    `devices:` or with `uart: true`; HAOS-kiosk uses `/dev/console` the same way.
- The app is meant to be published: no `full_access`/`privileged`. Keep it that way.
- `-p` pins the AirPlay ports; without it UxPlay uses random ones.
- HA's default audio output on the Pi is the 3.5 mm jack. The test box's app output is
  set to HDMI (`audio_output` via the options API); a default-to-HDMI is still to do.
- DRM content (Apple TV app, Netflix) only sends audio to non-certified receivers.
- UxPlay 1.71 segfaulted (exit 139) at the end of a session once; `run.sh` restarts it.
- HDMI-CEC (`/dev/cec0` is the TV's port; `cec-ctl` from `v4l-utils`):
  - vc4 CEC has one logical address, so the Pi is one device type at a time.
  - The HDMI-CEC app (`hdmi_cec/`) owns the adapter on the test box: it holds
    Audio System LA 5 for the TV's volume keys, in exclusive mode. `run.sh` asks it to
    switch the TV (`POST http://127.0.0.1:8686/active_source`) and only falls back to
    its own `cec-ctl` path when that API doesn't answer.
  - The Hisense TV wakes on `<Image View On>` from any LA, but ignores `<Active Source>`
    unless it comes from a playback LA, even from a CEC 2.0 LA that declares Playback in
    `all_device_types`. So both paths borrow the address: claim playback, send Active
    Source, then re-register the previous type/OSD name/vendor ID. The fallback must
    never otherwise reconfigure an adapter another client configured.
  - From standby the TV drops hot-plug while it boots, which takes the Pi's addresses
    away; the HDMI-CEC app waits for the TV to report On before switching. The
    fallback path doesn't, so it can miss the switch when the TV was off.
  - `cec-ctl` lists "Logical Addresses" twice (a bare capability, then the field);
    `cec_field` skips lines without a value.
- HDMI-CEC app:
  - The adapter is opened in exclusive initiator + follower mode, so `cec-ctl -s` from
    other clients gets EBUSY. The kernel core still answers Give Physical Address,
    OSD name, vendor ID and CEC version.
  - It retries opening the adapter on EBUSY: at boot, an older client may still hold it.
  - It replaced `cec_audio`, a custom integration that fired `cec_audio_command`.
