# Pinned on purpose, like the AirPlay app: the Supervisor passes its own base
# as BUILD_FROM. The daemon needs nothing beyond the Python standard library.
FROM alpine:3.22

RUN apk add --no-cache python3

COPY rootfs /

CMD ["python3", "-u", "/hdmi_cec.py"]
