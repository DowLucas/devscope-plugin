#!/usr/bin/env bash
# Common event sender for DevScope
# Usage: echo '{"hook_input":"..."}' | send-event.sh <event_type> '<payload_json>'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/queue.sh"

EVENT_TYPE="$1"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT_NAME=$(basename "$CWD" 2>/dev/null || echo "unknown")

# Session continuity: use DevScope session ID if available
# PPID identifies the Claude Code process, keeping concurrent sessions separate
if [ -n "$CWD" ]; then
  _GC_DEV_EMAIL=$(git -C "$CWD" config user.email 2>/dev/null || echo "${USER}@local")
  # Normalize email so the session-state filename matches across case-different
  # `git user.email` values, and matches session-start.sh's PROJECT_HASH.
  _GC_DEV_EMAIL=$(_ds_normalize_email "$_GC_DEV_EMAIL")
  _GC_HASH=$(_ds_sha256 "${_GC_DEV_EMAIL}:${CWD}:${PPID}")
  _GC_STATE="${HOME}/.cache/devscope/${_GC_HASH}.session"
  if [ -f "$_GC_STATE" ]; then
    _GC_SID=$(cat "$_GC_STATE")
    [ -n "$_GC_SID" ] && SESSION_ID="$_GC_SID"
  fi
fi

DEV_NAME=$(git -C "$CWD" config user.name 2>/dev/null || echo "$USER")
DEV_EMAIL=$(git -C "$CWD" config user.email 2>/dev/null || echo "${USER}@local")
# Normalize before hashing so developerId matches the backend's
# computeDeveloperId() in packages/backend/src/services/developerLink.ts,
# which lowercases + trims before SHA256. Without this a mixed-case
# `git user.email` produces a different developerId on the plugin side and
# forks the same human into two developer rows.
DEV_ID=$(_ds_sha256 "$(_ds_normalize_email "$DEV_EMAIL")")

PAYLOAD="${2:-$(echo "$INPUT" | jq -c '{raw: .}')}"

# DEV-74: in private mode, stamp `salt_version` (cached from session.start) on
# every event so the backend can attribute hashes to a salt epoch later. We
# never put `salt` itself on the wire — the backend strips event.payload.salt
# defensively (DEV-76) but the plugin must not send it in the first place.
if [ "${DEVSCOPE_PRIVACY:-standard}" = "private" ] && [ -n "$CWD" ]; then
  _DS_SVER=$(_ds_load_salt_version "$CWD" 2>/dev/null || true)
  if [ -n "$_DS_SVER" ]; then
    PAYLOAD=$(echo "$PAYLOAD" | jq -c --argjson sv "$_DS_SVER" '. + {salt_version: $sv}' 2>/dev/null) || true
  fi
fi

EVENT_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "evt-$(_ds_now_ns)")

TIMESTAMP=$(_ds_timestamp)

# Privacy: in `private` mode, replace projectPath/projectName with redacted
# stand-ins. The path becomes a stable hash of the absolute CWD so the backend
# can still group sessions; the name is replaced wholesale because the basename
# can itself be sensitive (e.g. `acme-acquisition-spike`). Other privacy modes
# are unchanged. See DEV-67.
if [ "${DEVSCOPE_PRIVACY:-standard}" = "private" ]; then
  PROJECT_PATH_OUT="hash:$(_ds_sha256 "$CWD" | cut -c1-12)"
  PROJECT_NAME_OUT="redacted"
else
  PROJECT_PATH_OUT="$CWD"
  PROJECT_NAME_OUT="$PROJECT_NAME"
fi

EVENT=$(jq -n \
  --arg id "$EVENT_ID" \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg did "$DEV_ID" \
  --arg dname "$DEV_NAME" \
  --arg ppath "$PROJECT_PATH_OUT" \
  --arg pname "$PROJECT_NAME_OUT" \
  --arg etype "$EVENT_TYPE" \
  --argjson payload "$PAYLOAD" \
  '{
    id: $id,
    timestamp: $ts,
    sessionId: $sid,
    developerId: $did,
    developerName: $dname,
    projectPath: $ppath,
    projectName: $pname,
    eventType: $etype,
    payload: $payload
  }')

