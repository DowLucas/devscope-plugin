#!/usr/bin/env bash
# "You've asked this before": gated retrieval over the user's own history.
#
# UserPromptSubmit, synchronous (Claude Code ignores async hook output). Sends
# the prompt to DevScope's /api/similar/preflight, which answers only when a
# near-identical prompt appears in the user's own earlier sessions, with how
# it went. The note goes to Claude as additionalContext; the user sees a
# one-line notice. Blocks the prompt at most ~2 s and stays silent on any
# problem. Off with DEVSCOPE_PREFLIGHT=off; never runs in private mode.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh" 2>/dev/null || exit 0

[ "${DEVSCOPE_PREFLIGHT:-on}" = "off" ] && exit 0
[ "${DEVSCOPE_PRIVACY:-standard}" = "private" ] && exit 0

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || exit 0
# Mirrors the server's 4-word minimum, so "yes"/"continue" cost no round trip.
[ "$(printf '%s' "$PROMPT" | wc -w)" -ge 4 ] || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

BODY=$(jq -n --arg p "${PROMPT:0:8000}" --arg s "${SESSION_ID:-none}" '{prompt: $p, session_id: $s}') || exit 0
CURL_CONFIG=""
[ -n "${DEVSCOPE_API_KEY:-}" ] && CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
RESP=$(printf '%s' "$CURL_CONFIG" | curl --config - -s -X POST "${DEVSCOPE_URL}/api/similar/preflight" \
  -H "Content-Type: application/json" -H "x-requested-with: devscope-cli" \
  -d "$BODY" --max-time 2 2>/dev/null) || exit 0

CTX=$(printf '%s' "$RESP" | jq -r '.context // empty' 2>/dev/null)
[ -n "$CTX" ] || exit 0
DAYS=$(printf '%s' "$RESP" | jq -r '[.matches[]?.day] | join(", ")' 2>/dev/null)

jq -n --arg c "$CTX" --arg m "DevScope: you've asked this before (${DAYS}). Claude has the notes." \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
