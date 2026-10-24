#!/usr/bin/env bash
# Run the `ha` CLI on the Home Assistant box through the SSH app.
# The SSH app holds a Supervisor token in its s6 environment, but login shells
# don't get it, so it is exported for this one command.
#
#   scripts/ha.sh apps info local_airplay_video
#   scripts/ha.sh apps rebuild local_airplay_video
#   scripts/ha.sh apps logs local_airplay_video
#
# Shortcuts for this app: install | rebuild | start | stop | restart | logs | info
#
# Raw Supervisor API (JSON body on stdin), e.g. to set the app's options:
#   echo '{"options": {...}}' | scripts/ha.sh api POST /addons/local_airplay_video/options
set -euo pipefail

HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-hassio}"
APP=local_airplay_video
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     "$HA_USER@$HA_HOST")
TOKEN='$(cat /run/s6/container_environment/SUPERVISOR_TOKEN)'

if [[ "${1:-}" == api ]]; then
    method="$2" path="$3"
    "${SSH[@]}" "sudo sh -c 'curl -sS -X $method -H \"Authorization: Bearer $TOKEN\" \
        -H \"Content-Type: application/json\" --data-binary @- http://supervisor$path'"
    echo
    exit
fi

case "${1:-}" in
    install|rebuild|start|stop|restart|logs|info) set -- apps "$1" "$APP" ;;
esac

"${SSH[@]}" "sudo sh -c 'SUPERVISOR_TOKEN=$TOKEN ha $*'"
