#!/usr/bin/env bash
# Entry point: start D-Bus + Avahi for mDNS, then run UxPlay with options
# from the app's Configuration tab (/data/options.json).
set -euo pipefail

OPTIONS=/data/options.json
opt() { jq -r --arg k "$1" '.[$k] // empty' "$OPTIONS"; }

log() { echo "[airplay_video] $*"; }

NAME="$(opt name)"
VIDEO_SINK="$(opt video_sink)"
DECODER="$(opt decoder)"
RESOLUTION="$(opt resolution)"
FPS="$(opt fps)"
AUDIO_SINK="$(opt audio_sink)"
EXTRA_ARGS="$(opt extra_args)"
DEBUG="$(opt debug)"
GST_DEBUG_OPT="$(opt gst_debug)"
CEC_SWITCH="$(opt cec_switch_input)"
CEC_DEVICE="$(opt cec_device)"

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
# /dev/console, not /dev/tty1: an app may not open tty devices (EPERM even
# when they are listed under devices:), but Docker's default device rules allow
# the console (5:1), which on HA OS is the HDMI console. HAOS-kiosk does the
# same to stop the console cursor blinking through its X screen.
console_write() {
    local err
    if ! err="$(printf '%b' "$1" 2>&1 > /dev/console)"; then
        log "console write failed: ${err:-unknown error}"
    fi
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

# --- HDMI-CEC: switch the TV to the Pi when mirroring starts ---------------
# <Image View On> wakes the TV / leaves its menus, <Active Source> with the
# Pi's physical address makes it select this HDMI input. TVs expect the
# latter from a playback device, so the app claims one if the adapter is
# unconfigured. If another client (e.g. an HA integration) already set up
# logical addresses, they are left alone and the messages go out as that
# address (best effort), since reconfiguring would break that client.
cec_field() { awk -F': *' -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {print $2; exit}'; }

cec_setup() {
    [[ "$CEC_SWITCH" == "true" ]] || return 0
    local info las
    if ! info="$(cec-ctl -d "$CEC_DEVICE" 2>&1)"; then
        log "cec: can't use $CEC_DEVICE (${info##*$'\n'}); input switching off"
        CEC_SWITCH=false
        return 0
    fi
    log "cec: $CEC_DEVICE driver $(cec_field "Driver Name" <<< "$info"), $(cec_field "Available Logical Addresses" <<< "$info") logical address(es) available"
    las="$(cec_field "Logical Addresses" <<< "$info")"
    if [[ "${las%% *}" == "0" || -z "$las" ]]; then
        if cec-ctl -d "$CEC_DEVICE" -s --playback --osd-name "${NAME:0:14}" > /dev/null 2>&1; then
            log "cec: $CEC_DEVICE configured as playback device \"${NAME:0:14}\" ($(cec-ctl -d "$CEC_DEVICE" -s -L 2>/dev/null | tr '\n' ' '))"
        else
            log "cec: configuring $CEC_DEVICE as playback device failed; sending anyway"
        fi
    else
        log "cec: $CEC_DEVICE already configured by another client ($(grep -E 'Logical Address  +:' <<< "$info" | sed 's/.*: //' | paste -sd, -)); using it as is"
    fi
    log "cec: physical address $(cec_field "Physical Address" <<< "$info")"
}

cec_switch_input() {
    [[ "$CEC_SWITCH" == "true" ]] || return 0
    local pa out
    out="$(cec-ctl -d "$CEC_DEVICE" -s --to 0 --image-view-on 2>&1)" || log "cec: image-view-on failed: ${out##*$'\n'}"
    pa="$(cec-ctl -d "$CEC_DEVICE" 2>/dev/null | cec_field "Physical Address")"
    if [[ -z "$pa" || "$pa" == "f.f.f.f" ]]; then
        # A TV that was off may only now report our address via EDID.
        sleep 2
        pa="$(cec-ctl -d "$CEC_DEVICE" 2>/dev/null | cec_field "Physical Address")"
    fi
    if [[ -z "$pa" || "$pa" == "f.f.f.f" ]]; then
        log "cec: no physical address on $CEC_DEVICE; can't send active-source"
        return 0
    fi
    if out="$(cec-ctl -d "$CEC_DEVICE" -s --active-source "phys-addr=$pa" 2>&1)"; then
        log "cec: switched TV to this input ($pa)"
    else
        log "cec: active-source failed: ${out##*$'\n'}"
    fi
}

# UxPlay's mirroring video arrives on TCP 7100 (0x1BBC); an ESTABLISHED (01)
# socket there means a session is on screen. Audio-only AirPlay doesn't use it.
mirroring_active() {
    grep -qsE '^ *[0-9]+: [0-9A-F]+:1BBC [0-9A-F]+:[0-9A-F]+ 01 ' /proc/net/tcp /proc/net/tcp6
}
watch_console() {
    local blanked=false
    log "console devices: $(ls -l /dev/console /dev/fb0 2>&1 | tr '\n' ';')"
    restore_console
    while sleep 1; do
        if mirroring_active; then
            if [[ "$blanked" == false ]]; then
                blank_console; blanked=true; log "mirroring started: console blanked"
                cec_switch_input &
            fi
        elif [[ "$blanked" == true ]]; then
            restore_console; blanked=false; log "mirroring stopped: console restored"
        fi
    done
}

# Log the HDMI mode the console left behind (resolution and refresh rate),
# which kmssink renders into.
display_mode() {
    modetest -M vc4 -p 2>/dev/null | awk '
        /^CRTCs:/ {sec=1; next}
        /^Planes:/ {exit}
        sec && /^[0-9]+\t/ {lit = ($NF != "(0x0)")}
        sec && lit && /^ +#[0-9]+ / {print $2 " @ " $3 " Hz"; exit}'
}
log "display mode: $(display_mode || true)"

case "$VIDEO_SINK" in
    # No force-modesetting: keep the console's display mode and let the vc4
    # plane scaler letterbox the frame. Modesetting to the frame size made the
    # TV stretch portrait (498x1080) streams across the whole screen.
    # skip-vsync: vc4 is an atomic driver, so kmssink waiting for vblank on
    # top of the page flip halves the frame rate (15 fps on a 30 Hz mode).
    kmssink)   VS="kmssink driver-name=vc4 skip-vsync=true" ;;
    fbdevsink) VS="fbdevsink device=/dev/fb0" ;;
    *)        VS="$VIDEO_SINK" ;;
