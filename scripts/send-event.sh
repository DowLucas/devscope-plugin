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

CURL_ARGS=(-s -X POST "${DEVSCOPE_URL}/api/events"
  -H "Content-Type: application/json"
  -d "$EVENT"
  --max-time 5
  -w '%{http_code}'
  -o /dev/null)

# Build curl config to avoid exposing API key in process listing
CURL_CONFIG=""
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
fi

HTTP_CODE=$(echo "$CURL_CONFIG" | curl --config - "${CURL_ARGS[@]}" 2>/dev/null) || true
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"

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
