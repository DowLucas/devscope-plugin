#!/usr/bin/env bash
# Speaks one reply summary or explanation, detached from the hook or command
# that queued it (both return at once). Waits its turn on the global speak
# lock, so it never talks over the announcer or another session.
# Usage: speak.sh reply <session-id> <event-id>
#        speak.sh say <job-file>
set -uo pipefail
VOICE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$VOICE_DIR/../_helpers.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1091
. "$VOICE_DIR/lib.sh" || exit 0

# A piece of long speech can run past the announcer's 30 s at a slow speed.
DS_VOICE_SPEAK_TIMEOUT=90
_ds_voice_mkdirs
# Registered so /devscope:voice stop can end this process group.
PIDF="$DS_VOICE_DIR/speakers/$$"
: > "$PIDF"
trap 'rm -f "$PIDF"' EXIT

case "${1:-}" in
  reply)
    SID="${2:-}" EID="${3:-}"
    [ -n "$SID" ] && [ -n "$EID" ] || exit 0
    JOB="$DS_VOICE_DIR/replies/$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9_-').json"
    current() { [ "$(jq -r '.eventId' "$JOB" 2>/dev/null)" = "$EID" ]; }
    current || exit 0
    TEXT=$(_ds_voice_reply_text "$JOB") || exit 0
    PRIVACY=$(jq -r '.privacy' "$JOB" 2>/dev/null)
    speak_reply() {
      # A newer reply from the same session replaces this one.
      current || return 0
      _ds_voice_muted && return 0
      _ds_voice_log "speak reply: $TEXT"
      _ds_voice_speak_long "$TEXT" "$PRIVACY"
      current && rm -f "$JOB"
    }
    _ds_voice_with_lock speak_reply ;;
  say)
    JOB="${2:-}"
    [ -f "$JOB" ] || exit 0
    speak_job() {
      _ds_voice_log "speak explanation ($(jq -r '.text | length' "$JOB" 2>/dev/null) chars)"
      _ds_voice_speak_long "$(jq -r '.text' "$JOB" 2>/dev/null)" "$(jq -r '.privacy' "$JOB" 2>/dev/null)"
    }
    _ds_voice_with_lock speak_job
    rm -f "$JOB" ;;
esac
exit 0
