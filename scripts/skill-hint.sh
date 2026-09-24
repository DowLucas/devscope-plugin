#!/usr/bin/env bash
# Suggest the usual next step after a pull request is opened or a skill runs.
#
# PostToolUse, Bash and Skill only. DevScope data showed that single events
# rarely predict a skill, but sequences do: opening a PR is the strongest
# precursor of a review (roughly 1 in 6 PRs, 16x the base rate), and many
# skills have a usual follow-up. Auto-invocation would be wrong most of the
# time, so nothing runs on its own. DEVSCOPE_HINTS=on shows the user a
# one-line hint; =claude also tells Claude, which is asked to offer the step,
# never to run it unasked.
#
# - Bash `gh pr create` -> DEVSCOPE_HINT_AFTER_PR (default /code-review).
# - Skill A -> the skill the user most often runs next after A, from the
#   per-user chains session-start.sh caches from /api/similar/skill-chains.
#
# Synchronous by necessity: Claude Code ignores the output of async hooks.
# It is local (no network), shown once per PR or skill per session, and
# silent on any error so it can never get in the way of a tool call.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh" 2>/dev/null || exit 0

[ "${DEVSCOPE_HINTS:-on}" = "off" ] && exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0

# True the first time KEY is seen in this session.
first_time() {
  local session dir seen
  session=$(printf '%s' "$INPUT" | jq -r '.session_id // "none"' 2>/dev/null | tr -cd 'a-zA-Z0-9_-')
  dir="${HOME}/.cache/devscope/hints"
  mkdir -p "$dir" 2>/dev/null || return 1
  find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
  seen="$dir/${session:-none}"
  grep -Fxq "$1" "$seen" 2>/dev/null && return 1
  printf '%s\n' "$1" >> "$seen" 2>/dev/null || true
}

# Show MSG to the user; in claude mode also give Claude CTX.
emit() {
  if [ "${DEVSCOPE_HINTS:-on}" = "claude" ]; then
    jq -n --arg m "$1" --arg c "$2" \
      '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
  else
    jq -n --arg m "$1" '{systemMessage: $m}'
  fi
}

case "$TOOL" in
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
    printf '%s' "$CMD" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create' || exit 0
    [ "$(printf '%s' "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)" = "true" ] && exit 0
    # Only a PR that was actually created: gh prints its URL on success.
    URL=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // ""' 2>/dev/null \
      | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -1)
    [ -n "$URL" ] || exit 0
    first_time "$URL" || exit 0

    NEXT="${DEVSCOPE_HINT_AFTER_PR:-/code-review}"
    emit "DevScope: PR opened. Review it next with ${NEXT}?" \
      "DevScope: the user just opened a pull request (${URL}). They often run ${NEXT} after opening one. Offer to run ${NEXT} in one short sentence; do not run it unless the user agrees."
    ;;
  Skill)
    CHAINS="${HOME}/.cache/devscope/skill-chains.json"
    [ -f "$CHAINS" ] || exit 0
    SKILL=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // "" | ltrimstr("/") | ascii_downcase' 2>/dev/null) || exit 0
    [ -n "$SKILL" ] || exit 0
    read -r NEXT PCT < <(jq -r --arg s "$SKILL" \
      '[.chains[]? | select(.from == $s)][0] // empty | "\(.to) \(.share * 100 | round)"' "$CHAINS" 2>/dev/null) || exit 0
    # Names come from the server: accept only plain skill names.
    printf '%s' "${NEXT:-}" | grep -Eq '^[a-z0-9:_-]{1,60}$' || exit 0
    printf '%s' "${PCT:-}" | grep -Eq '^[0-9]{1,3}$' || exit 0
    first_time "skill:${SKILL}" || exit 0

    emit "DevScope: after /${SKILL} you usually run /${NEXT} next." \
      "DevScope: after /${SKILL} the user usually runs /${NEXT} next (${PCT}% of the time). When the /${SKILL} work is done, offer to run /${NEXT} in one short sentence; do not run it unless the user agrees."
    ;;
esac
exit 0
