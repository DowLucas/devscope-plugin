#!/usr/bin/env bash
# Waits out a blocked session's grace delay, then announces it, and reminds
# later while it stays blocked. Started detached by _ds_voice_arm, one per arm:
# when the session re-arms, the marker's eventId changes and this timer exits.
# Usage: timer.sh <session-id> <event-id>
set -uo pipefail
VOICE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$VOICE_DIR/../_helpers.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1091
. "$VOICE_DIR/lib.sh" || exit 0

SID="${1:-}" EID="${2:-}"
[ -n "$SID" ] && [ -n "$EID" ] || exit 0
MARKER=$(_ds_voice_marker "$SID")

while :; do
  [ -f "$MARKER" ] && [ "$(jq -r '.eventId' "$MARKER" 2>/dev/null)" = "$EID" ] || exit 0
  _ds_voice_enabled || exit 0
  now=$(date +%s)
  due=$(_ds_voice_due "$MARKER" "$now") || exit 0
  # While muted, keep the marker and announce once the mute ends.
  mute=$(_ds_voice_int .mute_until 0)
  [ "$mute" -gt "$due" ] && due=$mute
  if [ "$now" -lt "$due" ]; then
    # Short naps, so off, unmute and re-arms take effect promptly.
    nap=$((due - now))
    [ "$nap" -gt "$DS_VOICE_MAX_SLEEP" ] && nap=$DS_VOICE_MAX_SLEEP
    sleep "$nap"
    continue
  fi
  _ds_voice_with_lock _ds_voice_announce_due
  sleep 1
done
