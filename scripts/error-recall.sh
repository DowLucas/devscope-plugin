#!/usr/bin/env bash
# "This error came up before": recall over the user's own past tool failures.
#
# PostToolUseFailure, synchronous (Claude Code ignores async hook output).
# Sends the failed tool's error to DevScope's /api/similar/error, which
# answers only when a very similar failure appears in the user's own earlier
# sessions, with whether it got resolved and how that turn ended. The note
# goes to Claude as additionalContext; the user sees a one-line notice. Asks
# once per distinct error per session, blocks at most ~2 s and stays silent
# on any problem. Off with DEVSCOPE_ERROR_RECALL=off; never runs in private mode.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh" 2>/dev/null || exit 0

[ "${DEVSCOPE_ERROR_RECALL:-on}" = "off" ] && exit 0
[ "${DEVSCOPE_PRIVACY:-standard}" = "private" ] && exit 0

INPUT=$(cat)
[ "$(printf '%s' "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null)" = "true" ] && exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
ERROR=$(printf '%s' "$INPUT" | jq -r '.error // "" | tostring' 2>/dev/null) || exit 0
# Mirrors the server's 20-char minimum ("Exit code 1" carries no signal).
[ -n "$TOOL" ] && [ "${#ERROR}" -ge 20 ] || exit 0

# Once per distinct error per session: a retry loop asks only the first time.
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "none"' 2>/dev/null | tr -cd 'a-zA-Z0-9_-')
HINT_DIR="${HOME}/.cache/devscope/hints"
mkdir -p "$HINT_DIR" 2>/dev/null || exit 0
SEEN="$HINT_DIR/${SESSION_ID:-none}.errors"
KEY=$(_ds_sha256 "${TOOL}:${ERROR}")
grep -Fxq "$KEY" "$SEEN" 2>/dev/null && exit 0
printf '%s\n' "$KEY" >> "$SEEN" 2>/dev/null || true

BODY=$(jq -n --arg t "$TOOL" --arg e "${ERROR:0:4000}" --arg s "${SESSION_ID:-none}" \
  '{tool: $t, error: $e, session_id: $s}') || exit 0
RESP=$(_ds_api POST /api/similar/error "$BODY" 2) || exit 0

CTX=$(printf '%s' "$RESP" | jq -r '.context // empty' 2>/dev/null)
[ -n "$CTX" ] || exit 0
SEEN_N=$(printf '%s' "$RESP" | jq -r '.matches | length' 2>/dev/null)
FIXED_N=$(printf '%s' "$RESP" | jq -r '[.matches[] | select(.resolved)] | length' 2>/dev/null)

jq -n --arg c "$CTX" --arg m "DevScope: you've hit this error before (${SEEN_N}x, ${FIXED_N} resolved). Claude has the notes." \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUseFailure", additionalContext: $c}}'
exit 0
