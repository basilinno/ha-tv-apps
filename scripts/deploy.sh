#!/usr/bin/env bash
# Copy the app into the Home Assistant box's /addons folder (local apps).
# After the first deploy, install it once from the HA UI:
#   Settings -> Apps -> App store -> ⋮ -> Check for updates -> Local apps.
# Subsequent deploys need a "Rebuild" from the app page (or scripts/ha.sh rebuild).
set -euo pipefail

HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-hassio}"
SLUG=airplay_video
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$HA_USER@$HA_HOST")

COPYFILE_DISABLE=1 tar -C "$ROOT" -cz "$SLUG" \
    | "${SSH[@]}" "sudo sh -c 'rm -rf /addons/$SLUG && tar -C /addons -xz && chown -R root:root /addons/$SLUG'"

"${SSH[@]}" "ls -R /addons/$SLUG"
echo "deployed $SLUG to $HA_HOST:/addons/$SLUG"
