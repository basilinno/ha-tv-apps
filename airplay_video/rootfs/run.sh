#!/usr/bin/env bash
# Entry point: start D-Bus + Avahi for mDNS, then exec UxPlay with options
# from the app's Configuration tab (/data/options.json).
set -euo pipefail

OPTIONS=/data/options.json
opt() { jq -r --arg k "$1" '.[$k] // empty' "$OPTIONS"; }

log() { echo "[airplay_video] $*"; }

NAME="$(opt name)"
VIDEO_SINK="$(opt video_sink)"
HW_DECODE="$(opt hardware_decode)"
RESOLUTION="$(opt resolution)"
FPS="$(opt fps)"
AUDIO_SINK="$(opt audio_sink)"
EXTRA_ARGS="$(opt extra_args)"
DEBUG="$(opt debug)"

log "uxplay $(dpkg-query -W -f='${Version}' uxplay 2>/dev/null || echo '?')"

# --- mDNS ---------------------------------------------------------------
# UxPlay registers its _airplay/_raop services through Avahi over D-Bus.
mkdir -p /run/dbus
rm -f /run/dbus/pid /run/dbus/system_bus_socket
dbus-daemon --system --fork
# Run Avahi in the background (not --daemonize) so its messages reach the app log.
AVAHI_ARGS=(--no-drop-root --no-chroot)
[[ "$DEBUG" == "true" ]] && AVAHI_ARGS+=(--debug)
avahi-daemon "${AVAHI_ARGS[@]}" 2>&1 | sed -u 's/^/[avahi] /' &
for _ in $(seq 1 20); do
    avahi-daemon --check 2>/dev/null && break
    sleep 0.25
done
avahi-daemon --check || { log "avahi-daemon failed to start"; exit 1; }

# --- video ----------------------------------------------------------------
# HA OS shows its text console on the HDMI output, and kmssink draws on an
# overlay plane above it, so the console shows around a letterboxed frame.
# The console's primary plane can't take the video instead (the vc4 driver
# rejects a primary-plane page flip smaller than the screen: EINVAL), so while
# a mirroring session is open the console's framebuffer is painted black and
# its cursor hidden. Afterwards the console is asked to repaint itself, so its
# text is not lost.
console_write() {
    [[ -w /dev/tty1 ]] && printf '%b' "$1" > /dev/tty1 2>/dev/null || true
}
blank_console() {
    console_write '\033[?25l'
    [[ -w /dev/fb0 ]] && { cat /dev/zero > /dev/fb0; } 2>/dev/null || true
}
restore_console() {
    # Show the cursor, then toggle reverse video (DECSCNM) on and off, which
    # makes fbcon redraw the whole screen from the VT's text buffer.
    console_write '\033[?25h\033[?5h\033[?5l'
}

# UxPlay's mirroring video arrives on TCP 7100 (0x1BBC); an ESTABLISHED (01)
# socket there means a session is on screen. Audio-only AirPlay doesn't use it.
mirroring_active() {
    grep -qsE '^ *[0-9]+: [0-9A-F]+:1BBC [0-9A-F]+:[0-9A-F]+ 01 ' /proc/net/tcp /proc/net/tcp6
}
watch_console() {
    local blanked=false
    restore_console
    while sleep 1; do
        if mirroring_active; then
            [[ "$blanked" == false ]] && { blank_console; blanked=true; log "mirroring started: console blanked"; }
        elif [[ "$blanked" == true ]]; then
            restore_console; blanked=false; log "mirroring stopped: console restored"
        fi
    done
}

case "$VIDEO_SINK" in
    # No force-modesetting: keep the console's display mode and let the vc4
    # plane scaler letterbox the frame. Modesetting to the frame size made the
    # TV stretch portrait (498x1080) streams across the whole screen.
    kmssink)   VS="kmssink driver-name=vc4" ;;
    fbdevsink) VS="fbdevsink device=/dev/fb0" ;;
    *)        VS="$VIDEO_SINK" ;;
esac

# -p: fixed legacy AirPlay ports (TCP 7000,7001,7100; UDP 6000,6001,7011)
# instead of random ones, so firewalls and watch_console can rely on them.
ARGS=(-n "$NAME" -nh -p -s "$RESOLUTION" -fps "$FPS" -vs "$VS" -as "$AUDIO_SINK")

# Pi 4 has a stateful H.264 decoder (bcm2835-codec); Pi 5 has none.
if [[ "$HW_DECODE" == "true" ]]; then
    if grep -qs "bcm2835-codec-decode" /sys/class/video4linux/video*/name; then
        # -bt709: iOS tags streams as full-range (colorimetry 1:3:7:1), which
        # v4l2h264dec on the Pi 4 refuses with "not-negotiated".
        # No v4l2convert (what -v4l2 adds): the ISP can't renegotiate when the
        # sender rotates (e.g. 498x1080 -> 1920x884), which kills the stream.
        # The vc4 planes scale the decoder's YUV output directly.
        ARGS+=(-vd v4l2h264dec -vc identity -bt709)
        log "hardware H.264 decode: bcm2835-codec"
    else
        log "hardware H.264 decode requested but no bcm2835-codec decoder found; using software"
    fi
fi

if [[ "$DEBUG" == "true" ]]; then
    ARGS+=(-d)
    export GST_DEBUG="${GST_DEBUG:-2}"
fi

if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206 # word-splitting is intended
    ARGS+=($EXTRA_ARGS)
fi

watch_console &

# UxPlay 1.71 has been seen to segfault (exit 139) when a session ends; keep
# the receiver available by restarting it, instead of leaving the app dead.
UXPLAY_PID=
trap '[[ -n "$UXPLAY_PID" ]] && kill -TERM "$UXPLAY_PID" 2>/dev/null; exit 0' TERM INT
while true; do
    log "start uxplay ${ARGS[*]}"
    # Line-buffer stdout so UxPlay's output reaches the app log without a TTY.
    stdbuf -oL -eL uxplay "${ARGS[@]}" &
    UXPLAY_PID=$!
    status=0
    wait "$UXPLAY_PID" || status=$?
    log "uxplay exited with status $status; restarting in 2s"
    sleep 2
done
