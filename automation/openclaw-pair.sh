#!/usr/bin/env bash
set -euo pipefail

# openclaw-pair.sh — manage OpenClaw Control-UI device access on the lab host.
#
#   list      show pending + paired Control-UI devices
#   approve   approve the most recent pending pairing request (unblocks a browser
#             stuck on "pairing required")
#   url       print a tokenized dashboard URL for the PUBLIC domain — paste it into
#             dev-hub → OpenClaw → Edit App → "Embed URL" (stored encrypted) so the
#             OpenClaw window opens already-connected, no manual pairing
#
# Run on the Dokploy host. The dashboard URL embeds a live OPERATOR token — it is
# printed to YOUR terminal only and never committed; treat it like a password.
#
# OpenClaw's Control UI pairs per-device: an unapproved browser lands in
# ~/.openclaw/devices/pending.json and must be approved into paired.json. The
# token URL sidesteps that (the token itself grants operator access).

PUBLIC_URL="${OPENCLAW_PUBLIC_URL:-https://claw.ai.alshawwaf.ca}"

gw_container() { sudo docker ps --format '{{.Names}}' | grep -i openclaw-gateway | head -1; }

oc() {
  local c; c="$(gw_container)"
  [ -n "$c" ] || { echo "openclaw-gateway container not found (is OpenClaw deployed?)" >&2; exit 1; }
  sudo docker exec "$c" node dist/index.js "$@"
}

case "${1:-list}" in
  list)
    oc devices list ;;
  approve)
    oc devices approve --latest ;;
  url)
    raw="$(oc dashboard --no-open 2>/dev/null | grep -oE 'https?://[^[:space:]]*#token=[^[:space:]]+' | head -1)"
    [ -n "$raw" ] || { echo "could not obtain a dashboard URL from the gateway" >&2; exit 1; }
    pub="$(printf '%s' "$raw" | sed -E "s#^https?://[^/]+#${PUBLIC_URL%/}#")"
    echo "$pub"
    echo "  ^ paste into dev-hub → OpenClaw → Edit App → Embed URL (encrypted at rest)." >&2
    ;;
  *)
    echo "usage: openclaw-pair.sh [list|approve|url]" >&2
    exit 1 ;;
esac
