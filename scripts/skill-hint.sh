#!/usr/bin/env bash
# Suggest the usual next step after a pull request is opened.
#
# PostToolUse, Bash only. DevScope data showed that opening a PR is the
# strongest precursor of running a review (roughly 1 in 6 PRs, 16x the base
# rate), but auto-invocation would be wrong most of the time, so this only
# shows the user a one-line hint; Claude is not told and runs nothing.
#
# Synchronous by necessity: Claude Code ignores the output of async hooks.
# It is local (no network), shown once per PR per session, and silent on
# any error so it can never get in the way of a Bash call.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh" 2>/dev/null || exit 0

[ "${DEVSCOPE_HINTS:-on}" = "off" ] && exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
printf '%s' "$CMD" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create' || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)" = "true" ] && exit 0

# Only a PR that was actually created: gh prints its URL on success.
URL=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // ""' 2>/dev/null \
  | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -1)
[ -n "$URL" ] || exit 0

# Once per PR per session.
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "none"' 2>/dev/null | tr -cd 'a-zA-Z0-9_-')
HINT_DIR="${HOME}/.cache/devscope/hints"
mkdir -p "$HINT_DIR" 2>/dev/null || exit 0
find "$HINT_DIR" -type f -mtime +7 -delete 2>/dev/null || true
SEEN="$HINT_DIR/${SESSION_ID:-none}"
grep -Fxq "$URL" "$SEEN" 2>/dev/null && exit 0
printf '%s\n' "$URL" >> "$SEEN" 2>/dev/null || true

NEXT="${DEVSCOPE_HINT_AFTER_PR:-/code-review}"
jq -n --arg m "DevScope: PR opened. Review it next with ${NEXT}?" '{systemMessage: $m}'
exit 0
