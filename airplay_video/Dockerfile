# Pinned on purpose: the Supervisor passes its Alpine base as BUILD_FROM,
# but uxplay and its GStreamer stack come from Debian.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        uxplay \
        avahi-daemon \
        curl \
        dbus \
        jq \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-libav \
        gstreamer1.0-alsa \
        gstreamer1.0-pulseaudio \
        gstreamer1.0-tools \
        libdrm-tests \
        v4l-utils \
    && rm -rf /var/lib/apt/lists/*

COPY rootfs /

RUN chmod +x /run.sh

CMD ["/run.sh"]
