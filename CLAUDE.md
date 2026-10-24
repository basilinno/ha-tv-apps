# ha-airplay-video

A Home Assistant app (add-on) wrapping UxPlay. The repo root is an HA app
repository (`repository.yaml`); the app itself is `airplay_video/`.

## Layout

- `airplay_video/config.yaml`: app manifest (options schema, devices, host network)
- `airplay_video/Dockerfile`: Debian trixie + `uxplay` 1.71 + GStreamer
- `airplay_video/rootfs/run.sh`: starts D-Bus and Avahi, maps options to `uxplay` args
- `airplay_video/rootfs/etc/avahi/avahi-daemon.conf`: in-container mDNS
- `scripts/deploy.sh`: copies the app to `/addons/airplay_video` on the test box

## Test box

- `$HA_HOST` (set in `.env`): Pi 4 (4 GB), Home Assistant OS 2026.6, kernel `6.12.x-haos-raspi`,
  HDMI-A-1 → Hisense 4K TV.
- SSH as `$HA_USER` lands in the HA SSH app container (Alpine). It has passwordless sudo
  and `/addons`, but no Supervisor token (`ha` CLI → unauthorized).
- Devices seen: `/dev/dri/card0` (v3d), `/dev/dri/card1` (vc4, the HDMI outputs),
  `renderD128`, `/dev/video10` (bcm2835-codec decode), `/dev/snd`.
- Another Pi on the same LAN runs shairport-sync as
  AirPlay "stereo". Don't confuse the two.

## Loop

1. Local smoke test (the Mac's Docker is arm64):
   `docker build -t airplay_video:dev airplay_video` and run it with a
   `/data/options.json` that uses `fakesink` for both sinks.
2. `scripts/deploy.sh`
3. `scripts/ha.sh store reload`, then `scripts/ha.sh install` the first time, or
   `scripts/ha.sh rebuild` after that. Then `scripts/ha.sh start` and
   `scripts/ha.sh logs`. Build errors are in `scripts/ha.sh supervisor logs`.
   (The user OK'd driving the `ha` CLI with the SSH app's Supervisor token.)
4. Mirror from the iPhone and check the TV.

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
  - `-bt709` is required with `v4l2h264dec`; iOS's full-range colorimetry is refused.
  - No `v4l2convert` (`-vc identity`): the ISP can't renegotiate on rotation.
  - No `force-modesetting`: it sets the mode to the frame size and the TV stretches it.
  - kmssink can't use the console's primary plane (page flip EINVAL unless full-screen),
    so `run.sh` blanks the console (`/dev/fb0`, `/dev/tty1`) only while TCP 7100 has an
    ESTABLISHED socket, and repaints it afterwards (DECSCNM toggle).
- `-p` pins the AirPlay ports; without it UxPlay uses random ones.
- UxPlay 1.71 segfaulted (exit 139) at the end of a session once; `run.sh` restarts it.
