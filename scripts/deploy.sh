#!/usr/bin/env bash
# Copy an app into the Home Assistant box's /addons folder (local apps).
#   scripts/deploy.sh airplay_video|hdmi_cec
# After the first deploy, install it once (scripts/ha.sh store reload, then
# scripts/ha.sh install <slug>). Later deploys need scripts/ha.sh rebuild <slug>,
# or scripts/ha.sh update <slug> after a version bump.
# The host comes from .env (HA_HOST, HA_USER).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-hassio}"
SLUG="${1:?usage: $0 <app slug>}"
[[ -f "$ROOT/$SLUG/config.yaml" ]] || { echo "no app $SLUG" >&2; exit 1; }

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$HA_USER@$HA_HOST")

# Drop image: so the Supervisor builds the local copy instead of pulling the
# published image.
COPYFILE_DISABLE=1 tar -C "$ROOT" -cz "$SLUG" \
    | "${SSH[@]}" "sudo sh -c 'rm -rf /addons/$SLUG && tar -C /addons -xz \
        && sed -i \"/^image:/d\" /addons/$SLUG/config.yaml && chown -R root:root /addons/$SLUG'"

"${SSH[@]}" "ls -R /addons/$SLUG"
echo "deployed $SLUG to $HA_HOST:/addons/$SLUG"