# Warn if sending API key over unencrypted HTTP to non-local server
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  case "$DEVSCOPE_URL" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*) ;;
    *) echo "[devscope] WARNING: Sending API key over unencrypted HTTP to ${DEVSCOPE_URL}" >&2 ;;
  esac
fi

# DEV-74: on `session.start` we need the response body so we can pin the
# per-org `salt` and `salt_version` returned by DEV-76. For all other event
# types we stay on the original `-o /dev/null` path to keep the hot loop tight.
_DS_BODY_FILE=""
if [ "$EVENT_TYPE" = "session.start" ]; then
  _DS_BODY_FILE=$(mktemp 2>/dev/null || echo "/tmp/ds-session-start-$$.json")
  CURL_ARGS=(-s -X POST "${DEVSCOPE_URL}/api/events"
    -H "Content-Type: application/json"
    -d "$EVENT"
    --max-time 5
    -w '%{http_code}'
    -o "$_DS_BODY_FILE")
else
  CURL_ARGS=(-s -X POST "${DEVSCOPE_URL}/api/events"
    -H "Content-Type: application/json"
    -d "$EVENT"
    --max-time 5
    -w '%{http_code}'
    -o /dev/null)
fi

# Build curl config to avoid exposing API key in process listing
CURL_CONFIG=""
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
fi

HTTP_CODE=$(echo "$CURL_CONFIG" | curl --config - "${CURL_ARGS[@]}" 2>/dev/null) || true
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"

# DEV-74: persist salt + salt_version from the session.start response so the
# rest of the session's hooks can hash path-like fields and stamp salt_version.
# The salt stays in a per-project cache file (mode 600); it is NEVER sent back
# on the wire, logged, or placed in events.payload (no-reverse-map rule —
# DEV-72). The cache is cleared on the next `startup` session-start.
if [ "$EVENT_TYPE" = "session.start" ] && [ -f "$_DS_BODY_FILE" ]; then
  case "$HTTP_CODE" in
    2*)
      _DS_SALT=$(jq -r '.salt // empty' "$_DS_BODY_FILE" 2>/dev/null || true)
      _DS_SVER_RESP=$(jq -r '.salt_version // empty' "$_DS_BODY_FILE" 2>/dev/null || true)
      if { [ -n "$_DS_SALT" ] || [ -n "$_DS_SVER_RESP" ]; } && [ -n "$CWD" ]; then
        _DS_PH=$(_ds_project_hash "$CWD")
        _DS_SF="${HOME}/.cache/devscope/${_DS_PH}.salt"
        mkdir -p -m 0700 "${HOME}/.cache/devscope"
        ( umask 077
          {
            [ -n "$_DS_SALT" ] && printf 'SALT=%s\n' "$_DS_SALT"
            [ -n "$_DS_SVER_RESP" ] && printf 'SALT_VERSION=%s\n' "$_DS_SVER_RESP"
          } > "$_DS_SF" )
        chmod 600 "$_DS_SF" 2>/dev/null || true
      fi
      ;;
  esac
  rm -f "$_DS_BODY_FILE" 2>/dev/null || true
fi

case "$HTTP_CODE" in
  2*)
    # Backend has it. Try to drain anything queued from earlier outages.
    if [ -z "${DEVSCOPE_NO_DRAIN:-}" ]; then
      ( "$SCRIPT_DIR/drain-queue.sh" >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
    ;;
  4*)
    # Backend rejected this specific event — log and drop. Don't queue:
    # retrying a malformed event would just fill the buffer.
    echo "[devscope] Event delivery failed (HTTP $HTTP_CODE) to ${DEVSCOPE_URL}" >&2
    ;;
  *)
    # 000 (network error / timeout) or 5xx (server problem) — buffer it.
    echo "[devscope] Event delivery failed (HTTP $HTTP_CODE) to ${DEVSCOPE_URL}; queued for retry" >&2
    printf '%s' "$EVENT" | _ds_queue_enqueue "$EVENT_ID" || true
    ;;
esac

exit 0