esac

# -p: fixed legacy AirPlay ports (TCP 7000,7001,7100; UDP 6000,6001,7011)
# instead of random ones, so firewalls and watch_console can rely on them.
ARGS=(-n "$NAME" -nh -p -s "$RESOLUTION" -fps "$FPS" -vs "$VS" -as "$AUDIO_SINK")

software_decoder() {
    # Frame threading: in a live pipeline avdec_h264 otherwise uses slice
    # threading, and iOS sends one slice per frame, so it decodes on a single
    # core and drops frames in complex landscape scenes. Costs ~100 ms of
    # latency, which the timestamp-based A/V sync absorbs.
    ARGS+=(-vd "avdec_h264 thread-type=frame max-threads=$(nproc)")
    log "H.264 decode: software (avdec_h264, frame-threaded, $(nproc) threads)"
}

case "$DECODER" in
    hardware)
        # Pi 4 only (bcm2835-codec); the Pi 5 has no H.264 decoder.
        # Not the default: it holds back up to ~16 frames for reordering when
        # the stream doesn't say it needs none (iOS streams don't), and the
        # count grows as frames shrink, so portrait (498x1080) arrives
        # 300-900 ms late and nearly every frame is dropped.
        if grep -qs "bcm2835-codec-decode" /sys/class/video4linux/video*/name; then
            # -bt709: iOS tags streams as full-range (colorimetry 1:3:7:1),
            # which v4l2h264dec refuses with "not-negotiated".
            # No v4l2convert (what -v4l2 adds): the ISP can't renegotiate when
            # the sender rotates (e.g. 498x1080 -> 1920x884).
            ARGS+=(-vd v4l2h264dec -vc identity -bt709)
            log "H.264 decode: hardware (bcm2835-codec)"
        else
            log "hardware decode requested but no bcm2835-codec decoder found"
            software_decoder
        fi
        ;;
    *)  software_decoder ;;
esac

# GStreamer logging on its own, without UxPlay's per-packet -d output, which
# is heavy enough to make the video drop frames.
if [[ -n "$GST_DEBUG_OPT" ]]; then
    export GST_DEBUG="$GST_DEBUG_OPT"
    log "GST_DEBUG=$GST_DEBUG"
fi

if [[ "$DEBUG" == "true" ]]; then
    ARGS+=(-d)
    export GST_DEBUG="${GST_DEBUG:-2}"
fi

if [[ -n "$EXTRA_ARGS" ]]; then
    # Split like a shell would (quotes group words, e.g.
    # -vd "avdec_h264 thread-type=frame"), without evaluating anything.
    mapfile -t EXTRA < <(xargs -n1 printf '%s\n' <<< "$EXTRA_ARGS")
    ARGS+=("${EXTRA[@]}")
fi

cec_setup
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
