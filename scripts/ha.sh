#!/usr/bin/env bash
# Copyright (c) 2026 Basil Innovations LLC.
# SPDX-License-Identifier: Apache-2.0
# Run the `ha` CLI on the Home Assistant box through the SSH app.
# The SSH app holds a Supervisor token in its s6 environment, but login shells
# don't get it, so it is exported for this one command.
#
#   scripts/ha.sh apps info local_airplay_video
#   scripts/ha.sh core logs --lines 100
#
# Shortcuts for a local app: install | rebuild | update | start | stop | restart | logs | info
#   scripts/ha.sh logs hdmi_cec --lines 50
#
# Raw Supervisor API (JSON body on stdin), e.g. to set an app's options:
#   echo '{"options": {...}}' | scripts/ha.sh api POST /addons/local_airplay_video/options
#
# The host comes from .env (HA_HOST, HA_USER).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-hassio}"
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
    install|rebuild|update|start|stop|restart|logs|info)
        cmd="$1" slug="${2:?usage: $0 $1 <app slug> [args]}"
        shift 2
        set -- apps "$cmd" "local_$slug" "$@"
        ;;
esac

"${SSH[@]}" "sudo sh -c 'SUPERVISOR_TOKEN=$TOKEN ha $*'"
